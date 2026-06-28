#!/bin/bash
# NASが手動マウント済みかを確認するだけ。マウント/アンマウントは行わない。
# マウント済みかつ書き込み可能なら 0、そうでなければ 1 を返す。
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
