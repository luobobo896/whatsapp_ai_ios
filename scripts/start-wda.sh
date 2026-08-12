#!/usr/bin/env bash
# 启动 WDA 服务器（iPhone 真机，前台常驻；Ctrl-C 停止）
# 用法:
#   ./scripts/start-wda.sh                       # 自动探测第一台 iPhone
#   ./scripts/start-wda.sh --udid <UDID>         # 指定设备
#   ./scripts/start-wda.sh --identity <SHA1>     # 钥匙串有重复证书时指定签名身份
# 环境变量: WDA_TEAM（必填，Apple Team ID）/ WDA_UDID / WDA_SIGN_IDENTITY（优先级: 参数 > 环境变量 > 自动探测）
# WhatsAppDeviceAgent（并入 WDA）:
#   WDA_PLATFORM_URL   平台地址，默认 https://hk.hsddns.com
#   WDA_ENROLL_CODE    一次性注册码；设置后 WDA 启动时自动注册/心跳/WSS（未设置则 WDA 保持纯净）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/WebDriverAgent.xcodeproj"
SCHEME="WebDriverAgentRunner"

# ---- 参数解析 ----
UDID=""; IDENTITY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | head -20; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---- Team：优先 WDA_TEAM 环境变量（主工程已废弃删除，不再自动读取）----
TEAM="${WDA_TEAM:-}"
[ -n "$TEAM" ] || { echo "错误: 未设置 WDA_TEAM（Apple Team ID，例如 WDA_TEAM=A3JP3VUZ78 ./scripts/start-wda.sh --udid ...）"; exit 1; }

# ---- UDID：参数 > 环境变量 > 自动探测（xctrace 里第一台 iPhone）----
UDID="${WDA_UDID:-$UDID}"
if [ -z "$UDID" ]; then
  UDID="$(xcrun xctrace list devices 2>/dev/null | grep -i iphone | head -1 | sed -n 's/.*(\([0-9A-F]\{8\}-[0-9A-F-]\{25,36\}\))\s*$/\1/p' | tr -d ' ')"
fi
[ -n "$UDID" ] || { echo "错误: 未指定 UDID（--udid 或 WDA_UDID），且未探测到 iPhone"; echo "可用设备:"; xcrun xctrace list devices 2>/dev/null | grep -i iphone; exit 1; }
echo "设备 UDID: $UDID"
echo "Team:      $TEAM"

# ---- 签名身份：钥匙串存在同名重复证书时必须显式指定，否则后处理重签会报 ambiguous ----
if [ -z "$IDENTITY" ]; then
  IDENTITY="${WDA_SIGN_IDENTITY:-}"
fi
if [ -z "$IDENTITY" ]; then
  # 统计同名开发证书是否重复
  DUPS="$(security find-identity -p codesigning -v 2>/dev/null | grep -oE '"Apple Development: [^"]+"' | sort | uniq -d | head -1)"
  if [ -n "$DUPS" ]; then
    echo "警告: 钥匙串存在重复开发证书（$DUPS）。"
    echo "      请用 --identity <SHA1> 指定 profile 引用的证书（security find-identity -p codesigning -v 查看）："
    security find-identity -p codesigning -v 2>/dev/null | grep -i "Apple Development"
    exit 1
  fi
fi

ARGS=(-project "$PROJECT" -scheme "$SCHEME" -destination "id=$UDID" -allowProvisioningUpdates)
[ -n "$TEAM" ] && ARGS+=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic)
[ -n "$IDENTITY" ] && ARGS+=(EXPANDED_CODE_SIGN_IDENTITY="$IDENTITY")

if [ -n "${WDA_ENROLL_CODE:-}" ]; then
  echo "Agent: 已配置 WDA_ENROLL_CODE，将自动注册 ${WDA_PLATFORM_URL:-https://hk.hsddns.com}"
  echo "构建测试包并注入 agent 环境变量（xcodebuild test 不透传 shell env，需改 xctestrun）..."
  DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/wda-derived.XXXXXX")"
  BUILD_ARGS=(-project "$PROJECT" -scheme "$SCHEME" -destination "id=$UDID" -allowProvisioningUpdates -derivedDataPath "$DERIVED")
  [ -n "$TEAM" ] && BUILD_ARGS+=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic)
  [ -n "$IDENTITY" ] && BUILD_ARGS+=(EXPANDED_CODE_SIGN_IDENTITY="$IDENTITY")
  xcodebuild "${BUILD_ARGS[@]}" build-for-testing || exit 1
  XCRUN="$(find "$DERIVED" -name '*.xctestrun' | head -1)"
  [ -n "$XCRUN" ] || { echo "错误: 未找到 xctestrun"; exit 1; }
  python3 - "$XCRUN" "${WDA_ENROLL_CODE}" "${WDA_PLATFORM_URL:-https://hk.hsddns.com}" <<'PYEOF'
import plistlib, sys
path, code, platform = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'rb') as f:
    data = plistlib.load(f)
runner = data.get('WebDriverAgentRunner', {})
env = dict(runner.get('EnvironmentVariables', {}))
env['WDA_ENROLL_CODE'] = code
env['WDA_PLATFORM_URL'] = platform
runner['EnvironmentVariables'] = env
data['WebDriverAgentRunner'] = runner
with open(path, 'wb') as f:
    plistlib.dump(data, f)
PYEOF
  echo "已注入 agent 环境变量，启动 WDA（前台常驻，Ctrl-C 停止）..."
  cd "$ROOT"
  exec xcodebuild test-without-building -xctestrun "$XCRUN" -destination "id=$UDID" -derivedDataPath "$DERIVED"
else
  echo "Agent: 未配置 WDA_ENROLL_CODE，WDA 保持纯净（不注册平台）"
  echo "启动 WDA（前台常驻，Ctrl-C 停止）..."
  cd "$ROOT"
  exec xcodebuild "${ARGS[@]}" test
fi
