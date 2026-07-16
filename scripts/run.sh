#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_ARGS=(--project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml")
REMOTE_COMPOSE_ARGS=(
  --project-directory "$REPO_ROOT"
  -f "$REPO_ROOT/compose.yaml"
  -f "$REPO_ROOT/compose.remote.yaml"
  --profile remote
)

if [ -f "$REPO_ROOT/.env" ]; then
  COMPOSE_ARGS+=(--env-file "$REPO_ROOT/.env")
  REMOTE_COMPOSE_ARGS+=(--env-file "$REPO_ROOT/.env")
fi

remote_container="$(docker compose "${REMOTE_COMPOSE_ARGS[@]}" ps --status running -q codex-ssh 2>/dev/null || true)"
if [ -n "$remote_container" ]; then
  echo "Codex远程服务正在复用同一个home和workspace，拒绝并发启动本地容器。" >&2
  echo "请先运行：$REPO_ROOT/scripts/remote.sh down" >&2
  exit 1
fi

# 默认 workspace 由脚本创建；自定义 WORKSPACE 时请先创建目标目录。
mkdir -p "$REPO_ROOT/workspace"

if [ "$(uname -s)" = "Linux" ]; then
  export HOST_UID="${HOST_UID:-$(id -u)}"
  export HOST_GID="${HOST_GID:-$(id -g)}"
fi

if [ "$#" -eq 0 ]; then
  echo "正在启动开发容器..."
  exec docker compose "${COMPOSE_ARGS[@]}" run --rm codex
fi

printf '正在开发容器中执行：'
printf ' %q' "$@"
printf '\n'
exec docker compose "${COMPOSE_ARGS[@]}" run --rm codex "$@"
