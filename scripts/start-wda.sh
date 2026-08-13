#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

# 签名身份：自动从钥匙串挑选第一个未吊销的 Apple Development 证书
# （旧的 129DCD81... 已失效，不再硬编码）。
WDA_SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -v CSSMERR_TP_CERT_REVOKED \
  | awk '/Apple Development/ {print $2; exit}')"
if [ -z "${WDA_SIGNING_IDENTITY}" ]; then
  echo "No valid Apple Development signing identity found in keychain." >&2
  exit 1
fi
echo "Using signing identity: ${WDA_SIGNING_IDENTITY}" >&2
WDA_DERIVED_DATA_PATH=${WDA_DERIVED_DATA_PATH:-/tmp/WebDriverAgentIntegrationDerived}
WDA_LOG_PATH=${WDA_LOG_PATH:-/tmp/wda-from-integration-app.log}

# 每次只接入一台手机：UDID 全自动从 USB 获取（ioreg 的 UsbAppleDeviceUDID，40 位经典格式），
# 无需环境变量或参数。
WDA_DEVICE_UDID="$(ioreg -p IOUSB -l -w0 2>/dev/null \
  | sed -nE 's/.*"UsbAppleDeviceUDID" = "([0-9A-Fa-f]{40})".*/\1/p' \
  | head -n 1)"
# 兜底：xcodebuild 可用目标里的 40 位真机 UDID（排除 "Any iOS Device" 占位符）。
if [ -z "${WDA_DEVICE_UDID}" ]; then
  WDA_DEVICE_UDID="$(xcodebuild \
    -project "${PROJECT_ROOT}/WebDriverAgent.xcodeproj" \
    -scheme WebDriverAgentRunner \
    -showdestinations 2>/dev/null \
    | sed -nE 's/.*platform:iOS, id:([0-9A-Fa-f]{40}).*/\1/p' \
    | head -n 1)"
fi
if [ -z "${WDA_DEVICE_UDID}" ]; then
  echo "未发现 USB 连接的真机 UDID：请确认 iPhone 已连接、解锁并信任此电脑。" >&2
  exit 1
fi
echo "目标设备 UDID: ${WDA_DEVICE_UDID}" >&2

# 上报 UDID 与目标机一致（同一台手机，无需单独配置）。
WDA_REPORTED_UDID="${WDA_DEVICE_UDID}"
echo "上报设备 UDID: ${WDA_REPORTED_UDID}" >&2

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
  -c "Add :WebDriverAgentRunner:EnvironmentVariables:WDA_DEVICE_UDID string ${WDA_REPORTED_UDID}" \
  "${WDA_RUNTIME_XCTESTRUN}"

echo "Starting WDA: destination=${WDA_DEVICE_UDID} reportedUDID=${WDA_REPORTED_UDID}" >> "${WDA_LOG_PATH}"
exec env EXPANDED_CODE_SIGN_IDENTITY="${WDA_SIGNING_IDENTITY}" xcodebuild \
  -xctestrun "${WDA_RUNTIME_XCTESTRUN}" \
  -destination "id=${WDA_DEVICE_UDID}" \
  test-without-building \
