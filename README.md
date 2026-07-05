# stenobot

> ラジオを聴いて書き起こす、AI速記者（steno + bot）。 **（v1.1）**

AMラジオを Mac mini で**連続録音**し、**文字起こし → AI校正 → AI要約 → メール通知**まで自動化するパイプラインです。

録音した音声を [whisper.cpp](https://github.com/ggerganov/whisper.cpp) で文字起こしし、**Claude（Haiku）** で校正、**Gemini 3.5 Flash（Google検索グラウンディング）** で要約して、番組名・概要・話題をまとめたメールを送ります。録音・文字起こしデータは NAS に保管します。

> 個人利用を想定した自動化スクリプト集です。録音物の取り扱いは各自の責任で、著作権法および放送局の利用規約を遵守してください（[注意事項](#注意事項)参照）。

---

## 特徴

- **途切れない連続録音**: `ffmpeg` のセグメント機能で毎時00分に区切り、1時間ごとに mp3 を生成。
- **録音と解析の分離**: 解析が重くても録音は止まらない。失敗したファイルは次回自動リトライ。
- **1分毎タイムスタンプ付き文字起こし**: `日-時-分-秒` 付きで1時間=1ファイル。
- **長時間音声でも切れない**: 文字起こしはチャンク分割、校正は行ブロック分割で全編を確実に処理。
- **2段のAIパイプライン**:
  - 第1段（校正）= **Claude Haiku**。誤変換・繰り返し・句読点を整え、行数検証で欠落を防止。
  - 第2段（要約）= **Gemini 3.5 Flash + Google検索グラウンディング**。番組名・出演者・時事を検索で確認して正確に要約。
- **詳細なメール通知**: 番組名・時間帯・話題（見出し/時刻/詳細）を記載し、校正済み文字起こしを添付。
- **設定の一元管理**: 個人設定は `config.sh` に集約。スクリプト本体は編集不要。

## 処理フロー

```
録音(mp3) ─▶ whisper(生文字起こし) ─▶ Claude Haiku 校正 ─▶ Gemini 要約(検索) ─▶ メール通知
                     │                      │                    │
              transcripts/            corrected/              texts/
              （30日保持）            （永続保存）           （30日保持）
recordings/（mp3・永続保存）
```

## 必要環境

- macOS（Mac mini を想定。`mount_smbfs` / `avfoundation` / `pmset` 等の macOS 機能を使用）
- AMラジオの音声入力経路（USBオーディオIF等）。具体的な機材・接続・ノイズ対策は [hardware.md](hardware.md) を参照。
- SMB 共有可能な NAS（手動マウント前提）
- [Homebrew](https://brew.sh/)
- Anthropic API キー（校正用）
- Google Gemini API キー（要約用）

### 依存パッケージ

```bash
brew install ffmpeg sox msmtp jq curl whisper-cpp
```

## クイックスタート

```bash
# 1. 取得して配置
git clone https://github.com/USER/stenobot.git ~/radio
cd ~/radio

# 2. 設定ファイルを作成して自分の環境に合わせて編集
cp scripts/config.sh.example scripts/config.sh
chmod 600 scripts/config.sh
$EDITOR scripts/config.sh        # メール・NAS・デバイス番号などを設定

# 3. APIキーを専用ファイルに保存（chmod 600）
printf '%s' 'sk-ant-...'  > ~/radio/.anthropic_api_key && chmod 600 ~/radio/.anthropic_api_key
printf '%s' 'AIza...'     > ~/radio/.gemini_api_key    && chmod 600 ~/radio/.gemini_api_key

# 4. whisper モデルを取得
mkdir -p ~/radio/models
curl -L -o ~/radio/models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# 5. NAS を手動マウントして起動
mount_smbfs -N //USER@NAS_IP/SHARE ~/radio_nas
~/radio/scripts/start_all.sh
```

詳細な手順は [implementation_guide.md](implementation_guide.md) を参照してください。

## スクリプト構成

| ファイル | 役割 |
|---|---|
| `config.sh.example` | 設定テンプレート（`config.sh` にコピーして使用） |
| `recorder.sh` | 連続録音（セグメント分割） |
| `ensure_nas.sh` | NASマウント確認（確認のみ） |
| `mark_done.sh` | 録音完了マーカー付与 |
| `analyzer.sh` | 文字起こし＋校正＋要約＋メール通知 |
| `format_transcript.sh` | 1分毎タイムスタンプ整形 |
| `run_analyzer.sh` | 解析ラッパー＋古いファイルの自動削除 |
| `analyzer_loop.sh` | 5分毎に解析を回すループ |
| `start_all.sh` / `stop_all.sh` | 一括起動 / 一括停止 |

## データ保持方針

| 保存先 | 内容 | 保持 |
|---|---|---|
| `recordings/` | mp3・マーカー | 永続保存 |
| `transcripts/` | 生文字起こし | 30日で自動削除 |
| `corrected/` | 校正済み文字起こし | 永続保存 |
| `texts/` | 解析結果（要約） | 30日で自動削除 |

保持日数は `run_analyzer.sh` で調整できます。

## コストの目安

AIのAPIは従量課金です。校正（Haiku）は1時間分の入出力、要約（Gemini）は検索グラウンディングの検索回数に応じて課金されます。番組数や発話量により変動するため、運用開始後しばらくは各サービスのコンソールで実使用量を確認することを推奨します。

## トラブルシュート

### 要約に失敗したメールが届いた場合（手動リトライ）

メール本文に「Gemini APIでの要約に失敗しました。修正済み文字起こしは添付パスを参照してください」と
表示された場合、録音・文字起こし・校正は成功しており、**要約（メール本文のまとめ）だけが失敗**した
状態です。多くはAPIの一時的な混雑やレート制限が原因なので、その回だけ再処理すれば解消します。

再処理は、対象ファイルの処理済みマーカー（`.processed`）を削除して、解析をもう一度実行するだけです。
録音データはそのまま使われるので、録り直しは不要です。

```bash
# 1. 対象の録音日時を特定（メールの「録音日時」欄。例: 20260628_2200）
STAMP=20260628_2200

# 2. 処理済みマーカーを削除（これで再処理の対象に戻る）
rm ~/radio_nas/recordings/radio_${STAMP}.mp3.done.processed

# 3. すぐに再処理を実行（次の自動ループを待たずに手動実行）
bash ~/radio/scripts/run_analyzer.sh
```

数分後、要約を含むメールが再送されます。`transcripts/`・`corrected/`・`texts/` の各ファイルも
上書き更新されます。

> 再処理では文字起こしからやり直されるため、校正・要約もすべて再生成されます。
> 連続して失敗する場合は、APIキーの残高・レート制限や、`~/radio/analyzer.err` のログを確認してください。
> 特にログに「上限(MAX_TOKENS)で途切れました」と出る場合は、`config.sh` の
> `GEMINI_MAX_TOKENS_SUM` を引き上げてください。

### 特定の回だけをまとめて再処理したい場合

```bash
# 複数ファイルの .processed をまとめて削除してから再実行
rm ~/radio_nas/recordings/radio_20260628_2100.mp3.done.processed
rm ~/radio_nas/recordings/radio_20260628_2200.mp3.done.processed
bash ~/radio/scripts/run_analyzer.sh
```

### 録音が短く・早口になる場合（サンプルレート不一致）

録音ファイルの中身は0分0秒〜59分59秒あるのに、再生の長さが48分ほどに縮み、少し早口
（ピッチが高い）に聞こえる場合は、**入力サンプルレートの不一致**が原因です。

`avfoundation` はオーディオIF（SB-PLAY3 等）の**固有レート**（多くは 44100/48000 Hz）で
音声を渡します。旧版（v1.0）は入力レートを宣言せず出力側 `-ar 16000` だけを指定していたため、
デバイスが 48000 で渡しているのに 16000 と誤認され、リサンプルが正しく効かず等速コピー扱いに
なって、60分が48分ほどに縮む・ピッチが上がる、という症状が出ることがありました。

**v1.1 で修正済み**です。`config.sh` に入力実レートを設定してください。

```bash
# 1. デバイスの実サンプルレートを確認（ログの "... Hz" を見る）
ffmpeg -f avfoundation -i "$AUDIO_DEVICE" -t 5 /tmp/test.wav
#   例: "Stream #0:0: Audio: pcm_..., 48000 Hz, mono" → 48000

# 2. config.sh に実レートを設定（44100 なら 44100 に）
#    INPUT_RATE=48000

# 3. 録音を再起動
~/radio/scripts/stop_all.sh
~/radio/scripts/start_all.sh
```

recorder.sh は `-f avfoundation -ar "$INPUT_RATE" -i "$AUDIO_DEVICE"` のように、
**入力レートを `-i` の前で宣言**するようになりました。これで入力→16kHzへのリサンプルが
正しく行われ、60分の内容が等速・正しいピッチの60分で保存されます。

#### 既に録れてしまった早口ファイルの救済

録り直さずに、`atempo` で間延びさせて等速化できます（実レート48000・誤認16000＝比率 1/3 でなく、
症状から実効比 0.8 の場合の例）。倍率は「正しい長さ ÷ 現在の長さ」で求めます。

```bash
# 例: 48分(2880秒)を60分(3600秒)へ → 倍率 2880/3600 = 0.8
ffmpeg -i radio_in.mp3 -filter:a "atempo=0.8" -ar 16000 -ac 1 radio_fixed.mp3
```

> `atempo` は 0.5〜2.0 の範囲。範囲外は `atempo=0.8,atempo=0.9` のように連結します。
> 正確な倍率は「録音の実尺（60分など） ÷ 実際の再生時間」で算出してください。

## 変更履歴

- **v1.1** — 録音のサンプルレート不一致を修正。`avfoundation` の入力レートを
  `config.sh` の `INPUT_RATE` で宣言するようにし、再生が短く・早口になる問題を解消。
  `hardware.md` にサンプルレート確認手順を追記。
- **v1.0** — 初版。連続録音＋文字起こし＋AI校正＋AI要約＋メール通知の一連パイプライン。

## 注意事項

- 本ソフトウェアは個人的な記録・研究用途を想定しています。録音物の保存・利用は、著作権法および各放送局の利用規約の範囲内で行ってください。録音物の再配布や公開は権利者の許諾が必要になる場合があります。
- API キー・メール認証情報は `config.sh` および `.anthropic_api_key` / `.gemini_api_key` に保存され、`.gitignore` でコミット対象外にしています。これらを誤って公開しないよう注意してください。
- 動作は macOS 環境に依存します。他OSでは `mount_smbfs`・`avfoundation`・`stat -f`・`date -r` 等の差異により修正が必要です。

## ライセンス

[MIT License](LICENSE.md)

Copyright (c) 2026 Masafumi Hiura
