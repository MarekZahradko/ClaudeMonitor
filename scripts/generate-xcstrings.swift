#!/usr/bin/env swift
import Foundation

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let projectDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let translationsDir = projectDir.appendingPathComponent("Translations")
let outputPath = projectDir.appendingPathComponent("ClaudeMonitor/Generated/Translations/Localizable.xcstrings")
let lprojDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

/// A single language's value for one key. Most keys are `.plain` — unchanged from before
/// plural support existed. A key whose JSON value is an object instead of a string is `.plural`:
/// its whole value IS the pluralized text (there is no surrounding literal text baked into the
/// same key — see e.g. `prefs.retention.years_suffix`), keyed by CLDR plural category
/// ("zero", "one", "two", "few", "many", "other"). The app supplies the count separately when
/// resolving these keys (see PreferencesWindowController).
enum LocalizedValue {
    case plain(String)
    case plural([String: String])
}

/// Any failure while loading a Translations/*.json file: unreadable file, malformed JSON,
/// or a value shape this format doesn't support. These must fail the whole generation run
/// (see `loadJSON` below) rather than be silently skipped — a silently-skipped key ships
/// with a missing translation and no diagnostic signal at all.
struct LocalizationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func loadJSON(_ url: URL) throws -> [String: LocalizedValue] {
    guard let data = try? Data(contentsOf: url) else {
        throw LocalizationError(message: "\(url.lastPathComponent): could not read file")
    }
    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LocalizationError(message: "\(url.lastPathComponent): not a valid JSON object of {key: value}")
    }
    var result: [String: LocalizedValue] = [:]
    for (key, value) in dict {
        if let s = value as? String {
            result[key] = .plain(s)
        } else if let categories = value as? [String: String] {
            guard !categories.isEmpty else {
                throw LocalizationError(message: "\(url.lastPathComponent): key \"\(key)\" is a plural object with no categories")
            }
            guard categories["other"] != nil else {
                throw LocalizationError(message: "\(url.lastPathComponent): key \"\(key)\" is a plural object missing the required \"other\" category")
            }
            result[key] = .plural(categories)
        } else {
            throw LocalizationError(message: "\(url.lastPathComponent): key \"\(key)\" has an unsupported value (expected a string, or a {category: string} plural object): \(value)")
        }
    }
    return result
}

// _comments.json has no plural entries — always plain strings. Comments are optional (the file
// legitimately doesn't have to exist — a repo with no dev comments yet is a supported state), so
// a missing file silently yields no comments. But if the file IS present, it must be readable and
// shaped as {key: string} like every other Translations/*.json file; a present-but-broken file
// fails the whole run for the same reason `loadJSON` does — silently discarding comments due to a
// malformed file would ship with no diagnostic signal at all.
func loadComments(_ url: URL) throws -> [String: String] {
    guard fm.fileExists(atPath: url.path) else { return [:] }
    guard let data = try? Data(contentsOf: url) else {
        throw LocalizationError(message: "\(url.lastPathComponent): could not read file")
    }
    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        throw LocalizationError(message: "\(url.lastPathComponent): not a valid JSON object of {key: string}")
    }
    return dict
}

do {
    let comments = try loadComments(translationsDir.appendingPathComponent("_comments.json"))

    var languages: [String: [String: LocalizedValue]] = [:]
    for file in try fm.contentsOfDirectory(at: translationsDir, includingPropertiesForKeys: nil) {
        let name = file.lastPathComponent
        guard name.hasSuffix(".json"), !name.hasPrefix("_") else { continue }
        let dict = try loadJSON(file)
        guard !dict.isEmpty else { continue }
        languages[file.deletingPathExtension().lastPathComponent] = dict
    }

    guard !languages.isEmpty else {
        fputs("Error: no language files in Translations/\n", stderr)
        exit(1)
    }

    let allKeys = Set(languages.values.flatMap(\.keys)).sorted()

    // Build xcstrings
    var strings: [String: Any] = [
        "_GENERATED": [
            "comment": "DO NOT READ OR EDIT THIS FILE. Generated from Translations/*.json by scripts/generate-xcstrings.swift. To add or change translations, edit the JSON source files and run the generate script.",
        ] as [String: Any],
    ]
    for key in allKeys {
        var entry: [String: Any] = [:]
        if let c = comments[key] { entry["comment"] = c }
        var locs: [String: Any] = [:]
        for (lang, values) in languages {
            guard let value = values[key] else { continue }
            switch value {
            case .plain(let s):
                locs[lang] = ["stringUnit": ["state": "translated", "value": s]]
            case .plural(let categories):
                var pluralVariations: [String: Any] = [:]
                for (category, text) in categories {
                    pluralVariations[category] = ["stringUnit": ["state": "translated", "value": text]]
                }
                locs[lang] = ["variations": ["plural": pluralVariations]]
            }
        }
        if !locs.isEmpty { entry["localizations"] = locs }
        strings[key] = entry
    }

    var data = try JSONSerialization.data(
        withJSONObject: ["sourceLanguage": "en", "strings": strings, "version": "1.0"] as [String: Any],
        options: [.prettyPrinted, .sortedKeys]
    )
    data.append(contentsOf: "\n".utf8)
    try fm.createDirectory(at: outputPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: outputPath)
    print("Generated xcstrings: \(allKeys.count) keys × \(languages.count) languages")

    // Write .lproj/.strings (+ .stringsdict for any plural keys) for CLI builds
    if let lprojDir {
        for (lang, values) in languages.sorted(by: { $0.key < $1.key }) {
            let dir = "\(lprojDir)/\(lang).lproj"
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

            var stringsOut = ""
            // NSStringLocalizedFormatKey ("value" below) is the fixed name of this key's sole
            // substitution variable — see the schema note on LocalizedValue.plural above: a
            // plural key's entire value is just the substitution token, with no other literal
            // text sharing the key.
            var stringsdictPlist: [String: Any] = [:]
            for key in allKeys {
                guard let value = values[key] else { continue }
                switch value {
                case .plain(let s):
                    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    stringsOut += "\"\(key)\" = \"\(escaped)\";\n"
                case .plural(let categories):
                    var variable: [String: String] = [
                        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                        "NSStringFormatValueTypeKey": "ld",
                    ]
                    for (category, text) in categories { variable[category] = text }
                    stringsdictPlist[key] = [
                        "NSStringLocalizedFormatKey": "%#@value@",
                        "value": variable,
                    ]
                }
            }
            try stringsOut.write(toFile: "\(dir)/Localizable.strings", atomically: true, encoding: .utf8)

            if !stringsdictPlist.isEmpty {
                let plistData = try PropertyListSerialization.data(fromPropertyList: stringsdictPlist, format: .xml, options: 0)
                try plistData.write(to: URL(fileURLWithPath: "\(dir)/Localizable.stringsdict"))
            }
        }
        print("Generated .strings for \(languages.count) languages")
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
