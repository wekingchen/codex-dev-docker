#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_ARGS=(--project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml")

if [ -f "$REPO_ROOT/.env" ]; then
  COMPOSE_ARGS+=(--env-file "$REPO_ROOT/.env")
fi

if [ "$#" -ne 2 ]; then
  echo "用法：$0 <旧 volume 名称> <新 volume 名称>" >&2
  echo "示例：$0 codex-dev-docker_codex-dev-home codex-dev-home" >&2
  exit 1
fi

SOURCE_VOLUME="$1"
TARGET_VOLUME="$2"

if [ "$SOURCE_VOLUME" = "$TARGET_VOLUME" ]; then
  echo "源和目标 volume 相同，无需迁移。" >&2
  exit 1
fi

if ! docker volume inspect "$SOURCE_VOLUME" >/dev/null 2>&1; then
  echo "源 volume 不存在：$SOURCE_VOLUME" >&2
  exit 1
fi

in_use="$({
  docker ps -aq --filter "volume=$SOURCE_VOLUME"
  docker ps -aq --filter "volume=$TARGET_VOLUME"
} | sort -u)"
if [ -n "$in_use" ]; then
  echo "源或目标 volume 仍被容器使用，请先停止这些容器：" >&2
  {
    docker ps -a --filter "volume=$SOURCE_VOLUME" --format '  {{.ID}} {{.Names}} {{.Status}}'
    docker ps -a --filter "volume=$TARGET_VOLUME" --format '  {{.ID}} {{.Names}} {{.Status}}'
  } | sort -u >&2
  exit 1
fi

if ! docker volume inspect "$TARGET_VOLUME" >/dev/null 2>&1; then
  docker volume create "$TARGET_VOLUME" >/dev/null
  echo "已创建目标 volume：$TARGET_VOLUME"
fi

# 默认 workspace 由脚本创建；自定义 WORKSPACE 时请先创建目标目录。
mkdir -p "$REPO_ROOT/workspace"

echo "准备复制 Home volume："
echo "  源：$SOURCE_VOLUME"
echo "  目标：$TARGET_VOLUME"
echo "源 volume 不会被删除。"

docker compose "${COMPOSE_ARGS[@]}" run --rm --no-deps \
  --entrypoint /bin/bash \
  --volume "$SOURCE_VOLUME:/source:ro" \
  --volume "$TARGET_VOLUME:/target" \
  codex -lc '
    set -euo pipefail

    if find /target -mindepth 1 -print -quit | grep -q .; then
      echo "目标 volume 不是空的，拒绝覆盖或合并。" >&2
      exit 1
    fi

    cp -a /source/. /target/

    source_count="$(find /source -xdev | wc -l)"
    target_count="$(find /target -xdev | wc -l)"

    if [ "$source_count" != "$target_count" ]; then
      echo "迁移校验失败：源对象数=$source_count，目标对象数=$target_count" >&2
      exit 1
    fi

    echo "迁移校验通过：共复制 $target_count 个文件系统对象。"
  '

echo "迁移完成。请使用新配置启动并检查 Codex 登录态、mise 和 Git 配置。"
echo "确认稳定前请保留旧 volume：$SOURCE_VOLUME"
