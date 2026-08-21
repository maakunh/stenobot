#!/bin/bash
set -uo pipefail

# ===== 設定読み込み =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"
REC_DIR="$NAS/recordings"                                  # 最終保管先（mover.sh が移送）
LOCAL_REC_DIR="${LOCAL_REC_DIR:-$BASE/recordings_local}"   # 録音の一次書き込み先（内蔵ディスク）
MIN_FREE_KB=$((5*1024*1024))                               # 5GB

# ===== 取り込みは sox(rec) を使う ==========================================
# 【2026-08-21 判明】ffmpeg の avfoundation 音声取り込みは、常にサンプルの
#   15〜19% を落とす。タイムスタンプは実時間どおり進むため、下流は受け取った
#   ものを忠実に書くだけで、書き込み先・リサンプル・エンコード・キューサイズを
#   変えても一切改善しなかった。
#
#   実測（同一デバイス・同一時間帯）:
#     ffmpeg -f avfoundation           600秒の実時間で 487秒  (81.2%)
#     rec (sox/CoreAudio)               60秒の実時間で  60.000秒 (100%)
#     rec | ffmpeg (この構成)          600秒の実時間で 599.976秒 (99.996%)
#
#   切り分けの過程で潰した仮説（いずれも無効だった）:
#     - NAS(SMB)への直接書き込みが詰まっている → 内蔵ディスクでも 81.9%
#     - リサンプル48k→16k / モノラル化が重い   → ネイティブPCMでも 83.5%
#     - mp3エンコードが重い                     → PCMでも変わらず
#     - -thread_queue_size が小さい             → 4096でも 83.2%
#     - バックグラウンド実行のQoS低下           → フォアグラウンドでも 81.2%
#
#   注意: ffmpeg の "time=" 表示はタイムスタンプ基準であってサンプル数ではない。
#         損失の有無は必ず出力バイト数か ffprobe の duration で確認すること。
#         （この見落としで長く原因を取り違えた）
#
#   よって取り込みだけを sox に置き換え、分割・命名・mp3化は従来どおり ffmpeg に
#   任せる。mover.sh / mark_done.sh / analyzer.sh は無変更で動く。
#
# 【注意】sox の CoreAudio ドライバはデバイス名指定が効かない
#   （'Sound Blaster Play! 3' を指定すると "can not get audio device
#   properties" で失敗する）。そのため **システムのデフォルト入力デバイス**
#   から録る。システム設定 → サウンド → 入力 を録音したいデバイスにしておくこと。
#   取り違えは下の起動時チェック（無音判定）で検知する。
#
# 【注意】起動はSSH経由では不可。SSHセッションから起動すると macOS が
#   マイクへのアクセスを拒否し("Policy disallows prompt")、エラーではなく
#   全ゼロの無音が録れる。必ず画面共有か本体の画面上のTerminalから起動する。
#   start_all.sh にSSH起動を拒否するガードを入れてある。
# ==========================================================================

# ===== NASマウント確認（手動マウント前提・自動マウントはしない）=====
if ! "$SCRIPT_DIR/ensure_nas.sh"; then
  echo "$(date '+%F %T') ERROR: NAS未マウント。録音中止。手動でマウントしてください。" >&2
  printf 'Subject: [警告] NAS未マウントで録音停止\nTo: %s\nFrom: %s\n\nNASがマウントされていないため録音を開始できませんでした。手動でマウントしてください。\n' \
    "$MAIL_TO" "$MAIL_FROM" | msmtp "$MAIL_TO" 2>/dev/null || true
  exit 1
fi
mkdir -p "$LOCAL_REC_DIR"

# ===== 空き容量チェック（警告のみ・録音は継続）=====
AVAIL_KB=$(df -k "$LOCAL_REC_DIR" | awk 'NR==2{print $4}')
if (( AVAIL_KB < MIN_FREE_KB )); then
  printf 'Subject: [警告] 内蔵ディスク空き容量不足（録音先）\nTo: %s\nFrom: %s\n\n録音先 %s の空き容量が5GB未満です。移送(mover.sh)が停止していないか確認してください。\n' \
    "$MAIL_TO" "$MAIL_FROM" "$LOCAL_REC_DIR" | msmtp "$MAIL_TO" || true
fi
AVAIL_NAS_KB=$(df -k "$NAS" | awk 'NR==2{print $4}')
if (( AVAIL_NAS_KB < 5*1024*1024 )); then
  printf 'Subject: [警告] NAS空き容量不足\nTo: %s\nFrom: %s\n\nNASの空き容量が5GB未満です。\n' \
    "$MAIL_TO" "$MAIL_FROM" | msmtp "$MAIL_TO" || true
fi

# ===== 起動時チェック：3秒録って「音が入っているか」を確かめる ==========
# これが無いと、下記のどちらでもエラーが出ないまま無音を録り続けてしまう。
#   - SSH起動によりマイク権限が拒否された場合（全ゼロが実時間ちょうどで返る）
#   - デフォルト入力デバイスが別のものに変わっていた場合
CHECK_WAV="$LOCAL_REC_DIR/.startup_check.wav"
rm -f "$CHECK_WAV"
if ! rec -q -c 2 -r 48000 "$CHECK_WAV" trim 0 3 2>/dev/null || [[ ! -s "$CHECK_WAV" ]]; then
  echo "$(date '+%F %T') ERROR: 起動時チェックの録音に失敗しました。" >&2
  printf 'Subject: [警告] 録音開始前チェックに失敗\nTo: %s\nFrom: %s\n\nrec(sox)での試し録りに失敗したため録音を開始しませんでした。入力デバイスを確認してください。\n' \
    "$MAIL_TO" "$MAIL_FROM" | msmtp "$MAIL_TO" 2>/dev/null || true
  rm -f "$CHECK_WAV"
  exit 1
fi
MEANVOL=$(ffmpeg -hide_banner -nostats -i "$CHECK_WAV" -af volumedetect -f null - 2>&1 \
          | sed -n 's/.*mean_volume: \(-*[0-9.]*\) dB.*/\1/p' | head -1)
rm -f "$CHECK_WAV"
# 無音(デジタルゼロ)は -91dB。-80dB より小さければ音が来ていないとみなす。
if [[ -z "$MEANVOL" ]] || awk -v v="$MEANVOL" 'BEGIN{exit !(v < -80)}'; then
  echo "$(date '+%F %T') ERROR: 入力が無音です(mean_volume=${MEANVOL:-取得失敗}dB)。録音を開始しません。" >&2
  printf 'Subject: [警告] 入力が無音のため録音を開始しませんでした\nTo: %s\nFrom: %s\n\n試し録りの音量が %s dB でした（無音は約-91dB）。\n\n確認してください:\n - SSH経由で起動していないか（マイク権限が拒否され無音になります）\n - システム設定→サウンド→入力 が録音したいデバイスになっているか\n - 受信機の電源とケーブル\n' \
    "$MAIL_TO" "$MAIL_FROM" "${MEANVOL:-取得失敗}" | msmtp "$MAIL_TO" 2>/dev/null || true
  exit 1
fi
echo "$(date '+%F %T') 起動時チェックOK (mean_volume=${MEANVOL}dB)。録音を開始します。"

# ===== 録音本体（途切れないセグメント録音）=====
# rec(sox) がデバイスから取り込み、生PCMをパイプで ffmpeg へ渡す。
# ffmpeg は分割・命名・16kHzモノラルmp3化のみを担当する（取り込みには関与しない）。
#   -segment_atclocktime 1 : 壁時計の毎時00分で区切る
#   -strftime 1            : ファイル名に開始時刻を埋め込む
rec -q -c 2 -r 48000 -t raw -e signed -b 16 - \
  | ffmpeg -nostdin -hide_banner -loglevel warning \
      -f s16le -ar 48000 -ac 2 -i - \
      -ac 1 -ar 16000 -codec:a libmp3lame -b:a 128k \
      -f segment -segment_time "$SEG_SECONDS" \
      -segment_atclocktime 1 \
      -strftime 1 \
      -reset_timestamps 1 \
      "$LOCAL_REC_DIR/radio_%Y%m%d_%H%M.mp3"
