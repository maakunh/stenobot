#!/bin/bash
set -uo pipefail

# ===== 設定読み込み =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"
LOCAL_REC_DIR="${LOCAL_REC_DIR:-$BASE/recordings_local}"   # 録音の一次書き込み先（内蔵ディスク）
MIN_FREE_KB=$((5*1024*1024))                               # 5GB
WARN_COOLDOWN=3600                                         # 同種の警告メールを再送するまでの秒数
WARN_DIR="$BASE/.warn"

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
#   注意: ffmpeg の "time=" 表示はタイムスタンプ基準であってサンプル数ではない。
#         損失の有無は必ず出力バイト数か ffprobe の duration で確認すること。
#
# 【注意】sox の CoreAudio ドライバはデバイス名指定が効かない
#   （"can not get audio device properties" で失敗する）。そのため
#   **システムのデフォルト入力デバイス**から録る。
#   システム設定 → サウンド → 入力 を目的のオーディオIFにしておくこと。
#   取り違えは下の起動時チェック（無音判定）が検知する。
#
# 【注意】マイク権限（TCC）について
#   SSHセッションから直接起動すると macOS がマイクへのアクセスを拒否し
#   （"Policy disallows prompt"）、エラーではなく全ゼロの無音が録れる。
#   LaunchAgent 経由（launchctl kickstart 含む）ならGUIログインセッションの
#   文脈で動くため、SSHから操作しても問題ない。
#   → install_launchagents.sh でのLaunchAgent運用を推奨。
#   手動で直接起動する場合は画面共有か本体の画面上のTerminalから行うこと。
# ==========================================================================

mkdir -p "$LOCAL_REC_DIR" "$WARN_DIR"

# 同種の警告メールを連発しない。$1=種別キー $2=件名 $3=本文
# LaunchAgent の KeepAlive で再起動を繰り返す場合、これが無いと
# 起動のたびに警告メールが飛ぶ。
warn_once() {
  local key="$1" subject="$2" body="$3" stamp last now
  stamp="$WARN_DIR/$key"
  now=$(date '+%s'); last=0
  [[ -f "$stamp" ]] && last=$(cat "$stamp" 2>/dev/null || echo 0)
  (( now - last < WARN_COOLDOWN )) && return 0
  printf 'Subject: %s\nTo: %s\nFrom: %s\n\n%s\n' \
    "$subject" "$MAIL_TO" "$MAIL_FROM" "$body" | msmtp "$MAIL_TO" 2>/dev/null || true
  echo "$now" > "$stamp"
}

# ===== NASマウント確認（警告のみ・録音は継続）=====
# 録音先は内蔵ディスクなのでNASは不要。NASが無くても録音は続け、
# 移送は mover.sh がNAS復旧後に自動で追いつく。
# （ここで exit すると、LaunchAgentのKeepAliveでログイン直後の
#   マウント前に無限再起動になってしまう）
if ! "$SCRIPT_DIR/ensure_nas.sh" >/dev/null 2>&1; then
  echo "$(date '+%F %T') WARN: NAS未マウント。録音はローカルに継続し、移送は mover.sh に任せる。" >&2
  warn_once nas_unmounted "[警告] NAS未マウント（録音は継続）" \
    "NASがマウントされていないため、録音ファイルをNASへ移送できません。録音は内蔵ディスクに継続しています。手動でマウントすれば mover.sh が自動で追いつきます。"
fi

# ===== 空き容量チェック（警告のみ・録音は継続）=====
AVAIL_KB=$(df -k "$LOCAL_REC_DIR" | awk 'NR==2{print $4}')
if (( AVAIL_KB < MIN_FREE_KB )); then
  warn_once disk_low "[警告] 内蔵ディスク空き容量不足（録音先）" \
    "録音先 $LOCAL_REC_DIR の空き容量が5GB未満です。移送(mover.sh)が停止していないか確認してください。"
fi

# ===== 起動時チェック：3秒録って「音が入っているか」を確かめる ==========
# これが無いと、下記のどれでもエラーが出ないまま無音を録り続けてしまう。
#   - マイク権限が拒否された場合（全ゼロが実時間ちょうどで返る）
#   - デフォルト入力デバイスが別のものに変わっていた場合
#   - 受信機の電源が落ちている場合
CHECK_WAV="$LOCAL_REC_DIR/.startup_check.wav"
rm -f "$CHECK_WAV"
# rec の標準エラーは捨てずに記録する。捨てていたために
# 「デバイスが開けない」のか「権限が無い」のかを切り分けられなかった。
REC_ERR=$(rec -q -c 2 -r 48000 "$CHECK_WAV" trim 0 3 2>&1)
REC_RC=$?
if (( REC_RC != 0 )) || [[ ! -s "$CHECK_WAV" ]]; then
  echo "$(date '+%F %T') ERROR: 起動時チェックの録音に失敗しました (rc=${REC_RC}): ${REC_ERR:-出力なし}" >&2
  warn_once rec_failed "[警告] 録音開始前チェックに失敗" \
    "rec(sox)での試し録りに失敗したため録音を開始しませんでした。

rc=${REC_RC}
${REC_ERR:-（エラー出力なし）}

確認してください:
 - マイク権限（システム設定→プライバシーとセキュリティ→マイク）
 - システム設定→サウンド→入力 のデバイス選択"
  rm -f "$CHECK_WAV"
  exit 1
fi
MEANVOL=$(ffmpeg -hide_banner -nostats -i "$CHECK_WAV" -af volumedetect -f null - 2>&1 \
          | sed -n 's/.*mean_volume: \(-*[0-9.]*\) dB.*/\1/p' | head -1)
rm -f "$CHECK_WAV"
# 無音(デジタルゼロ)は -91dB。-80dB より小さければ音が来ていないとみなす。
if [[ -z "$MEANVOL" ]] || awk -v v="$MEANVOL" 'BEGIN{exit !(v < -80)}'; then
  echo "$(date '+%F %T') ERROR: 入力が無音です(mean_volume=${MEANVOL:-取得失敗}dB)。録音を開始しません。" >&2
  warn_once silent_input "[警告] 入力が無音のため録音を開始しませんでした" \
    "試し録りの音量が ${MEANVOL:-取得失敗} dB でした（無音は約-91dB）。

確認してください:
 - マイク権限（SSHから直接起動していないか）
 - システム設定→サウンド→入力 が目的のオーディオIFになっているか
 - 受信機の電源とケーブル"
  exit 1
fi
echo "$(date '+%F %T') 起動時チェックOK (mean_volume=${MEANVOL}dB)。録音を開始します。"
# 正常に開始できたので、無音・録音失敗の警告履歴はリセットする
rm -f "$WARN_DIR/silent_input" "$WARN_DIR/rec_failed"

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
