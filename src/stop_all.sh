#!/bin/bash
# 録音・解析を停止する（NASのアンマウントはしない）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

echo "録音・解析を停止します..."
pkill -f "analyzer_loop.sh" 2>/dev/null && echo "解析ループ停止" || echo "解析ループは動いていません"
pkill -f "segment.*radio_" 2>/dev/null && echo "録音停止" || echo "録音は動いていません"
rmdir "$BASE/.analyzer.lock.d" 2>/dev/null || true
echo "完了。"
