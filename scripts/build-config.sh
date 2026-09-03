# BuildConfig.sh — single source of truth for build settings.
#
# Sourced by: build.sh, install.sh
# Must be kept in sync with: Xcode project (project.pbxproj), Package.swift
# See CLAUDE.md for details.

APP_NAME="ClaudeMonitor"
BUNDLE_ID="com.dancingZdenda.ClaudeMonitor"
VERSION="1.2.0"
DEPLOYMENT_TARGET="15.0"
SWIFT_VERSION="6"
DEFAULT_ISOLATION="nonisolated"
UPCOMING_FEATURES="MemberImportVisibility"

# Env var test.sh exports before launching the test binary. UsageHistory.init (via the
# generated BuildInfo.underTestEnvVar) uses this to detect it's running under our own
# test runner — see CLAUDE.md's anti-production-write guard.
UNDER_TEST_ENV_VAR="CLAUDEMONITOR_UNDER_TEST"

# Opt-in env var gating IntegrationTests.swift's real-network tests (via the generated
# BuildInfo.runIntegrationTestsEnvVar). Unset by default so ./test.sh never depends on
# network reachability; a developer sets it explicitly to exercise the live endpoints.
RUN_INTEGRATION_TESTS_ENV_VAR="CLAUDEMONITOR_RUN_INTEGRATION_TESTS"
