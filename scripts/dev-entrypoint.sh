#!/usr/bin/env bash
set -e

# 这个脚本用于兼容 /home/dev 被单独挂载成持久化 volume 的情况。
# 如果 volume 是新建的，Docker 通常会复制镜像里的 /home/dev；
# 如果用户复用了旧 volume，这里会补齐必要目录和 shell 初始化配置。

mkdir -p "${CODEX_HOME:-$HOME/.codex}" \
         "${MISE_DATA_DIR:-$HOME/.local/share/mise}" \
         "${MISE_CONFIG_DIR:-$HOME/.config/mise}" \
         "$HOME/.cache" \
         "$HOME/.config/git"

touch "$HOME/.bashrc" "$HOME/.profile"

if ! grep -q "mise activate bash" "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<'EOF'

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

if ! grep -q "mise activate bash" "$HOME/.profile"; then
  cat >> "$HOME/.profile" <<'EOF'

# mise
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
EOF
fi

exec "$@"
