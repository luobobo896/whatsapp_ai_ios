#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

WDA_DEVICE_UDID=${WDA_DEVICE_UDID:-}
WDA_SIGNING_IDENTITY=${WDA_SIGNING_IDENTITY:-129DCD812F1D6C5E696E3F44196A179FC61788A1}
WDA_DERIVED_DATA_PATH=${WDA_DERIVED_DATA_PATH:-/tmp/WebDriverAgentIntegrationDerived}
WDA_LOG_PATH=${WDA_LOG_PATH:-/tmp/wda-from-integration-app.log}

if [ -z "${WDA_DEVICE_UDID}" ]; then
  WDA_DEVICE_UDID="$(xcodebuild \
    -project "${PROJECT_ROOT}/WebDriverAgent.xcodeproj" \
    -scheme WebDriverAgentRunner \
    -showdestinations 2>/dev/null \
    | sed -nE 's/.*platform:iOS,.*id:([^,}]+).*/\1/p' \
    | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
    | head -n 1)"
fi
if [ -z "${WDA_DEVICE_UDID}" ]; then
  echo "Unable to discover an iPhone UDID. Set WDA_DEVICE_UDID explicitly." >&2
  exit 1
fi

RUNNER_APP="${WDA_DERIVED_DATA_PATH}/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"
WDA_PROJECT="${PROJECT_ROOT}/WebDriverAgent.xcodeproj"
WDA_RUNTIME_XCTESTRUN="${WDA_DERIVED_DATA_PATH}/Build/Products/WebDriverAgentRunner.runtime.xctestrun"

cd "${PROJECT_ROOT}"

EXPANDED_CODE_SIGN_IDENTITY="${WDA_SIGNING_IDENTITY}" \
  xcodebuild \
    -project "${WDA_PROJECT}" \
    -scheme WebDriverAgentRunner \
    -configuration Debug \
    -destination "id=${WDA_DEVICE_UDID}" \
    -derivedDataPath "${WDA_DERIVED_DATA_PATH}" \
    -allowProvisioningUpdates \
    ENABLE_DEFAULT_HEADER_SEARCH_PATHS=NO \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    'OTHER_CFLAGS=$(inherited) -Wno-error=poison-system-directories' \
    RUN_CLANG_STATIC_ANALYZER=NO \
    build-for-testing >> "${WDA_LOG_PATH}" 2>&1

GENERATED_XCTESTRUN="$(find "${WDA_DERIVED_DATA_PATH}/Build/Products" \
  -maxdepth 1 -name 'WebDriverAgentRunner_iphoneos*.xctestrun' \
  -print | head -n 1)"
if [ -z "${GENERATED_XCTESTRUN}" ]; then
  echo "Unable to locate the generated WebDriverAgentRunner xctestrun file." >&2
  exit 1
fi

cp -f "${GENERATED_XCTESTRUN}" "${WDA_RUNTIME_XCTESTRUN}"
/usr/libexec/PlistBuddy \
  -c "Delete :WebDriverAgentRunner:EnvironmentVariables:WDA_DEVICE_UDID" \
  "${WDA_RUNTIME_XCTESTRUN}" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Add :WebDriverAgentRunner:EnvironmentVariables:WDA_DEVICE_UDID string ${WDA_DEVICE_UDID}" \
  "${WDA_RUNTIME_XCTESTRUN}"

echo "Starting WDA with device UDID ${WDA_DEVICE_UDID}" >> "${WDA_LOG_PATH}"
exec env EXPANDED_CODE_SIGN_IDENTITY="${WDA_SIGNING_IDENTITY}" xcodebuild \
  -xctestrun "${WDA_RUNTIME_XCTESTRUN}" \
  -destination "id=${WDA_DEVICE_UDID}" \
  test-without-building \
