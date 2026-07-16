#!/usr/bin/env bash
set -euo pipefail

HOST_KEY_DIR="${HOST_KEY_DIR:-/etc/ssh/codex-host-keys}"
PRIVATE_KEY="${HOST_KEY_DIR}/ssh_host_ed25519_key"
PUBLIC_KEY="${PRIVATE_KEY}.pub"
TEMP_DIR=""
PUBLIC_KEY_TEMP=""

cleanup() {
  if [ -n "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
  if [ -n "$PUBLIC_KEY_TEMP" ]; then
    rm -f "$PUBLIC_KEY_TEMP"
  fi
}
trap cleanup EXIT

install -d -m 0700 -o root -g root "$HOST_KEY_DIR"
exec 9<"$HOST_KEY_DIR"
flock --exclusive 9

if [ -e "$PRIVATE_KEY" ]; then
  if [ ! -f "$PRIVATE_KEY" ] || [ -L "$PRIVATE_KEY" ]; then
    echo "Host private key不是普通文件，拒绝使用：$PRIVATE_KEY" >&2
    exit 1
  fi
else
  TEMP_DIR="$(mktemp -d "${HOST_KEY_DIR}/.hostkey.XXXXXX")"
  ssh-keygen -q -t ed25519 -N '' -C 'codex-dev-remote' -f "$TEMP_DIR/ssh_host_ed25519_key"
  install -m 0600 -o root -g root \
    "$TEMP_DIR/ssh_host_ed25519_key" "${PRIVATE_KEY}.new"
  mv -f "${PRIVATE_KEY}.new" "$PRIVATE_KEY"
fi

chmod 0600 "$PRIVATE_KEY"
chown root:root "$PRIVATE_KEY"

if ! ssh-keygen -l -E sha256 -f "$PRIVATE_KEY" | grep -q '(ED25519)$'; then
  echo "现有host private key不是有效的Ed25519密钥：$PRIVATE_KEY" >&2
  exit 1
fi

if [ -e "$PUBLIC_KEY" ] && { [ ! -f "$PUBLIC_KEY" ] || [ -L "$PUBLIC_KEY" ]; }; then
  echo "Host public key不是普通文件，拒绝覆盖：$PUBLIC_KEY" >&2
  exit 1
fi

PUBLIC_KEY_TEMP="$(mktemp "${HOST_KEY_DIR}/.hostkey-public.XXXXXX")"
ssh-keygen -y -f "$PRIVATE_KEY" > "$PUBLIC_KEY_TEMP"
chmod 0644 "$PUBLIC_KEY_TEMP"
chown root:root "$PUBLIC_KEY_TEMP"
mv -f "$PUBLIC_KEY_TEMP" "$PUBLIC_KEY"
PUBLIC_KEY_TEMP=""

ssh-keygen -l -E sha256 -f "$PUBLIC_KEY"
