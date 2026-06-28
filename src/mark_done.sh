#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"
REC_DIR="$NAS/recordings"

# NASマウント確認（手動マウント前提）
"$SCRIPT_DIR/ensure_nas.sh" || { echo "NAS未マウント、skip"; exit 0; }
cd "$REC_DIR" || exit 0

# mp3を新しい順に並べ、最新1個（録音中）を除く全てに .done を付与
shopt -s nullglob
FILES=( $(ls -t radio_*.mp3 2>/dev/null) )
COUNT=${#FILES[@]}
(( COUNT < 2 )) && exit 0

for (( i=1; i<COUNT; i++ )); do
  f="${FILES[$i]}"
  marker="${f}.done"
  if [[ ! -e "$marker" ]]; then
    # サイズ安定を確認（書き込み完了判定）
    s1=$(stat -f%z "$f"); sleep 2; s2=$(stat -f%z "$f")
    [[ "$s1" == "$s2" ]] && touch "$marker"
  fi
done
