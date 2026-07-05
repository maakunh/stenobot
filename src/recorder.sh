#!/bin/bash
set -euo pipefail

# ===== 設定読み込み =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"
REC_DIR="$NAS/recordings"

# 入力サンプルレート（デバイス実レート）。config.sh 未設定なら 48000 を既定にする。
INPUT_RATE="${INPUT_RATE:-48000}"

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
#
# 【v1.1 修正】入力サンプルレートを -i の前で明示する（-ar "$INPUT_RATE"）。
#   avfoundation はデバイス固有レート（多くは 44100/48000）で音声を渡すため、
#   入力レートを宣言せずに出力側 -ar 16000 だけを指定すると、リサンプルが
#   正しく効かず等速コピー扱いになり、再生が短く・早口（ピッチ上昇）になる。
#   例: 実 48000 を 16000 と誤認 → 60分が 48分(=16000/20000相当のズレ)に。
#   入力=INPUT_RATE を宣言 → 出力=16000 で正しくリサンプルされる。
ffmpeg -nostdin -hide_banner -loglevel warning \
  -f avfoundation -ar "$INPUT_RATE" -i "$AUDIO_DEVICE" \
  -ac 1 -ar 16000 -codec:a libmp3lame -b:a 128k \
  -f segment -segment_time "$SEG_SECONDS" \
  -segment_atclocktime 1 \
  -strftime 1 \
  -reset_timestamps 1 \
  "$REC_DIR/radio_%Y%m%d_%H%M.mp3"
