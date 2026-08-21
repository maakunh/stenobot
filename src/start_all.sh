#!/bin/bash
# 録音システム一式を起動する。前提: NASを手動マウント済みであること。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

# 0) SSH経由の起動を拒否する
#    SSHセッションから起動すると macOS がマイクへのアクセスを拒否し
#    （"Policy disallows prompt"）、エラーを出さずに全ゼロの無音が録音される。
#    無音のまま何時間も走り続けるのが最も厄介なので、ここで止める。
if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; then
  echo "エラー: SSH経由では起動できません。" >&2
  echo "  SSHから起動するとマイク権限が拒否され、無音のファイルが録音され続けます。" >&2
  echo "  画面共有でログインし、その画面上のTerminalから実行してください。" >&2
  exit 1
fi

# 1) NASマウント確認（未マウントなら案内して終了）
if ! "$SCRIPT_DIR/ensure_nas.sh"; then
  echo "NASが未マウント、または書き込み不可です。先に手動マウントしてください："
  echo "  mount_smbfs ${NAS_SHARE} ${NAS}"
  exit 1
fi

# 2) 二重起動防止：既存プロセスがあれば起動しない
if pgrep -f "segment.*radio_" >/dev/null; then
  echo "録音プロセスは既に起動しています。"
else
  echo "録音を起動します..."
  nohup "$SCRIPT_DIR/recorder.sh" < /dev/null > "$BASE/recorder.out" 2> "$BASE/recorder.err" &
  disown
fi

# 3) 移送ループ（内蔵ディスク→NAS）
if pgrep -f "mover.sh" >/dev/null; then
  echo "移送ループは既に起動しています。"
else
  echo "移送ループを起動します..."
  nohup "$SCRIPT_DIR/mover.sh" < /dev/null > "$BASE/mover.out" 2> "$BASE/mover.err" &
  disown
fi

if pgrep -f "analyzer_loop.sh" >/dev/null; then
  echo "解析ループは既に起動しています。"
else
  echo "解析ループを起動します..."
  nohup "$SCRIPT_DIR/analyzer_loop.sh" < /dev/null > /dev/null 2>&1 &
  disown
fi

echo "起動完了。状態確認："
echo "  pgrep -fl 'segment.*radio_'   # 録音"
echo "  pgrep -fl mover.sh            # 移送"
echo "  pgrep -fl analyzer_loop       # 解析ループ"
echo "  tail -f \$BASE/mover.err       # 移送ログ"
