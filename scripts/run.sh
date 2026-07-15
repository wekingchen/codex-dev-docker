#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_ARGS=(--project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml")

if [ -f "$REPO_ROOT/.env" ]; then
  COMPOSE_ARGS+=(--env-file "$REPO_ROOT/.env")
fi

# 默认 workspace 由脚本创建；自定义 WORKSPACE 时请先创建目标目录。
mkdir -p "$REPO_ROOT/workspace"

if [ "$(uname -s)" = "Linux" ]; then
  export HOST_UID="${HOST_UID:-$(id -u)}"
  export HOST_GID="${HOST_GID:-$(id -g)}"
fi

echo "正在启动 Codex 开发容器..."
exec docker compose "${COMPOSE_ARGS[@]}" run --rm codex
