#!/bin/bash
# ============================================================
# 完成した録音セグメントを内蔵ディスクからNASへ移送する常駐ループ。
#
# recorder.sh は取りこぼし防止のため内蔵ディスク($LOCAL_REC_DIR)に録音する。
# このスクリプトが、録音の終わったセグメントだけをNASのrecordings/へ移し、
# 移送完了と同時に .done マーカーを作成する。
#
# mark_done.sh / analyzer.sh は変更不要:
#   - NASへは完成したファイルしか置かれない
#   - .done はこのスクリプトが打つので mark_done.sh は素通りする
#     （mark_done.sh は marker が既にあれば何もしない）
#   - コピー中は "radio_*.mp3" に一致しない一時名(.xxx.part)を使うため、
#     mark_done.sh が中途半端なファイルを完成扱いする事故が起きない
#
# set -e は付けない。常駐ループなので個別の失敗で死なせない。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

REC_DIR="$NAS/recordings"
LOCAL_REC_DIR="${LOCAL_REC_DIR:-$BASE/recordings_local}"

INTERVAL=60      # 巡回間隔（秒）
STALE_MIN=10     # 最新ファイルでもmtimeがこれより古ければ「録音終了」とみなす（分）
WARN_COOLDOWN=3600
WARN_STAMP="$BASE/.mover_warned"

mkdir -p "$LOCAL_REC_DIR"

warn_once() {
  # 同じ警告メールを連発しないよう、最後の送信から WARN_COOLDOWN 秒あけて送る
  local subject="$1" body="$2" last now
  now=$(date '+%s')
  last=0
  [[ -f "$WARN_STAMP" ]] && last=$(cat "$WARN_STAMP" 2>/dev/null || echo 0)
  (( now - last < WARN_COOLDOWN )) && return 0
  printf 'Subject: %s\nTo: %s\nFrom: %s\n\n%s\n' \
    "$subject" "$MAIL_TO" "$MAIL_FROM" "$body" | msmtp "$MAIL_TO" 2>/dev/null || true
  echo "$now" > "$WARN_STAMP"
}

while true; do
  if "$SCRIPT_DIR/ensure_nas.sh" >/dev/null 2>&1; then
    mkdir -p "$REC_DIR"

    # 新しい順。最新1件は録音中の可能性があるので原則スキップする。
    files=( $(cd "$LOCAL_REC_DIR" && ls -t radio_*.mp3 2>/dev/null) )
    count=${#files[@]}

    for (( i=0; i<count; i++ )); do
      f="${files[$i]}"
      src="$LOCAL_REC_DIR/$f"
      [[ -f "$src" ]] || continue

      # 最新ファイルは、しばらく更新が無い（＝録音が終わっている）場合のみ移送。
      # これが無いと録音停止時に最後の1本が永久に取り残される。
      if (( i == 0 )); then
        if [[ -n "$(find "$src" -mmin -${STALE_MIN} 2>/dev/null)" ]]; then
          continue
        fi
      fi

      # サイズが安定していることを確認（書き込み完了判定）
      s1=$(stat -f%z "$src" 2>/dev/null) || continue
      sleep 2
      s2=$(stat -f%z "$src" 2>/dev/null) || continue
      [[ "$s1" != "$s2" ]] && continue
      (( s1 == 0 )) && { rm -f "$src"; continue; }

      dest="$REC_DIR/$f"
      part="$REC_DIR/.${f}.part"

      # 既にNASに同じサイズで存在するなら移送済み。ローカルを消して次へ。
      if [[ -e "$dest" ]]; then
        ds=$(stat -f%z "$dest" 2>/dev/null || echo 0)
        if [[ "$ds" == "$s1" ]]; then
          rm -f "$src"
          continue
        fi
        echo "$(date '+%F %T') WARN: $f はNASに異なるサイズで存在（NAS=$ds ローカル=$s1）。上書きする。" >&2
      fi

      # 一時名でコピー → サイズ検証 → 本名へリネーム → .done 作成 → ローカル削除
      rm -f "$part"
      if ! cp "$src" "$part" 2>/dev/null; then
        echo "$(date '+%F %T') ERROR: コピー失敗 $f" >&2
        rm -f "$part"
        warn_once "[警告] 録音ファイルのNAS移送に失敗" \
          "録音ファイル $f のNASへのコピーに失敗しました。NASの状態と空き容量を確認してください。"
        continue
      fi
      ps=$(stat -f%z "$part" 2>/dev/null || echo 0)
      if [[ "$ps" != "$s1" ]]; then
        echo "$(date '+%F %T') ERROR: サイズ不一致 $f (元=$s1 コピー先=$ps)" >&2
        rm -f "$part"
        continue
      fi
      if mv -f "$part" "$dest" 2>/dev/null; then
        touch "${dest}.done"
        rm -f "$src"
        echo "$(date '+%F %T') moved $f (${s1} bytes)"
      else
        echo "$(date '+%F %T') ERROR: リネーム失敗 $f" >&2
        rm -f "$part"
      fi
    done

    # 移送が滞っていないか監視（録音1本=約58MB、通常は0〜1本しか残らない）
    pending=$(cd "$LOCAL_REC_DIR" && ls -1 radio_*.mp3 2>/dev/null | wc -l | tr -d ' ')
    if (( pending > 6 )); then
      warn_once "[警告] 録音ファイルの移送が滞っています" \
        "内蔵ディスクに未移送の録音が ${pending} 本たまっています。NASへの書き込みを確認してください。"
    fi
  else
    echo "$(date '+%F %T') NAS未マウント。移送をスキップ。" >&2
    warn_once "[警告] NAS未マウントで録音の移送が停止" \
      "NASがマウントされていないため、録音ファイルをNASへ移送できません。内蔵ディスクに滞留します。"
  fi

  sleep "$INTERVAL"
done
