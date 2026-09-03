@testable import ClaudeMonitor
import Foundation
import Testing

struct UsageHistoryTestFixture {
    let history: UsageHistory
    let baseDirectory: URL

    @MainActor init() {
        self.baseDirectory = TestHistoryRoot.makeSubdirectory()
        self.history = UsageHistory(baseDirectory: baseDirectory)
    }
}
