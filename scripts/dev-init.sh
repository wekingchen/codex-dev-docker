#!/usr/bin/env bash

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="${DEV_HOME:-/home/dev}"
CODEX_LIFECYCLE_LOCK_TARGET="${CODEX_LIFECYCLE_LOCK_TARGET:-${DEV_HOME}}"

export HOME="${DEV_HOME}"
export CODEX_HOME="${CODEX_HOME:-${DEV_HOME}/.codex}"
export MISE_DATA_DIR="${MISE_DATA_DIR:-${DEV_HOME}/.local/share/mise}"
export MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-${DEV_HOME}/.config/mise}"

codex_acquire_lifecycle_lock() {
  mkdir -p "$CODEX_LIFECYCLE_LOCK_TARGET"

  # 锁定home volume挂载根目录本身。dev无法从root-owned /home中替换该挂载点，
  # 因此不会出现删除锁文件后在同一路径创建新inode并绕过flock的问题。
  if ! exec {CODEX_LIFECYCLE_LOCK_FD}<"$CODEX_LIFECYCLE_LOCK_TARGET"; then
    echo "无法打开Codex生命周期锁目标：$CODEX_LIFECYCLE_LOCK_TARGET" >&2
    exit 73
  fi

  if ! flock --exclusive --nonblock "$CODEX_LIFECYCLE_LOCK_FD"; then
    echo "另一个Codex容器正在使用共享home：$CODEX_LIFECYCLE_LOCK_TARGET" >&2
    exit 73
  fi
}

codex_remap_dev_identity() {
  local host_uid="${HOST_UID:-}"
  local host_gid="${HOST_GID:-}"
  local current_uid current_group current_gid target_group existing_user

  if [ -z "$host_uid" ] && [ -z "$host_gid" ]; then
    return 0
  fi

  if [ -z "$host_uid" ] || [ -z "$host_gid" ]; then
    echo "HOST_UID 和 HOST_GID 必须同时设置。" >&2
    exit 1
  fi

  if ! [[ "$host_uid" =~ ^[0-9]+$ ]] || ! [[ "$host_gid" =~ ^[0-9]+$ ]]; then
    echo "HOST_UID 和 HOST_GID 必须是正整数。" >&2
    exit 1
  fi

  if [ "${#host_uid}" -gt 10 ] || [ "${#host_gid}" -gt 10 ] \
    || [ "$host_uid" -gt 4294967294 ] || [ "$host_gid" -gt 4294967294 ]; then
    echo "HOST_UID 或 HOST_GID 超出 Linux 支持的数值范围。" >&2
    exit 1
  fi

  if [ "$host_uid" -eq 0 ] || [ "$host_gid" -eq 0 ]; then
    echo "拒绝将开发用户映射为 root UID/GID 0。" >&2
    exit 1
  fi

  current_uid="$(id -u "$DEV_USER")"
  current_group="$(id -gn "$DEV_USER")"
  current_gid="$(id -g "$DEV_USER")"
  target_group="$current_group"

  if [ "$host_gid" != "$current_gid" ]; then
    if getent group "$host_gid" >/dev/null; then
      target_group="$(getent group "$host_gid" | cut -d: -f1)"
    else
      groupmod --gid "$host_gid" "$current_group"
    fi
  fi

  if [ "$host_uid" != "$current_uid" ]; then
    existing_user="$(getent passwd "$host_uid" | cut -d: -f1 || true)"
    if [ -n "$existing_user" ] && [ "$existing_user" != "$DEV_USER" ]; then
      echo "目标 UID $host_uid 已被用户 $existing_user 使用，拒绝接管。" >&2
      exit 1
    fi
    usermod --uid "$host_uid" "$DEV_USER"
  fi

  usermod --gid "$target_group" "$DEV_USER"
}

codex_initialize_dev() {
  local primary_group

  codex_remap_dev_identity

  # 兼容 /home/dev 被挂载成持久化 volume 的情况。
  # 新 volume 或旧 volume 都可能由 root 拥有，因此先修复 home，再切换成开发用户。
  mkdir -p "${DEV_HOME}" \
           "${CODEX_HOME}" \
           "${MISE_DATA_DIR}" \
           "${MISE_CONFIG_DIR}" \
           "${DEV_HOME}/.cache" \
           "${DEV_HOME}/.config/git"

  touch "${DEV_HOME}/.bashrc" "${DEV_HOME}/.profile"

  if ! grep -q "mise activate bash" "${DEV_HOME}/.bashrc"; then
    cat >> "${DEV_HOME}/.bashrc" <<'EOF'

# mise
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi

# direnv
if command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook bash)"
fi
EOF
  fi

  if ! grep -q "mise activate bash" "${DEV_HOME}/.profile"; then
    cat >> "${DEV_HOME}/.profile" <<'EOF'

# mise
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
EOF
  fi

  # 只修正持久化 home。绝不递归修改 bind-mounted /workspace 的宿主机所有权。
  primary_group="$(id -gn "$DEV_USER")"
  chown -R "${DEV_USER}:${primary_group}" "${DEV_HOME}"
}
