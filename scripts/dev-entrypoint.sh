#!/usr/bin/env bash
set -e

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="${DEV_HOME:-/home/dev}"

export HOME="${DEV_HOME}"
export CODEX_HOME="${CODEX_HOME:-${DEV_HOME}/.codex}"
export MISE_DATA_DIR="${MISE_DATA_DIR:-${DEV_HOME}/.local/share/mise}"
export MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-${DEV_HOME}/.config/mise}"

# 兼容 /home/dev 被挂载成持久化 volume 的情况。
# 新 volume 或旧 volume 都可能出现 root 拥有权，导致 dev 用户无法创建 .codex/.local/.config/.cache。
# 因此入口脚本先以 root 修复权限，再切换成 dev 用户运行 shell/Codex。

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

# 修正整个 home volume 的权限。
# 这个目录主要保存 Codex 登录态、mise 运行时、git 配置和语言缓存。
chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"

cd /workspace

exec gosu "${DEV_USER}" "$@"
