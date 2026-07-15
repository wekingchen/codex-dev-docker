#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_ARGS=(--project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml")

if [ -f "$REPO_ROOT/.env" ]; then
  COMPOSE_ARGS+=(--env-file "$REPO_ROOT/.env")
fi

if [ "$#" -ne 1 ]; then
  echo "用法：$0 <要删除的实际 Docker volume 名称>" >&2
  echo "默认配置示例：$0 codex-dev-home" >&2
  echo "请先用 docker volume ls 确认准确名称。" >&2
  exit 1
fi

HOME_VOLUME="$1"

if ! docker volume inspect "$HOME_VOLUME" >/dev/null 2>&1; then
  echo "volume 不存在：$HOME_VOLUME" >&2
  exit 1
fi

echo "即将删除 Home volume：$HOME_VOLUME"
echo "这会清除 Codex 登录态、mise 安装的运行时、git 配置和各种缓存。"
read -r -p "确认删除请输入 DELETE $HOME_VOLUME： " answer

if [ "$answer" != "DELETE $HOME_VOLUME" ]; then
  echo "已取消。"
  exit 0
fi

# 先停止本 Compose 项目的容器，但不让 Compose 代为删除 volume。
docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans

users="$(docker ps -aq --filter "volume=$HOME_VOLUME")"
if [ -n "$users" ]; then
  echo "仍有其他容器正在使用 volume $HOME_VOLUME，拒绝删除：" >&2
  docker ps -a --filter "volume=$HOME_VOLUME" \
    --format '  {{.ID}} {{.Names}} {{.Status}}' >&2
  exit 1
fi

docker volume rm "$HOME_VOLUME" >/dev/null

if docker volume inspect "$HOME_VOLUME" >/dev/null 2>&1; then
  echo "删除后复核失败，volume 仍然存在：$HOME_VOLUME" >&2
  exit 1
fi

echo "已删除 Home volume：$HOME_VOLUME"
