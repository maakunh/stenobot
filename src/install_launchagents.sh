#!/bin/bash
# ============================================================
# stenobot を LaunchAgent として登録し、ログイン時に自動起動させる。
#
#   ./install_launchagents.sh            登録（既に登録済みなら更新して再起動）
#   ./install_launchagents.sh --uninstall  登録解除
#   ./install_launchagents.sh --status     状態表示のみ
#
# 【なぜスクリプトをローカルに置くのか】
#   ログイン直後はまだNASがマウントされていない。NAS上のスクリプトを
#   LaunchAgentから起動しようとしても読めないため、鶏と卵になる。
#   そこでスクリプト一式は $HOME/radio （内蔵ディスク）に置き、
#   NASはデータ専用とする。このスクリプトが配置をまとめて行う。
#
# 【マイク権限について】
#   LaunchAgent はGUIログインセッションの文脈で動くため、SSHから
#   launchctl で操作してもマイク権限は失われない（SSHから直接
#   recorder.sh を叩くと無音になるのとは対照的）。
#   ただし初回はマイク許可のダイアログが出る場合がある。画面共有か
#   本体の画面で許可すること。無音のまま録れ続ける事故は
#   recorder.sh の起動時チェックが防ぐ。
#
# 【NASの自動マウントについて】
#   ensure_nas.sh が mount_smbfs -N でKeychainの認証情報を使って
#   マウントする。事前に一度だけ、Finderの「サーバへ接続」で
#   「このパスワードをキーチェーンに保存」にチェックを入れて接続し、
#   認証情報をKeychainに保存しておくこと。
# ============================================================
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# config.sh があれば BASE を引き継ぐ（無ければ既定値）
if [[ -f "$SRC_DIR/config.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SRC_DIR/config.sh"
fi
BASE="${BASE:-$HOME/radio}"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABELS=(com.stenobot.recorder com.stenobot.mover com.stenobot.analyzer)
UID_NUM="$(id -u)"

# 配置するスクリプト（SRC_DIR から $BASE へコピー）
SCRIPTS=(recorder.sh mover.sh analyzer_loop.sh analyzer.sh run_analyzer.sh
         mark_done.sh ensure_nas.sh format_transcript.sh start_all.sh stop_all.sh)

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

status() {
  echo "=== LaunchAgent の状態 ==="
  for l in "${LABELS[@]}"; do
    if launchctl print "gui/${UID_NUM}/${l}" >/dev/null 2>&1; then
      local st pid
      st=$(launchctl print "gui/${UID_NUM}/${l}" 2>/dev/null | awk '/^\tstate = /{print $3}')
      pid=$(launchctl print "gui/${UID_NUM}/${l}" 2>/dev/null | awk '/^\tpid = /{print $3}')
      printf "  %-26s 登録済み  state=%-10s pid=%s\n" "$l" "${st:-?}" "${pid:-なし}"
    else
      printf "  %-26s 未登録\n" "$l"
    fi
  done
  echo
  echo "=== プロセス ==="
  pgrep -fl 'rec -q -c 2' | sed 's/^/  録音: /' || echo "  録音: なし"
  pgrep -fl 'mover.sh'    | sed 's/^/  移送: /' || echo "  移送: なし"
  pgrep -fl 'analyzer_loop' | sed 's/^/  解析: /' || echo "  解析: なし"
  echo
  echo "=== NASマウント ==="
  mount | grep "on $HOME/radio_nas " | sed 's/^/  /' || echo "  未マウント"
}

uninstall() {
  echo "=== LaunchAgent を解除します ==="
  for l in "${LABELS[@]}"; do
    if launchctl bootout "gui/${UID_NUM}/${l}" 2>/dev/null; then
      echo "  解除: $l"
    else
      echo "  未登録（スキップ）: $l"
    fi
    rm -f "$AGENT_DIR/${l}.plist"
  done
  echo "完了。手動起動に戻す場合は $BASE/start_all.sh を使ってください。"
}

# plist を生成する。
# $1=ラベル $2=実行するスクリプト名 $3=ProcessType $4=ThrottleInterval $5=ログの基底名
# ログの基底名を明示するのは、analyzer_loop.sh が自身で analyzer.out /
# analyzer.err へ追記するため、launchd の出力先と衝突させないため。
make_plist() {
  local label="$1" script="$2" ptype="$3" throttle="$4" name="$5"
  local out="$AGENT_DIR/${label}.plist"
  cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${BASE}/${script}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- launchd はユーザーのPATHを引き継がない。Homebrew(sox/ffmpeg/msmtp
         /jq/whisper-cli)を見つけられるよう明示する。 -->
    <key>PATH</key>
    <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <!-- 異常終了時の再起動間隔。短すぎると失敗を繰り返して負荷になる。 -->
  <key>ThrottleInterval</key>
  <integer>${throttle}</integer>
  <!-- Interactive は macOS の省電力スロットリング(App Nap/低QoS)を受けない。
       録音の取りこぼしを避けるため recorder は Interactive にする。 -->
  <key>ProcessType</key>
  <string>${ptype}</string>
  <!-- launchd のログ出力は追記される（起動のたびに切り詰められない）。
       手動起動で > を使って過去ログを失う問題が起きないのが利点。 -->
  <key>StandardOutPath</key>
  <string>${BASE}/${name}.out</string>
  <key>StandardErrorPath</key>
  <string>${BASE}/${name}.err</string>
  <key>WorkingDirectory</key>
  <string>${BASE}</string>
</dict>
</plist>
PLIST
  plutil -lint "$out" >/dev/null || { echo "  ERROR: plist が不正です: $out" >&2; return 1; }
  echo "  生成: ${label}.plist"
}

install_all() {
  # --- 1. 前提の確認 ---
  echo "=== 前提の確認 ==="
  local missing=0
  for cmd in rec ffmpeg ffprobe msmtp jq launchctl plutil; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf "  ○ %-12s %s\n" "$cmd" "$(command -v "$cmd")"
    else
      printf "  × %-12s 見つかりません\n" "$cmd"; missing=1
    fi
  done
  if (( missing )); then
    echo "ERROR: 必要なコマンドが不足しています。brew install ffmpeg sox msmtp jq を確認してください。" >&2
    return 1
  fi

  # --- 2. 動いている手動起動プロセスを止める ---
  echo
  echo "=== 手動起動のプロセスを停止 ==="
  pkill -f "analyzer_loop.sh" 2>/dev/null && echo "  解析ループ停止" || echo "  解析ループ: 動作なし"
  pkill -f "rec -q -c 2 -r 48000" 2>/dev/null && { echo "  取り込み(rec)停止"; sleep 3; } || echo "  取り込み: 動作なし"
  pkill -f "segment.*radio_" 2>/dev/null && echo "  録音(ffmpeg)停止" || echo "  録音(ffmpeg): 動作なし"
  pkill -f "mover.sh" 2>/dev/null && echo "  移送ループ停止" || echo "  移送ループ: 動作なし"
  rmdir "$BASE/.analyzer.lock.d" 2>/dev/null || true

  # --- 3. スクリプトをローカルへ配置 ---
  echo
  echo "=== スクリプトを $BASE へ配置 ==="
  mkdir -p "$BASE" "$BASE/recordings_local" "$BASE/.warn" "$AGENT_DIR"
  local f
  for f in "${SCRIPTS[@]}"; do
    if [[ -f "$SRC_DIR/$f" ]]; then
      if [[ "$SRC_DIR/$f" -ef "$BASE/$f" ]]; then
        echo "  同一ファイル（スキップ）: $f"
      else
        cp "$SRC_DIR/$f" "$BASE/$f" && chmod 700 "$BASE/$f" && echo "  配置: $f"
      fi
    elif [[ -f "$BASE/$f" ]]; then
      echo "  既存を使用: $f"
    else
      echo "  ERROR: $f が $SRC_DIR にも $BASE にもありません" >&2; return 1
    fi
  done
  # config.sh は個人設定なので、既にローカルにあれば上書きしない
  if [[ -f "$SRC_DIR/config.sh" && ! -f "$BASE/config.sh" ]]; then
    cp "$SRC_DIR/config.sh" "$BASE/config.sh" && chmod 600 "$BASE/config.sh" && echo "  配置: config.sh"
  fi

  # --- 4. plist を生成 ---
  echo
  echo "=== LaunchAgent の plist を生成 ==="
  # recorder は取りこぼしを避けるため Interactive（スロットリングされない）。
  # 無音やデバイス不在で終了した場合の再試行は5分間隔。
  make_plist com.stenobot.recorder recorder.sh      Interactive 300 recorder         || return 1
  make_plist com.stenobot.mover    mover.sh         Standard     30 mover            || return 1
  # analyzer_loop.sh 自身が analyzer.out/err に書くので、launchd 側は別名にする
  make_plist com.stenobot.analyzer analyzer_loop.sh Standard     60 analyzer_launchd || return 1

  # --- 5. 登録（既存があれば入れ替え）---
  echo
  echo "=== launchctl へ登録 ==="
  local l
  for l in "${LABELS[@]}"; do
    launchctl bootout "gui/${UID_NUM}/${l}" 2>/dev/null && echo "  既存を解除: $l"
    if launchctl bootstrap "gui/${UID_NUM}" "$AGENT_DIR/${l}.plist" 2>/dev/null; then
      echo "  登録: $l"
    else
      echo "  ERROR: 登録に失敗: $l" >&2
      echo "    手動確認: launchctl bootstrap gui/${UID_NUM} $AGENT_DIR/${l}.plist" >&2
      return 1
    fi
  done

  echo
  echo "=== 起動を確認（10秒待機）==="
  sleep 10
  status
  echo
  echo "録音が始まっているかは次で確認できます:"
  echo "  tail -5 $BASE/recorder.err        # 「起動時チェックOK」が出れば正常"
  echo "  ls -la $BASE/recordings_local     # mp3 が育っていれば録音中"
}

case "${1:-}" in
  --uninstall) uninstall ;;
  --status)    status ;;
  -h|--help)   usage ;;
  "")          install_all ;;
  *)           echo "不明なオプション: $1" >&2; usage; exit 1 ;;
esac
