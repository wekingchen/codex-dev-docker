#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/dev-init.sh
source /usr/local/lib/codex-dev/dev-init.sh

AUTHORIZED_KEYS_SOURCE="${AUTHORIZED_KEYS_SOURCE:-/etc/codex-ssh/authorized_keys.input}"
AUTHORIZED_KEYS_RUNTIME="${AUTHORIZED_KEYS_RUNTIME:-/run/codex-ssh/authorized_keys}"
SSHD_CONFIG_TEMPLATE="${SSHD_CONFIG_TEMPLATE:-/etc/ssh/codex_sshd_config}"
SSHD_CONFIG_RUNTIME="${SSHD_CONFIG_RUNTIME:-/run/codex-ssh/sshd_config}"

install_authorized_keys() {
  /usr/local/bin/validate-authorized-keys.sh "$AUTHORIZED_KEYS_SOURCE"
  install -d -m 0755 -o root -g root "$(dirname "$AUTHORIZED_KEYS_RUNTIME")"
  # sshd会以目标用户身份读取该文件；root-owned 0644允许读取但禁止dev修改授权集合。
  install -m 0644 -o root -g root "$AUTHORIZED_KEYS_SOURCE" "$AUTHORIZED_KEYS_RUNTIME"
}

render_sshd_config() {
  if ! [[ "$DEV_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "DEV_USER不是受支持的Linux用户名：$DEV_USER" >&2
    exit 1
  fi

  sed "s/__DEV_USER__/${DEV_USER}/g" "$SSHD_CONFIG_TEMPLATE" > "$SSHD_CONFIG_RUNTIME"
  chmod 0600 "$SSHD_CONFIG_RUNTIME"
  chown root:root "$SSHD_CONFIG_RUNTIME"
}

codex_acquire_lifecycle_lock
codex_initialize_dev

# 账号保持无可用密码但不处于锁定状态；sshd 同时硬禁用所有密码认证方式。
usermod --password x "$DEV_USER"

install_authorized_keys
render_sshd_config
install -d -m 0755 -o root -g root /run/sshd

/usr/sbin/sshd -t -f "$SSHD_CONFIG_RUNTIME"

sshd_pid=""
# shellcheck disable=SC2317,SC2329  # 由下面的signal trap间接调用。
forward_signal() {
  local signal="$1"
  if [ -n "$sshd_pid" ] && kill -0 "$sshd_pid" 2>/dev/null; then
    kill "-$signal" "$sshd_pid"
  fi
}
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT
trap 'forward_signal HUP' HUP

/usr/sbin/sshd -D -e -f "$SSHD_CONFIG_RUNTIME" &
sshd_pid="$!"
set +e
while true; do
  wait "$sshd_pid"
  sshd_status="$?"

  if ! kill -0 "$sshd_pid" 2>/dev/null; then
    break
  fi
done
set -e
trap - TERM INT HUP
exit "$sshd_status"
