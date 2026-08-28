#!/bin/bash
# NASが手動マウント済みかを確認するだけ。マウント/アンマウントは行わない。
# マウント済みかつ書き込み可能なら 0、そうでなければ 1 を返す。
#
# 【2026-08-26】マウント操作を絶対に行わない理由
#   一時期「書き込みテスト失敗 → 強制アンマウント → mount_smbfs -N で再マウント」
#   という実装を試したが、-N が失敗する環境では
#   **正常なマウントを壊して未マウントに転落させるだけ**になった。
#   実際に、手動マウント直後に本スクリプトが走ってアンマウントされ、
#   録音・移送が止まる事象が発生した。壊しても直せないなら壊さない。
#
#   mount_smbfs -N が使えない理由:
#     -N は Keychain ではなく ~/.nsmbrc からパスワードを読む（man 参照）。
#     Keychain を使うのは Finder / open smb:// が経由する NetFS 側で別系統。
#     さらに現行macOSでは ~/.nsmbrc 用の難読化コマンド smbutil crypt が
#     削除されており、平文保存以外の選択肢が無い。
#
#   録音は NAS 未マウントでも内蔵ディスクへ継続する（recorder.sh 参照）ため、
#   マウントを手動運用にしても録音データは失われない。移送と解析が待機するだけで、
#   マウントすれば mover.sh が自動で追いつく。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"
MOUNT_POINT="$NAS"

# マウントされているか
if ! mount | grep -q " on ${MOUNT_POINT} "; then
  echo "$(date '+%F %T') NAS未マウント: ${MOUNT_POINT}" >&2
  exit 1
fi

# 書き込み可能か（実際に書けることを確認）
if touch "${MOUNT_POINT}/.write_test" 2>/dev/null; then
  rm -f "${MOUNT_POINT}/.write_test"
  exit 0
else
  echo "$(date '+%F %T') NASはマウント済みだが書き込み不可: ${MOUNT_POINT}" >&2
  exit 1
fi
