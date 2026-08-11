#!/usr/bin/env bash
# 构建 EasyTier iOS XCFramework（设计 6.3）。
# 前置：third_party/easytier 已克隆到固定 commit；Rust 1.95 工具链已就绪。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EASYTIER_DIR="$REPO_ROOT/third_party/easytier"
SOURCE_COMMIT_FILE="$REPO_ROOT/Vendor/EasyTier/SOURCE_COMMIT"
OUT_DIR="$REPO_ROOT/Vendor/EasyTier/EasyTierFFI.xcframework"
RUST_VERSION="1.95"

if [ ! -d "$EASYTIER_DIR" ]; then
  echo "error: $EASYTIER_DIR 不存在，请先按 third_party/easytier/README.md 克隆 EasyTier v2.6.4" >&2
  exit 1
fi

# 1. 核验固定 commit 且工作区干净（设计 6.3）
EXPECTED_COMMIT="$(grep -v '^#' "$SOURCE_COMMIT_FILE" | grep -v '^$' | head -1)"
ACTUAL_COMMIT="$(git -C "$EASYTIER_DIR" rev-parse HEAD)"
if [ "$EXPECTED_COMMIT" = "PENDING_V2.6.4_COMMIT" ]; then
  echo "error: SOURCE_COMMIT 未填充，请先按 README 填入 v2.6.4 提交 SHA" >&2
  exit 1
fi
if [ "$ACTUAL_COMMIT" != "$EXPECTED_COMMIT" ]; then
  echo "error: EasyTier HEAD=$ACTUAL_COMMIT 不等于固定提交 $EXPECTED_COMMIT" >&2
  exit 1
fi
# 方案 6.2 允许的 fork 最小修改清单；其他 dirty 文件一律拒绝构建
ALLOWED_FORK_FILES="
easytier-contrib/easytier-ffi/Cargo.toml
easytier-contrib/easytier-ffi/src/lib.rs
easytier/src/core.rs
easytier/src/instance/instance.rs
easytier/src/instance_manager.rs
easytier/src/common/constants.rs
"
DIRTY_FILES="$(git -C "$EASYTIER_DIR" status --porcelain | awk '{print $2}')"
for f in $DIRTY_FILES; do
  if ! echo "$ALLOWED_FORK_FILES" | grep -qx "$f"; then
    echo "error: third_party/easytier 存在非预期修改：$f（只允许方案 6.2 的 fork 文件）" >&2
    exit 1
  fi
done

# 2. Rust 版本核验（设计 6.3：锁定 1.95）
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo 未找到（需要 Rust $RUST_VERSION）" >&2
  exit 1
fi
RUSTC_VERSION="$(rustc --version | awk '{print $2}')"
case "$RUSTC_VERSION" in
  "$RUST_VERSION"*) ;;
  *) echo "error: rustc=$RUSTC_VERSION，需要 $RUST_VERSION" >&2; exit 1 ;;
esac

pushd "$EASYTIER_DIR" >/dev/null

# 3. 构建三个架构的静态库（设计 6.3）
# iOS 最低版本：与 Configs/Base.xcconfig 的 IPHONEOS_DEPLOYMENT_TARGET(16.4) 保持一致。
# 不设置时 minos 会跟随构建环境（例如 26.2），链接进 16.4 的 target 会报警
# "built for newer iOS version than being linked"。
MIN_IOS_VERSION="${MIN_IOS_VERSION:-16.4}"
export IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS_VERSION"

for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  rustup target add "$target"
  cargo build --release --locked --target "$target" -p easytier-ffi
done

DEVICE_LIB="target/aarch64-apple-ios/release/libeasytier_ffi.a"
SIM_AARCH64="target/aarch64-apple-ios-sim/release/libeasytier_ffi.a"
SIM_X86_64="target/x86_64-apple-ios/release/libeasytier_ffi.a"

# 4. lipo 合并两个模拟器静态库（设计 6.3）
SIM_UNIVERSAL="target/ios-sim-universal/libeasytier_ffi.a"
mkdir -p "$(dirname "$SIM_UNIVERSAL")"
lipo -create "$SIM_AARCH64" "$SIM_X86_64" -output "$SIM_UNIVERSAL"

# 5. 生成唯一 XCFramework（设计 6.3）
rm -rf "$OUT_DIR"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$REPO_ROOT/Vendor/EasyTier/include" \
  -library "$SIM_UNIVERSAL" -headers "$REPO_ROOT/Vendor/EasyTier/include" \
  -output "$OUT_DIR"

popd >/dev/null

# 6. 符号核验（设计 6.3；基础 ABI 7 函数 + public bridge 3 函数）
"$REPO_ROOT/scripts/verify-easytier-ffi-symbols.sh" "$OUT_DIR"

# 7. 输出 SHA-256（设计 6.3）
find "$OUT_DIR" -type f -print0 | sort -z | xargs -0 shasum -a 256 \
  | shasum -a 256 | awk '{print $1}' > "$OUT_DIR.sha256"
echo "XCFramework 已生成：$OUT_DIR"
echo "SHA-256：$(cat "$OUT_DIR.sha256")"
