# 実装ガイド (implementation_guide.md)

AMラジオ録音・文字起こし・校正・要約・メール通知システムの構築手順です。
このガイドだけで一式を構築できます。概要は [README.md](README.md) を参照してください。

## 目次

1. システム構成と設計方針
2. 事前準備（パッケージ導入）
3. 配置と設定（config.sh）
4. デバイス・NAS接続情報の確認
5. NAS認証情報の保存（Keychain）と手動マウント
6. メール送信設定（msmtp）
7. APIキーの設定（Claude / Gemini）
8. whisperモデルの取得
9. 起動・停止・再起動後の復帰
10. 動作確認手順
11. データ保持とコスト
12. 既知の制約とトラブルシュート

---

## 1. システム構成と設計方針

```
   ※NASは事前に手動マウント。録音・解析はログインセッション内で nohup 常駐。

[recorder.sh]  ──毎時00分区切りのmp3──▶ recordings/（永続保存）
 (nohup常駐)                              │
                          (mark_done.sh が .done マーカー付与)
                                          │
[analyzer_loop.sh]                        ▼
  └5分毎─▶[run_analyzer.sh]─▶[analyzer.sh]
   1) whisper文字起こし(チャンク分割) ─▶ format_transcript.sh ─▶ transcripts/（生・30日）
   2) 第1段 Claude Haiku 校正(行ブロック分割・欠落防止)        ─▶ corrected/（永続）
   3) 第2段 Gemini 要約(Google検索グラウンディング) ─▶ texts/（30日）─▶ メール通知（添付付き）
```

### 設計方針

- **録音は途切れない**: ffmpeg の segment 機能で壁時計の毎時00分に区切る。
- **録音と解析の完全分離**: 解析が重くてもキューに溜めて順次消化。失敗は `.processed` 未付与で次回自動リトライ。
- **長時間音声対策**: 文字起こしは `CHUNK_SECONDS` ごとのチャンク分割、校正は `FIX_CHUNK_LINES` 行ごとのブロック分割で、全編を確実に処理。
- **校正の欠落防止**: 各ブロックの校正後に行数を検証し、入力と一致しなければ生テキストで代用。
- **モデル使い分け**: 校正は機械的整形なので **Haiku**（安価・確実）、要約は固有名詞・時事の確認が活きる **Gemini + 検索グラウンディング**。
- **手動マウント前提**: NASはログインセッションに紐づくため、launchdではなくセッション内 nohup で常駐させる。

---

## 2. 事前準備（パッケージ導入）

```bash
brew install ffmpeg sox msmtp jq curl whisper-cpp
```

> whisper.cpp のコマンド名はバージョンにより `whisper-cli` か `whisper-cpp`。
> `which whisper-cli || which whisper-cpp` で確認し、異なる場合は `scripts/analyzer.sh` 内の
> `whisper-cli` を実際の名前に置換してください。

---

## 3. 配置と設定（config.sh）

```bash
# リポジトリを ~/radio に配置（例）
git clone https://github.com/USER/stenobot.git ~/radio
cd ~/radio
mkdir -p ~/radio/models ~/radio/work

# 設定ファイルを作成
cp scripts/config.sh.example scripts/config.sh
chmod 600 scripts/config.sh
```

`scripts/config.sh` を編集し、以下を自分の環境に合わせます。

| 変数 | 説明 |
|---|---|
| `NAS` | NASのマウント先（既定 `$HOME/radio_nas`） |
| `BASE` | スクリプト・モデル・一時ファイルの内蔵ディレクトリ |
| `NAS_SHARE` | 手動マウント時の共有パス（例 `//USER@NAS_IP/SHARE`） |
| `AUDIO_DEVICE` | 音声入力デバイス番号（手順4で確認） |
| `MAIL_TO` / `MAIL_FROM` | 通知メールの宛先・差出人 |
| `MODEL_WHISPER` | whisperモデルのパス |
| `CLAUDE_*` / `GEMINI_*` | モデル名・キーファイル・トークン上限 |
| `SEG_SECONDS` / `CHUNK_SECONDS` / `FIX_CHUNK_LINES` | 録音長・チャンク長・校正ブロック行数 |

> 各スクリプトは同じ `scripts/` 内の `config.sh` を読み込みます。スクリプト本体の編集は不要です。

---

## 4. デバイス・NAS接続情報の確認

### 4-1. オーディオ入力デバイス番号

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

`[AVFoundation indev]` の **audio devices** の番号を `config.sh` の `AUDIO_DEVICE` に設定します
（例 `:1`）。`:1` は「映像なし・音声デバイス1」の意味。挿し直すと番号が変わることがあります。

### 4-2. NAS接続情報

NAS側で共有フォルダと、読み書き権限を持つユーザーを用意します。プロトコルは SMB を推奨します。

---

## 5. NAS認証情報の保存（Keychain）と手動マウント

### 5-1. SMBクライアント設定（NASがSMB2までの場合）

```bash
sudo tee /etc/nsmb.conf >/dev/null <<'EOF'
[default]
protocol_vers_map=6
signing_required=no
EOF
```

`protocol_vers_map`: `2`=SMB2のみ / `6`=SMB2+SMB3 / `7`=全部。

### 5-2. Keychainに認証情報を保存（対話入力でパスワードを安全に登録）

```bash
# 既存があれば削除（無ければ無視）
security delete-internet-password -s "NAS_IP" -a "USER" -r "smb " 2>/dev/null
security delete-internet-password -l "radio-nas" 2>/dev/null

# 登録（Password: で対話入力）
security add-internet-password \
  -s "NAS_IP" -a "USER" -r "smb " \
  -l "radio-nas" -T /sbin/mount_smbfs -w
```

`-s` の値は `mount_smbfs //USER@<ここ>/SHARE` の `<ここ>` と完全一致させます（IP接続ならIP）。

### 5-3. 手動マウント

```bash
mkdir -p ~/radio_nas
mount_smbfs -N //USER@NAS_IP/SHARE ~/radio_nas
ls ~/radio_nas
touch ~/radio_nas/.write_test && rm ~/radio_nas/.write_test && echo "書き込みOK"
```

> このマウントは実行したログインセッションに属します。録音・解析も同じセッションで nohup 起動します。
> 再起動・スリープ復帰でNASが外れたら再マウントしてください。

---

## 6. メール送信設定（msmtp）

`~/.msmtprc`（**権限 600 必須**）:

```
defaults
auth           on
tls            on
tls_starttls   on
logfile        ~/.msmtp.log

account        gmail
host           smtp.gmail.com
port           587
from           you@example.com
user           you@example.com
password       <アプリパスワード等>

account default : gmail
```

```bash
chmod 600 ~/.msmtprc
echo -e "Subject: test\n\nhello" | msmtp you@example.com
```

> Gmailの場合は2段階認証を有効化し「アプリパスワード」を発行して使用します。
> 表示される16桁は **スペースを詰めて** 貼り付けてください（スペースありは認証失敗の原因）。
> 通常のログインパスワードでは送信できません。

---

## 7. APIキーの設定（Claude / Gemini）

### 7-1. 保存（専用ファイル・chmod 600）

```bash
# Claude（校正用）: https://console.anthropic.com で発行
printf '%s' 'sk-ant-...' > ~/radio/.anthropic_api_key
chmod 600 ~/radio/.anthropic_api_key

# Gemini（要約用）: https://aistudio.google.com/apikey で発行
printf '%s' 'AIza...' > ~/radio/.gemini_api_key
chmod 600 ~/radio/.gemini_api_key
```

### 7-2. 疎通テスト

```bash
# Claude（OKが返れば成功）
KEY=$(cat ~/radio/.anthropic_api_key)
curl -sS https://api.anthropic.com/v1/messages \
  -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":50,"messages":[{"role":"user","content":"OKとだけ返して"}]}' \
  | jq -r '.content[0].text'

# Gemini（OKが返れば成功）
GKEY=$(cat ~/radio/.gemini_api_key)
curl -sS "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent" \
  -H "x-goog-api-key: $GKEY" -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"OKとだけ返して"}]}]}' \
  | jq -r '.candidates[0].content.parts[]?.text'
```

---

## 8. whisperモデルの取得

```bash
mkdir -p ~/radio/models
curl -L -o ~/radio/models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

`large-v3-turbo` は精度と速度のバランス型です。速度優先なら `medium`、精度優先なら `large-v3` に
差し替え可能（`config.sh` の `MODEL_WHISPER` を変更）。

---

## 9. 起動・停止・再起動後の復帰

### 起動（毎回 / 再起動後）

```bash
mount_smbfs -N //USER@NAS_IP/SHARE ~/radio_nas   # NASを手動マウント
~/radio/scripts/start_all.sh                      # 録音・解析ループを起動
```

### 停止

```bash
~/radio/scripts/stop_all.sh
# 必要ならアンマウント: umount ~/radio_nas
```

### 状態確認

```bash
pgrep -fl "segment.*radio_"   # 録音ffmpeg
pgrep -fl analyzer_loop       # 解析ループ
tail -5 ~/radio/recorder.err ~/radio/analyzer.out ~/radio/analyzer.err
```

> ログアウト・再起動で全停止します。復帰は「NAS手動マウント → `start_all.sh`」。

### macOS 補足設定

```bash
sudo pmset -c sleep 0          # スリープ無効（常時録音のため）
sudo pmset -c disksleep 0
sudo systemsetup -gettimezone  # タイムスタンプ用にタイムゾーン確認（Asia/Tokyo等）
```

マイク権限は `start_all.sh` 初回でダイアログが出たら許可します。出ない場合は一度
`~/radio/scripts/recorder.sh` を直接実行してダイアログを通してください。

---

## 10. 動作確認手順

### 10-1. 基本動作

1. NASを手動マウントし、`~/radio/scripts/ensure_nas.sh; echo $?` が `0` を返すことを確認。
2. APIキー疎通（手順7-2）で Claude・Gemini 両方が `OK` を返すことを確認。
3. `~/radio/scripts/start_all.sh` で起動。
4. 録音確認: `pgrep -fl "segment.*radio_"`、`ls -lt ~/radio_nas/recordings/`。
5. 解析確認（最初の1ファイル完成後、`bash ~/radio/scripts/run_analyzer.sh` を手動実行可）:
   - `transcripts/` に生文字起こし（1分毎TS・60行）
   - `corrected/` に校正済み（ヘッダに `# 校正: Claude ...`、行欠落なし）
   - `texts/` に要約（番組名・概要・話題）
   - メール受信（4パス・番組名・時間帯・話題、校正済み文字起こしを添付）

### 10-2. whisper JSON構造の確認（重要・初回）

```bash
which whisper-cli || which whisper-cpp
whisper-cli -m ~/radio/models/ggml-large-v3-turbo.bin -l ja -f /path/to/test.wav -oj -of /tmp/test
jq '.transcription[0]' /tmp/test.json
#   { "offsets": { "from": 0, "to": 5230 }, "text": "..." } を期待
```

キーが異なる場合は `scripts/format_transcript.sh` の `(.offsets.from // 0)` と
`scripts/analyzer.sh` の `.transcription[].text` 抽出を実キーに合わせます。

---

## 11. データ保持とコスト

### 保持方針

| 保存先 | 内容 | 保持 |
|---|---|---|
| `recordings/` | mp3・マーカー | 永続保存 |
| `transcripts/` | 生文字起こし | 30日で自動削除 |
| `corrected/` | 校正済み文字起こし | 永続保存 |
| `texts/` | 解析結果（要約） | 30日で自動削除 |

保持日数は `scripts/run_analyzer.sh` の `find ... -mtime +30` で調整します。mp3は永続保存のため
容量が増え続けます（128kbps mono で約55MB/時≒約40GB/月）。空き容量が `recorder.sh` の閾値
（既定5GB）を下回ると警告メールが届きます。古いmp3は外部ディスク等へ手動退避してください。

### コスト

- 校正（Claude Haiku）: 1時間分の入出力に対して課金。
- 要約（Gemini 3.5 Flash）: トークン課金に加え、検索グラウンディングは検索クエリ数に応じて課金。
  1回のAPI呼び出しで複数クエリが走るとそれぞれ課金対象になります。

番組数・発話量により変動するため、運用開始後しばらくは各サービスのコンソールで実使用量を確認してください。

---

## 12. 既知の制約とトラブルシュート

- **ログアウト・再起動で全停止**: nohup運用のため。復帰は「NAS手動マウント → `start_all.sh`」。
- **launchd 文脈ではNASに書けない**: 手動SMBマウントがログインセッションに属するため。これが
  nohup 運用にしている理由です。
- **録音が20分等で切れる**: mp3自体が短ければ録音側（デバイス番号・NAS書込）を確認。文字起こしだけ
  切れる場合はチャンク分割で解消済み。校正が切れる場合は行ブロック分割＋欠落防止ガードで解消済み。
- **校正で行欠落**: 各ブロックで入力行数と出力行数を検証し、不一致なら生テキストで代用するため
  最終出力の行数は保証されます。ヘッダに「一部ブロックは校正失敗」と出た場合はAPI側の一時障害です。
- **whisperのコマンド名/JSONキー**: バージョン依存。手順10-2で確認。
- **多重起動防止ロックが残った**: `rmdir ~/radio/.analyzer.lock.d`（`stop_all.sh` でも掃除）。
- **再処理したい**: 対象の `recordings/radio_*.mp3.done.processed` を削除すれば次回ループで再実行。
- **要約の検索が過剰課金になる**: クエリ数が多い場合は要約プロンプトで検索条件を絞るか、要約モデルを
  検索なしに切り替えます。

---

以上で、録音から AI による校正・要約・メール通知までの一式が動作します。
日常運用は「NAS手動マウント → `start_all.sh`」、停止は「`stop_all.sh`」です。
