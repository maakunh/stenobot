# stenobot

> ラジオを聴いて書き起こす、AI速記者（steno + bot）。 **（v1.4）**

AMラジオを Mac mini で**連続録音**し、**文字起こし → AI校正 → AI要約 → メール通知**まで自動化するパイプラインです。

録音した音声を [whisper.cpp](https://github.com/ggerganov/whisper.cpp) で文字起こしし、**Claude（Haiku）** で校正、**Gemini 3.5 Flash（Google検索グラウンディング）** で要約して、番組名・概要・話題をまとめたメールを送ります。録音・文字起こしデータは NAS に保管します。

> 個人利用を想定した自動化スクリプト集です。録音物の取り扱いは各自の責任で、著作権法および放送局の利用規約を遵守してください（[注意事項](#注意事項)参照）。

---

## 特徴

- **取りこぼしのない取り込み**: 音声の取り込みは `sox`（CoreAudio）が担当。`ffmpeg` の
  `avfoundation` はサンプルを取りこぼすため使いません（[経緯](#録音が60分に満たない場合)）。
- **途切れない連続録音**: `ffmpeg` のセグメント機能で毎時00分に区切り、1時間ごとに mp3 を生成。
- **録音と解析の分離**: 解析が重くても録音は止まらない。失敗したファイルは次回自動リトライ。
- **NAS障害に強い録音**: 録音は内蔵ディスクに書き、完成したファイルだけを `mover.sh` が
  NAS へ移送。NAS が落ちても録音は止まらず、復旧後に自動で追いつきます。
- **無音の録音を防ぐ起動時チェック**: 起動時に3秒だけ試し録りして音量を確認し、無音なら
  メール警告を出して録音を開始しません。
- **1分毎タイムスタンプ付き文字起こし**: `日-時-分-秒` 付きで1時間=1ファイル。
- **長時間音声でも切れない**: 文字起こしはチャンク分割、校正は行ブロック分割で全編を確実に処理。
- **2段のAIパイプライン**:
  - 第1段（校正）= **Claude Haiku**。誤変換・繰り返し・句読点を整え、行数検証で欠落を防止。
  - 第2段（要約）= **Gemini 3.5 Flash + Google検索グラウンディング**。番組名・出演者・時事を検索で確認して正確に要約。
- **詳細なメール通知**: 番組名・時間帯・話題（見出し/時刻/詳細）を記載し、校正済み文字起こしを添付。
- **設定の一元管理**: 個人設定は `config.sh` に集約。スクリプト本体は編集不要。

## 処理フロー

```
sox(取り込み) ─▶ ffmpeg(毎時分割・16kHzモノラルmp3化) ─▶ 内蔵ディスク
                                                              │
                                                    mover.sh（完成後にNASへ移送）
                                                              ▼
録音(mp3) ─▶ whisper(生文字起こし) ─▶ Claude Haiku 校正 ─▶ Gemini 要約(検索) ─▶ メール通知
                     │                      │                    │
              transcripts/            corrected/              texts/
              （30日保持）            （永続保存）           （30日保持）
recordings/（mp3・永続保存）
```

取り込みと書き込みを分けているのが要点です。`sox` はデバイスから取り込むことだけを行い、
分割・変換・NASへの書き込みはすべて後段が担当します。ネットワークやディスクが詰まっても
取り込みが影響を受けません。

## 必要環境

- macOS（Mac mini を想定。`mount_smbfs` / CoreAudio / `pmset` 等の macOS 機能を使用）
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
#    OS（Mac mini）起動後、まず NAS を手動マウントする（標準手順）。
#    実行するとパスワードの入力を求められるので、入力する。
mkdir -p ~/radio_nas
mount_smbfs //USER@NAS_IP/SHARE ~/radio_nas   # Password: と表示されたら入力
~/radio/scripts/start_all.sh
```

> **起動は画面共有か本体の画面上の Terminal から**
> `start_all.sh` は **SSH 経由での起動を拒否します**。SSHセッションから起動すると macOS が
> マイクへのアクセスを拒否し、エラーを返さないまま**全編無音のファイルを録り続ける**ためです
> （[詳細](#最も多い原因ssh経由での起動)）。録音を伴わない `mover.sh` の単独起動は SSH からでも行えます。

> **入力デバイスの選択について**
> 取り込みを行う `sox` はデバイス名の指定が効かないため、**システムのデフォルト入力デバイス**
> から録音します。**システム設定 → サウンド → 入力**を目的のオーディオIFに設定してください。
> `config.sh` でデバイスを指定することはできません。取り違えは起動時チェックが検知します。

> **NAS の手動マウントについて**
> stenobot は NAS を自動マウントしません。**OS 起動後（および再起動・スリープ復帰でマウントが
> 外れた後）は、都度この `mount_smbfs` を手動実行してパスワードを入力する**のが標準手順です。
> マウント確認は `mount | grep radio_nas` で行えます。
>
> **録音は NAS 未マウントでも継続します。** 録音先は内蔵ディスクで、完成したセグメントを
> `mover.sh` がNASへ移送する構成のためです。マウントを忘れても録音データは失われず、
> 移送と解析が待機するだけで、マウントすれば自動で追いつきます。滞留が続くと
> `mover.sh` が警告メールを送ります。
>
> 自動マウントは断念しました。`mount_smbfs -N` は Keychain ではなく `~/.nsmbrc` から
> パスワードを読みますが（Keychain を使うのは Finder が経由する NetFS 側で別系統）、
> 現行 macOS では `~/.nsmbrc` 用の難読化コマンド `smbutil crypt` が削除されており、
> **平文でパスワードを置く以外の選択肢がありません**。再起動の頻度を考えると
> 割に合わないと判断しました。

## スクリプト構成

| ファイル | 役割 |
|---|---|
| `config.sh.example` | 設定テンプレート（`config.sh` にコピーして使用） |
| `recorder.sh` | 連続録音（sox取り込み → ffmpegでセグメント分割・mp3化） |
| `mover.sh` | 完成した録音を内蔵ディスクからNASへ移送し `.done` を付与 |
| `ensure_nas.sh` | NASマウント確認（確認のみ） |
| `mark_done.sh` | 録音完了マーカー付与（通常は `mover.sh` が先に付ける） |
| `analyzer.sh` | 文字起こし＋校正＋要約＋メール通知 |
| `format_transcript.sh` | 1分毎タイムスタンプ整形 |
| `run_analyzer.sh` | 解析ラッパー＋古いファイルの自動削除 |
| `analyzer_loop.sh` | 5分毎に解析を回すループ |
| `start_all.sh` / `stop_all.sh` | 一括起動 / 一括停止（手動運用時） |
| `install_launchagents.sh` | LaunchAgent として登録し、ログイン時に自動起動させる |

## LaunchAgent での常駐運用（推奨）

`install_launchagents.sh` を実行すると、録音・移送・解析を macOS の LaunchAgent として
登録します。手動起動（`start_all.sh`）より優れている点が3つあります。

**ログイン時に自動起動し、クラッシュしても自動復帰します**（`KeepAlive`）。個別に監視される
ため、「移送だけが死んでいるのに気づかない」という事態を防げます。

**SSH からでも安全に再起動できます。** これが最大の利点です。SSH から `recorder.sh` を直接
起動すると macOS がマイクへのアクセスを拒否し、エラーを返さないまま無音を録り続けます
（[詳細](#最も多い原因ssh経由での起動)）。LaunchAgent は GUI ログインセッションの文脈で動く
ため、`launchctl kickstart` で再起動してもマイク権限が維持されます。

**ログが切り詰められません。** launchd の出力は追記されるため、再起動で過去のログを失いません。

```bash
./install_launchagents.sh              # 登録（再実行で更新）
./install_launchagents.sh --status     # 状態確認
./install_launchagents.sh --uninstall  # 登録解除
```

登録後の操作：

```bash
U=$(id -u)
launchctl kickstart -k gui/$U/com.stenobot.recorder   # 再起動
launchctl print gui/$U/com.stenobot.mover             # 詳細
```

> **スクリプトは `$BASE`（内蔵ディスク）に置かれます**
> ログイン直後はまだNASがマウントされていないため、NAS上のスクリプトはLaunchAgentから
> 起動できません。`install_launchagents.sh` がスクリプト一式を `$BASE` へ配置します。
> NASはデータ専用になります。

### macOS の権限設定（必須）

LaunchAgent が起動する `/bin/bash` に、**フルディスクアクセス**を与える必要があります。
これが無いと、NAS（ネットワークボリューム）への書き込みが `Operation not permitted` で
失敗します。エラーは `mover.err` にしか出ないため気づきにくい失敗です。

システム設定 → プライバシーとセキュリティ → フルディスクアクセス → `+` →
`Cmd+Shift+G` で `/bin/bash` を指定して追加し、トグルをオンにします。追加後は
エージェントの再起動が必要です（TCCの許可はプロセス起動時に読まれるため）。

拒否されているかはログで確認できます。

```bash
log show --last 20m --predicate 'subsystem == "com.apple.TCC"' --info | grep -i NetworkVolumes
```

`Auth Right: Unknown (None)` と出ていれば未許可です。

> `/bin/bash` へのフルディスクアクセスは、このMacで実行される**すべてのbashスクリプト**に
> 同じ権限を与えます。録音専用機であれば実用上の問題は小さいですが、汎用機では留意してください。

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

### 録音が60分に満たない場合

1時間録音したはずの mp3 が48〜50分しかなく、再生すると少し早口に聞こえ、文字起こしの
末尾10分ほどが「（無音）」になる——これは **v1.3 で解決済み**の症状です。

**原因は `ffmpeg` の `avfoundation` 音声取り込みでした。** 常にサンプルの15〜19%を落とし、
しかもタイムスタンプは実時間どおり進むため、下流は受け取ったものを忠実に書くだけになります。

同一デバイス・同一時間帯での実測は次のとおりでした。

| 取り込み方法 | 結果 |
|---|---|
| `ffmpeg -f avfoundation` | 600秒の実時間で **487秒**（81.2%） |
| `rec`（sox / CoreAudio） | 60秒の実時間で **60.000秒**（100%） |
| `rec \| ffmpeg`（v1.3の構成） | 600秒の実時間で **599.976秒**（99.996%） |

そのため v1.3 では**取り込みだけを `sox` に置き換え**、分割・命名・mp3化は従来どおり
`ffmpeg` に任せています。デバイス側は正常なので、機材の交換は不要です。

> **v1.1 / v1.2 の「サンプルレート不一致」という説明は誤りでした。**
> リサンプル（`aresample`）、書き込み先、mp3エンコード、`-thread_queue_size`、
> フォアグラウンド実行——いずれを変えても改善しませんでした。すべて損失より
> **後段**だったためです。
>
> 特に `-af "aresample=async=1:first_pts=0,aresample=16000"` は**絶対に使わないでください**。
> この環境は入力PTSがシステム稼働時間（実測で約46日）から始まるため、`first_pts=0` が
> その分の無音を生成し、**録音が全編デジタル無音（-91dB）になります**。長さだけは60分に
> 揃うので、一見直ったように見えるのが厄介です。

#### 損失の有無を正しく測る

`ffmpeg` の `time=` 表示は**タイムスタンプ基準であってサンプル数ではありません**。
取りこぼしがあっても `time=00:01:00.00` と表示されるため、これを見て「損失なし」と
判断すると誤ります。必ず出力の実サイズか `ffprobe` の `duration` で確認してください。

```bash
# 実時間を外側から測る。real が 60秒前後なら損失なし、72秒なら約17%の損失
time rec -c 2 -r 48000 /tmp/t.wav trim 0 60
ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/t.wav
```

#### 既に録れてしまった早口ファイルの救済

録り直さず、`atempo` で間延びさせて等速化できます。倍率は「実際の再生時間 ÷ 本来の長さ」。

```bash
# 例: 48分(2880秒)を60分(3600秒)へ → 倍率 2880/3600 = 0.8
ffmpeg -i radio_in.mp3 -filter:a "atempo=0.8" -ar 16000 -ac 1 radio_fixed.mp3
```

> `atempo` は 0.5〜2.0 の範囲。範囲外は `atempo=0.8,atempo=0.9` のように連結します。
> ただし取りこぼした音声そのものは戻りません（間延びさせるだけです）。

### 録音が無音になる場合

v1.3 以降は `recorder.sh` の**起動時チェック**が無音を検知し、メール警告を出して録音を
開始しません。それでも無音が疑われるときは、まず入力段を切り分けます。

```bash
# 3秒録って音量を確認（mean_volume が -90dB 前後ならほぼ無音）
rec -c 2 -r 48000 /tmp/raw.wav trim 0 3
ffmpeg -i /tmp/raw.wav -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume"
```

#### 最も多い原因：SSH経由での起動

**SSHセッションから起動すると macOS がマイクへのアクセスを拒否します。** しかもエラーを
返さず、実時間ちょうどのペースで**全ゼロのデータ**を渡してくるため、録音は一見正常に
進み続けます。システムログには次のように記録されます。

```
tccd: Policy disallows prompt for Sub:{/usr/libexec/sshd-keygen-wrapper};
      access to kTCCServiceMicrophone denied
```

`Policy disallows prompt` とあるとおり、許可ダイアログすら表示されないため、待っていても
解決しません。**画面共有か本体の画面上の Terminal から起動してください。**
`start_all.sh` は SSH からの起動を検知して拒否します。

```bash
log show --last 30m --predicate 'subsystem == "com.apple.TCC"' --info | grep -i microphone
```

#### そのほかの原因

`sox` は**システムのデフォルト入力デバイス**から録ります（CoreAudio ドライバはデバイス名
指定が効きません）。**システム設定 → サウンド → 入力**が目的のオーディオIFになっているか
確認してください。USB の抜き挿しやスリープ復帰で変わることがあります。

それでも無音なら入力経路です。よくある順に、オーディオIFの**入力端子（ピンク）に挿さって
いるか**（緑=出力ではないか）、macOS のサウンド入力ゲインが0でないか、ラジオの電源・音量・
ヘッドホン出力、アイソレーターと3.5mmプラグの挿し込みを確認してください。

### NASが落ちて移送が止まった場合

`mover.sh` は NAS に触れる操作をすべてタイムアウト付きで実行するため、NAS の I/O が
ハングしてもループは回り続け、`ensure_nas.sh` が再マウントを試みます。**復旧すれば
人手を介さず自動で追いつきます。**

その間、録音は内蔵ディスクに書かれ続けるのでデータは失われません。滞留が3本を超えると
警告メールが飛びます。状況は次で確認できます。

```bash
ls -la ~/radio/recordings_local          # 滞留しているファイル
tail -20 ~/radio/mover.err               # タイムアウトや再マウントの記録
```

### macOS の権限（TCC）でつまずきやすい3点

本システムは macOS のプライバシー保護（TCC）に3箇所で引っかかります。いずれも
**エラーが分かりにくい形で出る**のが共通点で、切り分けに時間がかかります。

| 対象 | 症状 | 対処 |
|---|---|---|
| マイク | SSH起動時、エラーなく**全編無音**が録れる | LaunchAgent 経由で起動する |
| ネットワークボリューム | NASへの書き込みが `Operation not permitted` | `/bin/bash` にフルディスクアクセス |
| Desktop/Documents 等 | 実在するファイルが「無い」ように見える | 該当アプリにフルディスクアクセス |

いずれも共通のログで確認できます。

```bash
log show --last 30m --predicate 'subsystem == "com.apple.TCC"' --info | grep -iE 'microphone|NetworkVolumes'
```

3つ目は、SMB共有を読むツール側で起きます。**共有が正常でもファイルが見えなくなる**ため、
「ファイルが消えた」と誤診しやすい点に注意してください。判断の前に、書き込みテストで
マウントの健全性を確かめるのが確実です。

```bash
touch ~/radio_nas/.wtest && rm ~/radio_nas/.wtest && echo "マウント正常"
```

## 変更履歴

- **v1.4** — **運用面の堅牢化。** LaunchAgent での常駐運用（`install_launchagents.sh`）を
  追加し、ログイン時の自動起動とクラッシュ時の自動復帰（`KeepAlive`）を実現。加えて
  **SSHからでも安全に再起動できる**ようになった（LaunchAgent はGUIログインセッションの
  文脈で動くため、マイク権限が維持される）。
  `mover.sh` にNAS I/Oハング対策のタイムアウトを追加（NASが固まると `cp`/`mv` が
  ブロックしたままループごと停止し、実際に約4時間、移送と解析が止まった）。
  `ensure_nas.sh` はマウント操作を行わない「確認のみ」に統一（再マウントできない状況で
  正常なマウントを破壊していたため）。ログを追記（`>>`）に変更し、起動のたびに
  過去ログが消える問題を解消。
  NASの自動マウントは断念（`mount_smbfs -N` は Keychain ではなく `~/.nsmbrc` を読むが、
  現行 macOS では難読化コマンド `smbutil crypt` が削除されており、平文保存以外の
  選択肢が無いため）。録音はNAS未マウントでも継続するので実害は小さい。
- **v1.3** — **録音が60分に満たない問題を解決**。原因は `ffmpeg` の `avfoundation` 音声
  取り込みが常にサンプルの15〜19%を落としていたことで、運用開始（v1.0）から一度も
  60分録れていなかった。取り込みを `sox` に置き換え、99.9%を達成。あわせて、
  録音先を内蔵ディスクにして完成後に `mover.sh` がNASへ移送する構成に変更（NAS障害で
  録音が止まらない）、起動時の無音チェックとSSH起動ガードを追加。
  v1.1 の「サンプルレート不一致」という診断は誤りだったため、該当箇所を訂正。
- **v1.2** — 通知メールの各話題に「分野」を追加（話の内容から分野を一言で表記、複数は
  カンマ区切り）。Gemini 要約フォーマットに `話題N分野` を追加。
- **v1.1** — 録音のサンプルレート不一致を修正（出力直前に `aresample=16000` を明示し、
  再生が短く・早口になる問題を解消）。NAS 手動マウント手順を `-N` なし・OS起動後の
  パスワード入力方式に統一。`hardware.md` にサンプルレート確認手順、README に無音時の
  切り分け手順を追記。
  > **この診断は誤りでした。** 真因は `avfoundation` の取り込みそのもので、
  > `aresample` では改善しません。v1.3 を参照してください。
  > なお `aresample=async=1:first_pts=0` は**全編デジタル無音を招くため使用禁止**です。
- **v1.0** — 初版。連続録音＋文字起こし＋AI校正＋AI要約＋メール通知の一連パイプライン。

## 注意事項

- 本ソフトウェアは個人的な記録・研究用途を想定しています。録音物の保存・利用は、著作権法および各放送局の利用規約の範囲内で行ってください。録音物の再配布や公開は権利者の許諾が必要になる場合があります。
- API キー・メール認証情報は `config.sh` および `.anthropic_api_key` / `.gemini_api_key` に保存され、`.gitignore` でコミット対象外にしています。これらを誤って公開しないよう注意してください。
- 動作は macOS 環境に依存します。他OSでは `mount_smbfs`・`avfoundation`・`stat -f`・`date -r` 等の差異により修正が必要です。

## ライセンス

[MIT License](LICENSE.md)

Copyright (c) 2026 Masafumi Hiura
