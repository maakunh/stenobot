#!/bin/bash
set -euo pipefail

# ===== 設定読み込み =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"
REC_DIR="$NAS/recordings"

# ===== NASマウント確認（手動マウント前提・自動マウントはしない）=====
if ! "$SCRIPT_DIR/ensure_nas.sh"; then
  echo "$(date '+%F %T') ERROR: NAS未マウント。録音中止。手動でマウントしてください。" >&2
  printf 'Subject: [警告] NAS未マウントで録音停止\nTo: %s\nFrom: %s\n\nNASがマウントされていないため録音を開始できませんでした。手動でマウントしてください。\n' \
    "$MAIL_TO" "$MAIL_FROM" | msmtp "$MAIL_TO" 2>/dev/null || true
  exit 1
fi
mkdir -p "$REC_DIR"

# ===== 空き容量チェック（5GB未満で警告、録音は継続）=====
AVAIL_KB=$(df -k "$REC_DIR" | awk 'NR==2{print $4}')
if (( AVAIL_KB < 5*1024*1024 )); then
  printf 'Subject: [警告] NAS空き容量不足\nTo: %s\nFrom: %s\n\nNASの空き容量が5GB未満です。\n' \
    "$MAIL_TO" "$MAIL_FROM" | msmtp "$MAIL_TO" || true
fi

# ===== 録音本体（途切れないセグメント録音）=====
# -segment_atclocktime 1 : 壁時計の毎時00分で区切る
# -strftime 1            : ファイル名に開始時刻を埋め込む
ffmpeg -nostdin -hide_banner -loglevel warning \
  -f avfoundation -i "$AUDIO_DEVICE" \
  -ac 1 -ar 16000 -codec:a libmp3lame -b:a 128k \
  -f segment -segment_time "$SEG_SECONDS" \
  -segment_atclocktime 1 \
  -strftime 1 \
  -reset_timestamps 1 \
  "$REC_DIR/radio_%Y%m%d_%H%M.mp3"
