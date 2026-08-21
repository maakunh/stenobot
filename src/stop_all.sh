#!/bin/bash
# 録音・解析を停止する（NASのアンマウントはしない）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

echo "録音・解析を停止します..."
pkill -f "analyzer_loop.sh" 2>/dev/null && echo "解析ループ停止" || echo "解析ループは動いていません"
# 録音は rec(sox) → ffmpeg のパイプ構成。
# rec を先に止めると ffmpeg が EOF を受けて録音中セグメントを正しく閉じるので、
# 必ず rec → ffmpeg の順で止める。
if pkill -f "rec -q -c 2 -r 48000" 2>/dev/null; then
  echo "取り込み(rec)停止"
  sleep 3   # ffmpeg がセグメントを閉じ終わるのを待つ
else
  echo "取り込み(rec)は動いていません"
fi
pkill -f "segment.*radio_" 2>/dev/null && echo "録音(ffmpeg)停止" || echo "録音(ffmpeg)は動いていません"
# 移送ループは録音停止のあとに止める。
# 停止直前まで録っていた最後の1本は、mover.sh が STALE_MIN(10分) 経過後に
# 移送する仕組みのため、ここで即座に止めると内蔵ディスクに残る。
# 残った場合は start_all.sh で再開すれば回収される。
pkill -f "mover.sh" 2>/dev/null && echo "移送ループ停止" || echo "移送ループは動いていません"
rmdir "$BASE/.analyzer.lock.d" 2>/dev/null || true

PENDING=$(ls -1 "${LOCAL_REC_DIR:-$BASE/recordings_local}"/radio_*.mp3 2>/dev/null | wc -l | tr -d ' ')
if [ "${PENDING:-0}" -gt 0 ]; then
  echo "注意: 内蔵ディスクに未移送の録音が ${PENDING} 本あります。"
  echo "      start_all.sh で再開すれば移送ループが自動で回収します。"
fi
echo "完了。"
