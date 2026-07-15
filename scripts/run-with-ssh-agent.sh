#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_ARGS=(--project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml")

if [ -f "$REPO_ROOT/.env" ]; then
  COMPOSE_ARGS+=(--env-file "$REPO_ROOT/.env")
fi

if [ -z "${SSH_AUTH_SOCK:-}" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
  echo "未检测到可用的 SSH Agent socket。请先启动 ssh-agent 并添加密钥：" >&2
  echo "  eval \"\$(ssh-agent -s)\"" >&2
  echo "  ssh-add ~/.ssh/id_ed25519" >&2
  exit 1
fi

# 默认 workspace 由脚本创建；自定义 WORKSPACE 时请先创建目标目录。
mkdir -p "$REPO_ROOT/workspace"

if [ "$(uname -s)" = "Linux" ]; then
  export HOST_UID="${HOST_UID:-$(id -u)}"
  export HOST_GID="${HOST_GID:-$(id -g)}"
fi

echo "正在启动 Codex 开发容器，并转发 SSH Agent..."
exec docker compose "${COMPOSE_ARGS[@]}" run --rm \
  --volume "$SSH_AUTH_SOCK:/ssh-agent" \
  --env SSH_AUTH_SOCK=/ssh-agent \
  codex
