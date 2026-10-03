#!/bin/bash
set -euo pipefail

# ===== 設定読み込み =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

# 派生パス
REC_DIR="$NAS/recordings"
TXT_DIR="$NAS/texts"                # 解析結果（要約・メール文面）
TRANSCRIPT_DIR="$NAS/transcripts"   # 1分毎TS付き 生文字起こし（whisper素のまま）
CORRECTED_DIR="$NAS/corrected"      # 1分毎TS付き 修正済み文字起こし（Haiku校正後）
WORK="$BASE/work"

# NASマウント確認（手動マウント前提）
"$SCRIPT_DIR/ensure_nas.sh" || { echo "NAS未マウント、skip"; exit 0; }
mkdir -p "$TXT_DIR" "$WORK" "$TRANSCRIPT_DIR" "$CORRECTED_DIR"

# Claude APIキーの読み込み（専用ファイル・chmod 600）
if [[ ! -r "$CLAUDE_KEY_FILE" ]]; then
  echo "$(date '+%F %T') ERROR: APIキーファイルが読めません: $CLAUDE_KEY_FILE" >&2
  exit 1
fi
CLAUDE_API_KEY=$(tr -d ' \t\r\n' < "$CLAUDE_KEY_FILE")
if [[ -z "$CLAUDE_API_KEY" ]]; then
  echo "$(date '+%F %T') ERROR: APIキーが空です: $CLAUDE_KEY_FILE" >&2
  exit 1
fi

# ----- Batch API 設定（config.sh に無ければ既定値）-----
# Batch API は全トークンが半額。結果は非同期で返る（通常数分〜1時間、最大24時間）。
USE_BATCH="${USE_BATCH:-1}"                          # 0 にすると従来どおり即時APIのみ
BATCH_POLL_SECONDS="${BATCH_POLL_SECONDS:-30}"       # 完了確認の間隔
BATCH_TIMEOUT_SECONDS="${BATCH_TIMEOUT_SECONDS:-3600}" # これを過ぎたら取り消して即時APIで処理
# 要約の思考量。Sonnet 5.5 は思考が常時有効で、思考分も出力として課金される。
# 要約は low でも品質がほぼ変わらないため low とする。Haiku 4.5 は effort 非対応なので校正には付けない。
CLAUDE_EFFORT_SUM="${CLAUDE_EFFORT_SUM:-low}"

# リクエスト本文（params）を組み立てる。effort が空なら output_config を付けない。
# 使い方: claude_params <model> <max_tokens> <effort> < プロンプト
claude_params() {
  jq -Rs \
    --arg model "$1" \
    --argjson max_tokens "$2" \
    --arg effort "$3" \
    '{model:$model, max_tokens:$max_tokens, messages:[{role:"user", content:.}]}
     + (if $effort == "" then {} else {output_config:{effort:$effort}} end)'
}

# 応答メッセージから text ブロックを連結して取り出す。Sonnet 5.5 等は思考が常時有効で、
# content[0] が thinking ブロックになるため、先頭だけを読むと毎回失敗扱いになる。
CLAUDE_TEXT_JQ='[.content[]? | select(.type=="text") | .text] | join("")'

# ===== Claude Batch API 呼び出し関数 =====
# 使い方: claude_batch <dir> <model> <max_tokens> <effort>
#   dir 内の各 <id>.prompt を1つのバッチにまとめて送り、成功したものの応答を <id>.out に書く。
#   失敗・期限切れ・取り消しになったものは .out を作らない。取りこぼしの扱い
#   （即時APIでの再試行など）は呼び出し側が .out の有無で判断する。戻り値は常に0。
claude_batch() {
  local dir="$1" model="$2" max_tokens="$3" effort="$4"
  local api="https://api.anthropic.com/v1/messages/batches"
  local f id resp batch_id status results_url waited=0 canceled=0

  for f in "$dir"/*.prompt; do
    id=$(basename "$f" .prompt)
    claude_params "$model" "$max_tokens" "$effort" < "$f" | jq -c --arg id "$id" '{custom_id:$id, params:.}'
  done | jq -s '{requests:.}' > "$dir/request.json"

  resp=$(curl -sS --max-time 120 "$api" \
    -H "x-api-key: ${CLAUDE_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d @"$dir/request.json" 2>/dev/null) || resp=""
  batch_id=$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)
  if [[ -z "$batch_id" ]]; then
    echo "$(date '+%F %T') WARN: バッチ作成失敗(${model}): $(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null || true)" >&2
    return 0
  fi

  # 完了（ended）まで待つ。時間切れなら取り消し、取り消し完了（これも ended）まで待って
  # 処理済みの分だけ受け取る。処理済みの分は課金されているので捨てない。
  while :; do
    sleep "$BATCH_POLL_SECONDS"
    waited=$(( waited + BATCH_POLL_SECONDS ))
    resp=$(curl -sS --max-time 60 "$api/$batch_id" \
      -H "x-api-key: ${CLAUDE_API_KEY}" \
      -H "anthropic-version: 2023-06-01" 2>/dev/null) || resp=""
    status=$(printf '%s' "$resp" | jq -r '.processing_status // empty' 2>/dev/null || true)
    [[ "$status" == "ended" ]] && break
    if (( ! canceled && waited >= BATCH_TIMEOUT_SECONDS )); then
      echo "$(date '+%F %T') WARN: バッチ ${batch_id} が ${BATCH_TIMEOUT_SECONDS}秒で終わらず、取り消します" >&2
      curl -sS --max-time 60 -X POST "$api/$batch_id/cancel" \
        -H "x-api-key: ${CLAUDE_API_KEY}" \
        -H "anthropic-version: 2023-06-01" >/dev/null 2>&1 || true
      canceled=1
    fi
  done

  results_url=$(printf '%s' "$resp" | jq -r '.results_url // empty' 2>/dev/null || true)
  [[ -z "$results_url" ]] && return 0
  curl -sS --max-time 120 "$results_url" \
    -H "x-api-key: ${CLAUDE_API_KEY}" \
    -H "anthropic-version: 2023-06-01" -o "$dir/results.jsonl" 2>/dev/null || return 0

  jq -r 'select(.result.type != "succeeded")
         | "\(.custom_id) \(.result.type) \(.result.error.error.message // "")"' \
    "$dir/results.jsonl" 2>/dev/null \
    | while read -r line; do
        echo "$(date '+%F %T') WARN: バッチ結果(${model}) ${line}" >&2
      done
  for f in "$dir"/*.prompt; do
    id=$(basename "$f" .prompt)
    jq -r --arg id "$id" \
      "select(.custom_id == \$id and .result.type == \"succeeded\") | .result.message | ${CLAUDE_TEXT_JQ}" \
      "$dir/results.jsonl" > "$dir/$id.out" 2>/dev/null || true
    [[ -s "$dir/$id.out" ]] || rm -f "$dir/$id.out"
  done
  return 0
}

# ===== Claude API 呼び出し共通関数（即時API。バッチで取りこぼした分の再試行に使う）=====
# 使い方: claude_call <model> <max_tokens> <prompt文字列> [effort]
#   成功: 標準出力に応答テキスト、戻り値0
#   失敗: 標準出力は空、戻り値1（最大3回リトライ後）
claude_call() {
  local model="$1"; local max_tokens="$2"; local prompt="$3"; local effort="${4:-}"
  local req resp text errmsg attempt
  req=$(printf '%s' "$prompt" | claude_params "$model" "$max_tokens" "$effort")

  for attempt in 1 2 3; do
    resp=$(curl -sS --max-time 180 https://api.anthropic.com/v1/messages \
      -H "x-api-key: ${CLAUDE_API_KEY}" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d "$req" 2>/dev/null) || resp=""

    text=$(printf '%s' "$resp" | jq -r "$CLAUDE_TEXT_JQ" 2>/dev/null)
    if [[ -n "$text" ]]; then
      printf '%s' "$text"
      return 0
    fi
    errmsg=$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)
    echo "$(date '+%F %T') Claude API(${model}) 試行${attempt}失敗: ${errmsg:-応答なし/解析不可}" >&2
    sleep $(( attempt * 5 ))
  done
  return 1
}

# ===== 多重起動防止（mkdirアトミックロック・macOS標準で動作）=====
LOCKDIR="$BASE/.analyzer.lock.d"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$(date '+%F %T') already running, skip."; exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# ===== 完了マーカー付きの未処理ファイルを古い順に処理 =====
shopt -s nullglob
for marker in $(ls -tr "$REC_DIR"/radio_*.mp3.done 2>/dev/null); do
  MP3="${marker%.done}"
  [[ -f "$MP3" ]] || { rm -f "$marker"; continue; }
  [[ -e "${marker}.processed" ]] && continue

  STAMP=$(basename "$MP3" .mp3 | sed 's/^radio_//')   # 例 20260620_1400
  TXT="$TXT_DIR/radio_${STAMP}.txt"
  TRANSCRIPT_TXT="$TRANSCRIPT_DIR/radio_${STAMP}_transcript.txt"
  echo "$(date '+%F %T') analyzing $MP3"

  # ----- ファイル名から録音開始の絶対時刻(UNIX秒)を復元 -----
  Y=${STAMP:0:4}; MO=${STAMP:4:2}; D=${STAMP:6:2}
  HH=${STAMP:9:2}; MI=${STAMP:11:2}
  EPOCH_START=$(date -j -f "%Y%m%d%H%M" "${Y}${MO}${D}${HH}${MI}" "+%s")

  # ----- 文字起こし（長時間音声の途中切れ回避のためチャンク分割処理）-----
  # mp3→16kHz mono wav に変換
  WAV="$WORK/${STAMP}.wav"
  ffmpeg -y -hide_banner -loglevel error -i "$MP3" -ar 16000 -ac 1 "$WAV"

  # 音声長（秒・整数）を取得
  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null)
  DUR=${DUR%.*}; [[ -z "$DUR" || "$DUR" -le 0 ]] && DUR=$SEG_SECONDS

  WJSON="$WORK/${STAMP}.json"
  CHUNK_JSONS=()        # 各チャンクの補正済みJSON断片を貯める

  # CHUNK_SECONDS 毎に分割して個別に文字起こし→オフセット補正
  idx=0
  off=0
  while (( off < DUR )); do
    CHUNK_WAV="$WORK/${STAMP}_c${idx}.wav"
    CHUNK_OUT="$WORK/${STAMP}_c${idx}"     # whisper -of 用（拡張子なし）
    # この区間を切り出し（-ss 開始, -t 長さ）
    ffmpeg -y -hide_banner -loglevel error -ss "$off" -t "$CHUNK_SECONDS" \
      -i "$WAV" -ar 16000 -ac 1 "$CHUNK_WAV"

    # チャンクが空（末尾の端数で無音0秒）なら抜ける
    if [[ ! -s "$CHUNK_WAV" ]]; then
      rm -f "$CHUNK_WAV"
      break
    fi

    # whisperで文字起こし（チャンクは短時間なので途中切れしない）
    whisper-cli -m "$MODEL_WHISPER" -l ja -f "$CHUNK_WAV" \
      -oj -of "$CHUNK_OUT" \
      --max-context 0 \
      --temperature 0.0 \
      --entropy-thold 2.8 \
      --no-speech-thold 0.6 \
      >/dev/null 2>&1

    # チャンク内オフセット(ms)に、このチャンクの開始位置(off*1000)を足して全体通しに補正
    if [[ -f "${CHUNK_OUT}.json" ]]; then
      off_ms=$(( off * 1000 ))
      CORR=$(jq --argjson base "$off_ms" '
        [ .transcription[]
          | { text: .text,
              offsets: { from: ((.offsets.from // 0) + $base),
                         to:   ((.offsets.to   // 0) + $base) } } ]
      ' "${CHUNK_OUT}.json" 2>/dev/null)
      [[ -n "$CORR" ]] && CHUNK_JSONS+=("$CORR")
    fi

    rm -f "$CHUNK_WAV" "${CHUNK_OUT}.json"
    idx=$(( idx + 1 ))
    off=$(( off + CHUNK_SECONDS ))
  done

  # 全チャンクの配列を結合し、format_transcript.sh が読む形 {transcription:[...]} に整形
  if (( ${#CHUNK_JSONS[@]} > 0 )); then
    printf '%s\n' "${CHUNK_JSONS[@]}" \
      | jq -s 'add | { transcription: . }' > "$WJSON" 2>/dev/null
  fi
  # 失敗時は空の構造体を置く（format_transcript側で「解析失敗」表示）
  [[ -s "$WJSON" ]] || echo '{"transcription":[]}' > "$WJSON"

  # ----- 1分毎・絶対時刻付きテキストへ整形してNASへ保存（生文字起こし）-----
  "$SCRIPT_DIR/format_transcript.sh" \
    "$WJSON" "$EPOCH_START" "$(basename "$MP3")" "$TRANSCRIPT_TXT"
  rm -f "$WAV" "$WJSON"

  # ----- 時間帯（録音開始〜終了）を算出 -----
  EPOCH_END=$(( EPOCH_START + SEG_SECONDS ))
  TIME_RANGE="$(date -r "$EPOCH_START" '+%Y-%m-%d %H:%M')〜$(date -r "$EPOCH_END" '+%H:%M')"

  CORRECTED_TXT="$CORRECTED_DIR/radio_${STAMP}_corrected.txt"

  # ===== 第1段：Haikuで文字起こしを校正（行ブロック分割・欠落防止ガード付き）=====
  # ヘッダ（# で始まる）と空行を除いた本文行のみ抽出。各行は「YYYY-MM-DD-HH-MM-SS  本文」。
  RAW_BODY=$(grep -v '^#' "$TRANSCRIPT_TXT" | sed '/^$/d')

  FIX_INSTRUCTION="あなたは日本語AMラジオの自動文字起こしを校正する専門家です。
入力は「タイムスタンプ2個分のスペース本文」という形式の行が並んだものです。
次の規則を厳守して校正後の全行を出力してください。

規則:
- 行数・行の順序・各行先頭のタイムスタンプは絶対に変更しない。入力が N 行なら出力も必ず同じ N 行にする。
- 各行の本文部分のみを校正する。誤変換・同音異義語の誤り・不自然な区切りを文脈から自然な日本語に直す。
- 明らかな繰り返し（同じ語句の機械的反復）は1回に整える。句読点を適切に補う。
- 固有名詞は、読み（音）が同じか極めて近い表記に直す場合に限り修正してよい。
  読みの異なる別の語には置き換えない（例：「東宝大学」→「東邦大学」は可、「東京大学」は不可）。
  確信が持てない固有名詞は原文のまま残す。
- 商品名・番組名・リスナー名など、放送中の固有の呼び名は原文のまま残す（一般的な語に言い換えない）。
- 同一行内で表記を揃える目的で、正しい語を誤った語に合わせない。
- 内容を要約・追加・削除しない（あくまで校正）。本文が「（無音）」の行はそのまま「（無音）」にする。
- 出力は校正後の行のみ。前置き・説明・コードブロックは一切付けない。"

  # 本文を FIX_CHUNK_LINES 行ずつのブロックに分けて個別に校正→連結
  # （1回の出力を短く保ち、出力トークン上限での途中切れ・欠落を回避）
  # 全ブロックのプロンプトを先に作り、1つのバッチでまとめて校正する。
  # ブロックごとにバッチを分けると、完了待ちが直列に積み重なって処理が遅れるため。
  TOTAL_LINES=$(printf '%s\n' "$RAW_BODY" | grep -c .)
  FIX_DIR="$WORK/batch_${STAMP}_fix"
  rm -rf "$FIX_DIR"; mkdir -p "$FIX_DIR"
  start_line=1
  while (( start_line <= TOTAL_LINES )); do
    BLOCK=$(printf '%s\n' "$RAW_BODY" | sed -n "${start_line},$(( start_line + FIX_CHUNK_LINES - 1 ))p")
    BLOCK_LINES=$(printf '%s\n' "$BLOCK" | grep -c .)
    printf '%s' "${FIX_INSTRUCTION}

--- 入力（${BLOCK_LINES}行）---
${BLOCK}" > "$FIX_DIR/$(printf 'b%05d' "$start_line").prompt"
    start_line=$(( start_line + FIX_CHUNK_LINES ))
  done
  (( USE_BATCH )) && claude_batch "$FIX_DIR" "$CLAUDE_MODEL_FIX" "$CLAUDE_MAX_TOKENS_FIX" ""

  CORRECTED_BODY=""
  FIX_FAILED=0
  start_line=1
  while (( start_line <= TOTAL_LINES )); do
    BLOCK=$(printf '%s\n' "$RAW_BODY" | sed -n "${start_line},$(( start_line + FIX_CHUNK_LINES - 1 ))p")
    BLOCK_LINES=$(printf '%s\n' "$BLOCK" | grep -c .)
    BLOCK_ID=$(printf 'b%05d' "$start_line")

    USE_RAW=0
    BLOCK_OK=0
    if [[ -s "$FIX_DIR/$BLOCK_ID.out" ]]; then
      BLOCK_OUT=$(cat "$FIX_DIR/$BLOCK_ID.out"); BLOCK_OK=1
    elif BLOCK_OUT=$(claude_call "$CLAUDE_MODEL_FIX" "$CLAUDE_MAX_TOKENS_FIX" "$(cat "$FIX_DIR/$BLOCK_ID.prompt")"); then
      BLOCK_OK=1
    fi
    if (( BLOCK_OK )); then
      # 欠落防止ガード：校正後の行数が入力と一致しない場合は信頼せず生ブロックを使う
      OUT_LINES=$(printf '%s\n' "$BLOCK_OUT" | grep -c .)
      if (( OUT_LINES != BLOCK_LINES )); then
        echo "$(date '+%F %T') WARN: 校正ブロック(${start_line}-)行数不一致(入力${BLOCK_LINES}/出力${OUT_LINES})、生テキストで代用" >&2
        USE_RAW=1
        FIX_FAILED=1
      fi
    else
      echo "$(date '+%F %T') WARN: 校正ブロック(${start_line}-)API失敗、生テキストで代用" >&2
      USE_RAW=1
      FIX_FAILED=1
    fi
    (( USE_RAW )) && BLOCK_OUT="$BLOCK"

    # 連結（最初のブロック以外は改行を挟む）
    if [[ -z "$CORRECTED_BODY" ]]; then
      CORRECTED_BODY="$BLOCK_OUT"
    else
      CORRECTED_BODY="${CORRECTED_BODY}
${BLOCK_OUT}"
    fi
    start_line=$(( start_line + FIX_CHUNK_LINES ))
  done

  {
    echo "# 修正済み文字起こし: radio_${STAMP}.mp3"
    echo "# 時間帯: ${TIME_RANGE}"
    if (( FIX_FAILED )); then
      echo "# 校正: Claude ${CLAUDE_MODEL_FIX}（一部ブロックは校正失敗のため生テキスト）"
    else
      echo "# 校正: Claude ${CLAUDE_MODEL_FIX}"
    fi
    echo ""
    printf '%s\n' "$CORRECTED_BODY"
  } > "$CORRECTED_TXT"

  # ===== 第2段：修正済みテキストをClaude Sonnetで要約しメール文面を作成 =====
  SUM_PROMPT="あなたはAMラジオ番組の内容を簡潔にまとめる編集者です。番組で語られた内容に基づいて、正確な要約を作成してください。
以下は校正済みの文字起こし（各行先頭に時刻）です。これを読み、厳密に次のフォーマットで日本語出力してください。前置きや感想、脚注は不要です。

番組名: <推定される番組名。判らなければ「不明」>
全体概要: <番組全体を3〜4文で要約>
話題数: <主要な話題の数（整数）>
---
話題1名: <短い見出し>
話題1分野: <その話題がどの分野の話かを一言で表す（例: 経済, 政治, 国際, スポーツ, 科学, 健康, 芸能, 文化, 生活, 天気, 交通）。複数にまたがる場合はカンマ区切りで複数併記（例: 経済, 国際）>
話題1時刻: <その話題が始まる時刻 HH:MM 目安>
話題1詳細: <2〜3文の要約>
---
話題2名: <短い見出し>
話題2分野: <一言。複数はカンマ区切り>
話題2時刻: <HH:MM 目安>
話題2詳細: <2〜3文の要約>
---
（同じ形式で話題3、話題4…と最大6件まで）

--- 校正済み文字起こし ---
${CORRECTED_BODY}"

  SUM_DIR="$WORK/batch_${STAMP}_sum"
  rm -rf "$SUM_DIR"; mkdir -p "$SUM_DIR"
  printf '%s' "$SUM_PROMPT" > "$SUM_DIR/summary.prompt"
  (( USE_BATCH )) && claude_batch "$SUM_DIR" "$CLAUDE_MODEL_SUM" "$CLAUDE_MAX_TOKENS_SUM" "$CLAUDE_EFFORT_SUM"
  if [[ -s "$SUM_DIR/summary.out" ]]; then
    ANALYSIS=$(cat "$SUM_DIR/summary.out")
  elif ! ANALYSIS=$(claude_call "$CLAUDE_MODEL_SUM" "$CLAUDE_MAX_TOKENS_SUM" "$SUM_PROMPT" "$CLAUDE_EFFORT_SUM"); then
    ANALYSIS="番組名: 不明
全体概要: （Claude APIでの要約に失敗しました。修正済み文字起こしは添付パスを参照してください）
話題数: 0"
  fi
  rm -rf "$FIX_DIR" "$SUM_DIR"

  # ----- 番組名を要約結果から抽出（件名・本文の見出し用）-----
  PROGRAM=$(printf '%s\n' "$ANALYSIS" | sed -n 's/^番組名:[[:space:]]*//p' | head -1)
  [ -z "$PROGRAM" ] && PROGRAM="不明"

  # ----- 解析結果txt -----
  {
    echo "番組名     : ${PROGRAM}"
    echo "録音日時   : ${STAMP}"
    echo "時間帯     : ${TIME_RANGE}"
    echo "MP3パス        : $MP3"
    echo "生文字起こし    : $TRANSCRIPT_TXT"
    echo "修正済み文字起こし: $CORRECTED_TXT"
    echo "解析結果パス    : $TXT"
    echo "========================================"
    echo "$ANALYSIS"
  } > "$TXT"

  # ----- メール通知（詳細版・修正済み文字起こしを添付）-----
  SUBJECT="[AMラジオ] ${TIME_RANGE} ${PROGRAM}"
  BODY="AMラジオの録音・修正・要約が完了しました。

■ 基本情報
　番組名   : ${PROGRAM}
　時間帯   : ${TIME_RANGE}
　録音日時 : ${STAMP}

■ ファイル
　MP3音声          : $MP3
　生文字起こし      : $TRANSCRIPT_TXT
　修正済み文字起こし: $CORRECTED_TXT
　解析結果          : $TXT
　（修正済み文字起こしを本メールに添付しています）

■ 内容まとめ（番組名・概要・話題）
${ANALYSIS}
"

  # 件名は日本語を含むためRFC2047 Bエンコード（=?UTF-8?B?...?=）
  SUBJECT_ENC="=?UTF-8?B?$(printf '%s' "$SUBJECT" | base64 | tr -d '\n')?="
  # 添付ファイル名（ASCIIのみなのでそのまま使用可）
  ATTACH_NAME="radio_${STAMP}_corrected.txt"
  # MIME境界文字列（衝突しにくい固定パターン＋STAMP）
  BOUNDARY="==AMRADIO_${STAMP}_$$=="

  {
    echo "To: $MAIL_TO"
    echo "From: $MAIL_FROM"
    echo "Subject: $SUBJECT_ENC"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=\"$BOUNDARY\""
    echo ""
    # --- 本文パート ---
    echo "--$BOUNDARY"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo ""
    echo "$BODY"
    echo ""
    # --- 添付パート（修正済み文字起こし・base64）---
    echo "--$BOUNDARY"
    echo "Content-Type: text/plain; charset=UTF-8; name=\"$ATTACH_NAME\""
    echo "Content-Transfer-Encoding: base64"
    echo "Content-Disposition: attachment; filename=\"$ATTACH_NAME\""
    echo ""
    base64 < "$CORRECTED_TXT"
    echo ""
    echo "--$BOUNDARY--"
  } | msmtp "$MAIL_TO"

  touch "${marker}.processed"
  echo "$(date '+%F %T') done $MP3"
done
