#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GENERATED_DIR="${PROJECT_DIR}/ClaudeMonitor/Generated"
mkdir -p "${GENERATED_DIR}"

source "${PROJECT_DIR}/scripts/build-config.sh"

BUILD_DATE=$(date +"%Y-%m-%d")

cat > "${GENERATED_DIR}/BuildInfo.swift" << EOF
enum BuildInfo {
    static let date = "${BUILD_DATE}"
    // Single source of truth is scripts/build-config.sh's UNDER_TEST_ENV_VAR.
    static let underTestEnvVar = "${UNDER_TEST_ENV_VAR}"
    // Single source of truth is scripts/build-config.sh's RUN_INTEGRATION_TESTS_ENV_VAR.
    static let runIntegrationTestsEnvVar = "${RUN_INTEGRATION_TESTS_ENV_VAR}"
}
EOF

echo "Generated BuildInfo.swift (date: ${BUILD_DATE})"
