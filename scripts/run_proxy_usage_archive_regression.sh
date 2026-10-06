#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGRESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-archive-regression.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR"' EXIT

# 使用独立原生 SwiftPM 清单，避免本机 swiftbuild 布局差异与历史对象混入。
BACKEND_BUILD_DIR="${AIUSAGE_ARCHIVE_BACKEND_BUILD_DIR:-$REGRESSION_DIR/backend}"
swift build --package-path "$PROJECT_DIR/QuotaBackend" --scratch-path "$BACKEND_BUILD_DIR" \
  --build-system native --target QuotaBackend >/dev/null
BACKEND_BIN="$(swift build --package-path "$PROJECT_DIR/QuotaBackend" --scratch-path "$BACKEND_BUILD_DIR" --build-system native --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' \
  "$BACKEND_BIN/description.json" > "$REGRESSION_DIR/backend-objects.txt"

swiftc -O -parse-as-library -swift-version 5 \
  -I "$BACKEND_BIN/Modules" -Xlinker -filelist -Xlinker "$REGRESSION_DIR/backend-objects.txt" \
  "$PROJECT_DIR/AIUsage/Models/ProxyUsageArchive.swift" \
  "$PROJECT_DIR/AIUsage/ViewModels/ProxyViewModel+UsageArchive.swift" \
  "$PROJECT_DIR/scripts/ProxyUsageArchiveRegression.swift" \
  -lsqlite3 -o "$REGRESSION_DIR/archive-regression"

mkdir "$REGRESSION_DIR/home"
CFFIXED_USER_HOME="$REGRESSION_DIR/home" "$REGRESSION_DIR/archive-regression"
# 每个场景使用独立 HOME，避免上个场景的磁盘账本影响初始断言。
SAME_MODEL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-archive-regression.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR" "$SAME_MODEL_DIR"' EXIT
mkdir "$SAME_MODEL_DIR/home"
CFFIXED_USER_HOME="$SAME_MODEL_DIR/home" "$REGRESSION_DIR/archive-regression" --same-model
