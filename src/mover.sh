#!/bin/bash
# ============================================================
# 録音済みセグメントをNASへ移送する常駐ループ。
#
# recorder.sh は内蔵ディスク($LOCAL_REC_DIR)へ録音する。
# このスクリプトが、録音の終わったセグメントをNASのrecordings/へ移し、
# 移送完了と同時に .done マーカーを作成する。
#
# mark_done.sh / analyzer.sh は変更不要:
#   - NASへは完成済みのmp3しか置かれない（従来と同じ形式・同じ名前）
#   - .done はこのスクリプトが打つので mark_done.sh は素通りする
#   - コピー中の一時ファイルは .staging/ サブディレクトリに置くため、
#     mark_done.sh の "radio_*.mp3" グロブには一致しない
#
# 旧方式で残った .wav は 16kHzモノラルmp3 に変換してから移送する。
#
# 【2026-08-24 追加】NAS I/O ハング対策のタイムアウト
#   NASのI/Oが固まると cp / mv / stat がブロックしたまま戻らず、
#   このループごと停止する。実際に 15:00 から約4時間、移送と解析が
#   止まったまま自力復帰できなかった（ensure_nas.sh による再マウントも
#   ループが回らなければ実行されないため）。
#   対策として、NASを触る操作をすべて run_with_timeout で包む。
#   タイムアウトしても次の巡回に進むので、ensure_nas.sh の再マウントが効く。
#
#   一時ファイルは .staging/ に毎回ユニークな名前で作る。
#   ハングして放棄したコピーが、次の再試行の一時ファイルを壊さないため。
#   放棄された一時ファイルは STALE_PART_MIN 経過後に掃除する。
#
# set -e は付けない。常駐ループなので個別の失敗で死なせない。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

REC_DIR="$NAS/recordings"
STAGING="$REC_DIR/.staging"
LOCAL_REC_DIR="${LOCAL_REC_DIR:-$BASE/recordings_local}"

INTERVAL=60          # 巡回間隔（秒）
STALE_MIN=10         # 最新ファイルでもmtimeがこれより古ければ「録音終了」とみなす（分）
PENDING_WARN=3       # 未処理がこの本数を超えたら警告
WARN_COOLDOWN=3600
WARN_STAMP="$BASE/.mover_warned"

# --- タイムアウト値（秒）---
# 実測では 58MB のコピーに約90秒。余裕を見て10分で打ち切る。
CP_TIMEOUT=600
NAS_OP_TIMEOUT=60    # stat / mv / touch / rm など軽い操作
ENSURE_TIMEOUT=90    # ensure_nas.sh（再マウントを試みるので長め）
CONV_TIMEOUT=600     # wav→mp3 変換（ローカル同士だが念のため）
STALE_PART_MIN=120   # .staging に残った一時ファイルを掃除するまでの分数
CLEAN_EVERY=60       # 何巡ごとに .staging を掃除するか（60巡=約1時間）

mkdir -p "$LOCAL_REC_DIR"

# ===== タイムアウト付きでコマンドを実行する =====
# 戻り値: コマンドの終了コード / タイムアウト時は 124
# 注意: NASのI/Oでブロックした子プロセスはSIGKILLでも即座に死なないことが
#       ある。そのため打ち切り後は wait せずに放置し、ループを進める。
#       （マウントが復旧した時点で子は死ぬ）
#       監視は0.2秒刻み。1秒刻みだと即座に終わる操作でも1秒かかり、
#       1ファイルあたり6回のNAS操作で6秒以上を無駄にするため。
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$! ticks=0
  local max=$(( secs * 5 ))
  while (( ticks < max )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return $?
    fi
    sleep 0.2
    ticks=$(( ticks + 1 ))
  done
  # disown してから止める。そうしないと bash が "Terminated: 15" という
  # ジョブ通知を stderr に出し、mover.err がノイズで埋まる。
  disown "$pid" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
  sleep 2
  kill -KILL "$pid" 2>/dev/null
  return 124
}

# NAS上のファイルサイズを取得（ハング対策つき）。取得できなければ空を返す。
nas_size() {
  local f="$1" out
  out=$(run_with_timeout "$NAS_OP_TIMEOUT" stat -f%z "$f" 2>/dev/null) || return 1
  printf '%s' "$out"
}

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

# NASへ mp3 を送り込み、.done を打ってから元ファイルを消す。
# $1=送るmp3のパス  $2=NAS上の最終ファイル名  $3以降=成功時に削除するファイル群
deliver() {
  local srcmp3="$1" name="$2"; shift 2
  local dest="$REC_DIR/$name"
  local part="$STAGING/${name}.$(date '+%s').$$.part"
  local size ps ds rc

  size=$(stat -f%z "$srcmp3" 2>/dev/null || echo 0)   # ローカルなのでハングしない
  (( size == 0 )) && { echo "$(date '+%F %T') ERROR: 送るファイルが空 $name" >&2; return 1; }

  # 既にNASに同じサイズで存在するなら移送済み
  if ds=$(nas_size "$dest") && [[ -n "$ds" ]]; then
    if [[ "$ds" == "$size" ]]; then
      echo "$(date '+%F %T') 既にNASに存在 $name。ローカルを削除。"
      rm -f "$@" "$srcmp3"
      return 0
    fi
    echo "$(date '+%F %T') WARN: $name はNASに異なるサイズで存在（NAS=$ds 新=$size）。上書きする。" >&2
  fi

  run_with_timeout "$NAS_OP_TIMEOUT" mkdir -p "$STAGING" || {
    echo "$(date '+%F %T') ERROR: .staging の作成に失敗/タイムアウト" >&2
    return 1
  }

  run_with_timeout "$CP_TIMEOUT" cp "$srcmp3" "$part"
  rc=$?
  if (( rc != 0 )); then
    if (( rc == 124 )); then
      echo "$(date '+%F %T') ERROR: NASへのコピーがタイムアウト(${CP_TIMEOUT}秒) $name。次の巡回で再試行する。" >&2
      warn_once "[警告] NASへの移送がタイムアウトしました" \
        "録音ファイル $name のNASへのコピーが ${CP_TIMEOUT} 秒で完了しませんでした。NASがハングしている可能性があります。録音は継続していますが、ファイルは内蔵ディスクに滞留します。"
    else
      echo "$(date '+%F %T') ERROR: NASへのコピー失敗(rc=$rc) $name" >&2
      warn_once "[警告] 録音ファイルのNAS移送に失敗" \
        "録音ファイル $name のNASへのコピーに失敗しました。NASの状態と空き容量を確認してください。"
    fi
    run_with_timeout "$NAS_OP_TIMEOUT" rm -f "$part" 2>/dev/null
    return 1
  fi

  ps=$(nas_size "$part") || ps=""
  if [[ "$ps" != "$size" ]]; then
    echo "$(date '+%F %T') ERROR: サイズ不一致 $name (元=$size コピー先=${ps:-取得失敗})" >&2
    run_with_timeout "$NAS_OP_TIMEOUT" rm -f "$part" 2>/dev/null
    return 1
  fi

  if run_with_timeout "$NAS_OP_TIMEOUT" mv -f "$part" "$dest"; then
    if ! run_with_timeout "$NAS_OP_TIMEOUT" touch "${dest}.done"; then
      # 本体は届いているので、.done は次の巡回か mark_done.sh が付ける。
      # ローカルは消さずに残し、次回 deliver で「既に存在」判定に入らせる。
      echo "$(date '+%F %T') WARN: .done の作成に失敗 $name。ローカルは保持する。" >&2
      return 1
    fi
    rm -f "$@" "$srcmp3"
    echo "$(date '+%F %T') delivered $name (${size} bytes)"
    return 0
  fi
  echo "$(date '+%F %T') ERROR: リネーム失敗/タイムアウト $name" >&2
  run_with_timeout "$NAS_OP_TIMEOUT" rm -f "$part" 2>/dev/null
  return 1
}

# 録音が終わっているか判定する。$1=パス $2=最新ファイルか(1/0)
# 対象はローカルディスクなのでハングの心配はない。
is_complete() {
  local f="$1" newest="$2" s1 s2
  # 最新ファイルは、しばらく更新が無い（＝録音終了）場合のみ完成扱い。
  # これが無いと録音停止時に最後の1本が永久に取り残される。
  if (( newest == 1 )); then
    [[ -n "$(find "$f" -mmin -${STALE_MIN} 2>/dev/null)" ]] && return 1
  fi
  s1=$(stat -f%z "$f" 2>/dev/null) || return 1
  sleep 2
  s2=$(stat -f%z "$f" 2>/dev/null) || return 1
  [[ "$s1" != "$s2" ]] && return 1
  (( s1 == 0 )) && { rm -f "$f"; return 1; }
  return 0
}

loop_count=0
while true; do
  loop_count=$(( loop_count + 1 ))

  if run_with_timeout "$ENSURE_TIMEOUT" "$SCRIPT_DIR/ensure_nas.sh" >/dev/null 2>&1; then
    run_with_timeout "$NAS_OP_TIMEOUT" mkdir -p "$REC_DIR" || true

    # ---- WAV（旧方式の残り・変換が必要） ----
    wavs=( $(cd "$LOCAL_REC_DIR" && ls -t radio_*.wav 2>/dev/null) )
    for (( i=0; i<${#wavs[@]}; i++ )); do
      w="${wavs[$i]}"
      src="$LOCAL_REC_DIR/$w"
      [[ -f "$src" ]] || continue
      newest=0; (( i == 0 )) && newest=1
      is_complete "$src" "$newest" || continue

      base="${w%.wav}"
      tmpmp3="$LOCAL_REC_DIR/.${base}.mp3.tmp"
      rm -f "$tmpmp3"

      wdur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null)
      wdur=${wdur%.*}
      t0=$(date '+%s')
      # -f mp3 は必須。出力先が .tmp 拡張子のため、指定しないと
      # ffmpeg が出力フォーマットを判定できず失敗する。
      run_with_timeout "$CONV_TIMEOUT" ffmpeg -nostdin -v error -y -i "$src" \
             -ac 1 -ar 16000 -c:a libmp3lame -b:a 128k -f mp3 "$tmpmp3"
      if (( $? != 0 )); then
        echo "$(date '+%F %T') ERROR: mp3変換失敗/タイムアウト $w" >&2
        rm -f "$tmpmp3"
        warn_once "[警告] 録音ファイルのmp3変換に失敗" \
          "録音ファイル $w の16kHzモノラルmp3への変換に失敗しました。"
        continue
      fi
      t1=$(date '+%s')
      echo "$(date '+%F %T') converted $w (WAV ${wdur:-?}秒 → mp3, $((t1-t0))秒)"

      deliver "$tmpmp3" "${base}.mp3" "$src"
    done

    # ---- MP3（現行方式） ----
    mp3s=( $(cd "$LOCAL_REC_DIR" && ls -t radio_*.mp3 2>/dev/null) )
    for (( i=0; i<${#mp3s[@]}; i++ )); do
      m="${mp3s[$i]}"
      src="$LOCAL_REC_DIR/$m"
      [[ -f "$src" ]] || continue
      newest=0; (( i == 0 )) && newest=1
      is_complete "$src" "$newest" || continue
      deliver "$src" "$m"
    done

    # ---- 放棄された一時ファイルの掃除（たまに実行）----
    if (( loop_count % CLEAN_EVERY == 0 )); then
      run_with_timeout "$NAS_OP_TIMEOUT" \
        find "$STAGING" -maxdepth 1 -name '*.part' -mmin +${STALE_PART_MIN} -delete 2>/dev/null || true
    fi

    # ---- 滞留監視 ----
    pending=$(cd "$LOCAL_REC_DIR" && ls -1 radio_*.wav radio_*.mp3 2>/dev/null | wc -l | tr -d ' ')
    if (( pending > PENDING_WARN )); then
      warn_once "[警告] 録音ファイルの移送が滞っています" \
        "内蔵ディスクに未処理の録音が ${pending} 本たまっています。NASへの書き込みと空き容量を確認してください。"
    fi
  else
    echo "$(date '+%F %T') NAS未マウント/確認タイムアウト。移送をスキップ。" >&2
    warn_once "[警告] NAS未マウントで録音の移送が停止" \
      "NASがマウントされていないため、録音ファイルをNASへ移送できません。内蔵ディスクに滞留します。"
  fi

  sleep "$INTERVAL"
done
