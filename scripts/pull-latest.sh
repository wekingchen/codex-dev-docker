#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_ARGS=(--project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml")

if [ -f "$REPO_ROOT/.env" ]; then
  COMPOSE_ARGS+=(--env-file "$REPO_ROOT/.env")
fi

echo "正在拉取 Compose 配置中的 Codex 镜像..."
docker compose "${COMPOSE_ARGS[@]}" pull codex
echo "镜像拉取完成。"
