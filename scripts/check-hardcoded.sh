#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OLD_OWNER="${OLD_OWNER:-minjue2017}"

echo "正在检查会影响运行的受版本控制文件中是否残留旧用户名：${OLD_OWNER}"

FILES_TO_CHECK=(
  "compose.yaml"
  "compose.remote.yaml"
  ".env.example"
  ".github/workflows/docker.yml"
  ".github/workflows/docker-personal.yml"
  ".github/workflows/cleanup-ghcr.yml"
  ".github/workflows/cleanup-personal-ghcr.yml"
  ".github/workflows/supply-chain-audit.yml"
  ".github/workflows/supply-chain-audit-personal.yml"
  "scripts/audit-supply-chain.sh"
  "scripts/audit-claude-private-supply-chain.sh"
  "scripts/resolve-public-release-pair.sh"
  "scripts/run.sh"
  "scripts/run-with-ssh-agent.sh"
  "scripts/pull-latest.sh"
  "scripts/reset-home-volume.sh"
  "scripts/migrate-home-volume.sh"
  "scripts/dev-init.sh"
  "scripts/dev-entrypoint.sh"
  "scripts/remote-entrypoint.sh"
  "scripts/remote-hostkey-init.sh"
  "scripts/remote.sh"
  "scripts/smoke-image.sh"
  "scripts/smoke-remote-ssh.sh"
  "scripts/validate-authorized-keys.sh"
  "remote/sshd_config"
  "templates/portainer-stack.yaml"
  "base/Dockerfile"
  "private/Dockerfile"
  "private/visibility-probe.Dockerfile"
)

found=false

for file in "${FILES_TO_CHECK[@]}"; do
  path="${REPO_ROOT}/${file}"
  if [ -f "$path" ] && grep -n "$OLD_OWNER" "$path"; then
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
  path="${REPO_ROOT}/${file}"
  if [ -f "$path" ]; then
    grep -n "ghcr.io/" "$path" | sed "s#^#${file}:#" || true
  fi
done
