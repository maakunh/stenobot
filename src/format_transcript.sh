#!/bin/bash
# 使い方: format_transcript.sh <whisper_json> <epoch_start> <mp3_basename> <out_txt>
#   1分毎に「録音開始＋m分」の絶対時刻(YYYY-MM-DD-HH-MM-SS)と本文を1行出力。1時間=60行。
set -euo pipefail

JSON="$1"; EPOCH_START="$2"; MP3_BASE="$3"; OUT="$4"
SEG_MINUTES=60   # 1ファイルあたりの分数（録音セグメント長/60）

# ヘッダ
START_HUMAN=$(date -r "$EPOCH_START" '+%Y-%m-%d %H:%M:%S')
{
  echo "# 文字起こし: ${MP3_BASE}"
  echo "# 録音開始: ${START_HUMAN}"
  echo ""
} > "$OUT"

# whisper JSON から「オフセット秒, 本文」を取り出す（offsets.from はミリ秒）
jq -r '
  .transcription[]
  | ( (.offsets.from // 0) / 1000 | floor ) as $sec
  | "\($sec)\t\(.text)"
' "$JSON" > "${OUT}.seg.tmp" 2>/dev/null || {
  echo "（文字起こしデータの解析に失敗しました）" >> "$OUT"
  rm -f "${OUT}.seg.tmp"; exit 0
}

# 各分ごとに本文を連結して絶対時刻付きで出力
for (( m=0; m<SEG_MINUTES; m++ )); do
  lo=$(( m * 60 )); hi=$(( lo + 60 ))
  line=$(awk -F'\t' -v lo="$lo" -v hi="$hi" '
    { s=$1+0 }
    (s>=lo && s<hi) {
      txt=$2
      gsub(/^[ \t　]+/,"",txt); gsub(/[ \t　]+$/,"",txt)
      if (txt!="" && txt!=prev) {        # 直前と同じ文ならスキップ（連続重複除去）
        out = (out=="" ? txt : out " " txt)
        prev = txt
      }
    }
    END { print out }
  ' "${OUT}.seg.tmp")

  ts_epoch=$(( EPOCH_START + m * 60 ))
  ts=$(date -r "$ts_epoch" '+%Y-%m-%d-%H-%M-%S')
  [[ -z "$line" ]] && line="（無音）"
  printf '%s  %s\n' "$ts" "$line" >> "$OUT"
done

rm -f "${OUT}.seg.tmp"
