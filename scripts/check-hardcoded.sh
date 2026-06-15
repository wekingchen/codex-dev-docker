#!/usr/bin/env bash
set -euo pipefail

OLD_OWNER="${OLD_OWNER:-minjue2017}"

echo "正在检查会影响运行的配置文件中是否残留旧用户名：${OLD_OWNER}"

FILES_TO_CHECK=(
  "compose.yaml"
  ".env"
  ".env.example"
  ".github/workflows/docker.yml"
  ".github/workflows/cleanup-ghcr.yml"
  "scripts/run.sh"
  "scripts/run-with-ssh-agent.sh"
  "scripts/pull-latest.sh"
  "scripts/reset-home-volume.sh"
  "scripts/dev-entrypoint.sh"
  "base/Dockerfile"
)

found=false

for file in "${FILES_TO_CHECK[@]}"; do
  if [ -f "$file" ] && grep -n "$OLD_OWNER" "$file"; then
    echo "发现残留：$file" >&2
    found=true
  fi
done

if [ "$found" = true ]; then
  echo "检查失败：请修正旧用户名后再提交。" >&2
  exit 1
fi

echo "检查通过：运行相关配置中未发现旧用户名残留。"

echo
echo "当前运行相关文件中的 ghcr.io 引用："
for file in "${FILES_TO_CHECK[@]}"; do
  if [ -f "$file" ]; then
    grep -n "ghcr.io/" "$file" | sed "s#^#${file}:#" || true
  fi
done
