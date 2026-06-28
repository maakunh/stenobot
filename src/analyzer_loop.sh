#!/bin/bash
# run_analyzer.sh を5分毎に実行し続けるループ。手動セッションで nohup 常駐させる。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"
while true; do
  "$SCRIPT_DIR/run_analyzer.sh" >> "$BASE/analyzer.out" 2>> "$BASE/analyzer.err"
  sleep 300
done
