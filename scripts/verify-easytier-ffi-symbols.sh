#!/usr/bin/env bash
# 核验 EasyTier XCFramework 导出符号与 easytier_ffi.h 声明一致（设计 6.3/6.2）。
# 基础 ABI 7 个为 v1 内部分发轨必需；public packetFlow bridge 3 个属 M0-E fork 新增，
# 设置 REQUIRE_PACKET_FLOW=1 时要求存在（App Store 轨）。
# 注：Xcode 26.3 的 nm/llvm-nm 无法解析 Rust 1.95 (LLVM22) object 的元数据，
#     符号表改用 strings 从 archive 字符串表提取（带 _ 前缀）。
set -euo pipefail

FRAMEWORK="${1:-Vendor/EasyTier/EasyTierFFI.xcframework}"
HEADER="Vendor/EasyTier/include/easytier_ffi.h"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$FRAMEWORK" in
  /*) ;; # 已是绝对路径
  *) FRAMEWORK="$REPO_ROOT/$FRAMEWORK" ;;
esac
case "$HEADER" in
  /*) ;;
  *) HEADER="$REPO_ROOT/$HEADER" ;;
esac

BASE_SYMBOLS=(
  parse_config
  run_network_instance
  set_tun_fd
  retain_network_instance
  collect_network_infos
  get_error_msg
  free_string
)
PACKET_FLOW_SYMBOLS=(
  set_packet_flow_io
  push_packet_flow_packet
  close_packet_flow_io
)
REQUIRE_PACKET_FLOW="${REQUIRE_PACKET_FLOW:-0}"

[ -d "$FRAMEWORK" ] || { echo "error: $FRAMEWORK 不存在" >&2; exit 1; }

# header 必须声明全部 ABI
for func in "${BASE_SYMBOLS[@]}" "${PACKET_FLOW_SYMBOLS[@]}"; do
  grep -q "${func}(" "$HEADER" || { echo "error: header 缺少声明 ${func}" >&2; exit 1; }
done

FAIL=0
for lib in $(find "$FRAMEWORK" -name '*.a'); do
  # 从字符串表提取导出符号（Mach-O nlist 字符串，前缀 _）
  export_has() { strings "$lib" 2>/dev/null | grep -x "_$1" >/dev/null; }

  for func in "${BASE_SYMBOLS[@]}"; do
    export_has "$func" || { echo "error: $lib 缺少基础 ABI 符号 $func" >&2; FAIL=1; }
  done
  if [ "$REQUIRE_PACKET_FLOW" = "1" ]; then
    for func in "${PACKET_FLOW_SYMBOLS[@]}"; do
      export_has "$func" || { echo "error: $lib 缺少 public packetFlow ABI 符号 $func" >&2; FAIL=1; }
    done
  fi
done

if [ "$FAIL" -eq 0 ]; then
  if [ "$REQUIRE_PACKET_FLOW" = "1" ]; then
    echo "symbols OK: 10 个 ABI 符号在全部架构中核验通过（含 public packetFlow bridge）"
  else
    echo "symbols OK: 7 个基础 ABI 符号在全部架构中核验通过（packetFlow 3 个待 M0-E）"
  fi
fi
exit "$FAIL"
