#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

"$SCRIPT_DIR/mark_done.sh"
"$SCRIPT_DIR/analyzer.sh"

# 任意：30日より古い「生文字起こし」「解析txt」のみ自動削除。
# 永続保存（削除しない）: recordings/（mp3・マーカー）, corrected/（修正済み文字起こし）。
find "$NAS/transcripts" -name 'radio_*_transcript.txt' -mtime +30 -delete 2>/dev/null || true
find "$NAS/texts"       -name 'radio_*.txt'            -mtime +30 -delete 2>/dev/null || true
