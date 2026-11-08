#!/bin/bash
# End-to-end smoke test for the built app.
#
#   ./scripts/smoke.sh [folder]
#
# 1. builds the debug binary
# 2. runs it headless-ish with --add-folder / --scan-and-export
# 3. prints what the UI would show (counts, size groups, timings)
#
# An empty HOME is used so the test never touches your real library or cache.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
FOLDER="${1:-/tmp/imgmgr/imgs}"

export TMPDIR="$ROOT/.cache/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/.cache/clang"
export SWIFT_MODULECACHE_PATH="$ROOT/.cache/clang"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

if [ ! -d "$FOLDER" ]; then
  echo "Folder not found: $FOLDER" >&2
  exit 1
fi

echo "Building debug binary"
swift build --disable-sandbox >/dev/null 2>&1

BIN="$ROOT/.build/debug/ImageManager"
# Isolated folders.json / filters.json / index.json so the test never touches
# your real library or remembered filters.
SANDBOX_HOME="$ROOT/.cache/smoke-home"
SANDBOX_SUPPORT="$SANDBOX_HOME/support"
rm -rf "$SANDBOX_HOME" "$ROOT/.cache/smoke-report.json"
mkdir -p "$SANDBOX_HOME/Library/Application Support" "$SANDBOX_HOME/Library/Caches" "$SANDBOX_SUPPORT"

echo "Launching app against ${FOLDER}"
HOME="$SANDBOX_HOME" IMAGE_MANAGER_SUPPORT_DIR="$SANDBOX_SUPPORT" timeout 120 "$BIN" \
  --add-folder "$FOLDER" \
  --scan-and-export "$ROOT/.cache/smoke-report.json" \
  2>"$ROOT/.cache/smoke.log" || true

# The report now carries the dimension filter state; print it if any.
if [ ! -f "$ROOT/.cache/smoke-report.json" ]; then
  echo "✗ App did not produce a report. Log tail:" >&2
  tail -20 "$ROOT/.cache/smoke.log" >&2
  exit 1
fi

python3 - "$ROOT/.cache/smoke-report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"✓ scanned {d['count']} PNG files ({d['totalBytes']/1e6:.1f} MB) in {d['scanSeconds']*1000:.0f} ms")
print("  按宽高比分类:")
for k, v in sorted(d['aspect'].items(), key=lambda kv: -kv[1]):
    print(f"    {k:<18} {v:>6}")
print("  最常见尺寸:")
for g in d['exactSizes'][:8]:
    print(f"    {g['size']:<14} {g['count']:>6}")
print(f"  缩略图已生成: {d['cachedThumbnails']} 张")
if d.get('filterActive'):
    print(f"  长宽筛选: {d['filterSummary']}  → 显示 {d['filteredCount']} 张（隐藏 {d['hiddenByFilter']}）")
PY
