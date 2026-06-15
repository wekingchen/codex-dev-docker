#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

IMAGE="${IMAGE:-${CODEX_DEV_IMAGE:-ghcr.io/wekingchen/codex-dev-base:latest}}"
WORKSPACE="${WORKSPACE:-$REPO_ROOT/workspace}"
HOME_VOLUME="${HOME_VOLUME:-codex-dev-home}"

if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  echo "未检测到 SSH_AUTH_SOCK。请先启动 ssh-agent 并添加密钥：" >&2
  echo '  eval "$(ssh-agent -s)"' >&2
  echo '  ssh-add ~/.ssh/id_ed25519' >&2
  exit 1
fi

mkdir -p "$WORKSPACE"

echo "正在启动 Codex 开发容器，并挂载 SSH Agent..."
echo "镜像：$IMAGE"
echo "工作目录：$WORKSPACE"
echo "Home volume：$HOME_VOLUME"

docker run --rm -it \
  -v "$WORKSPACE:/workspace" \
  -v "$HOME_VOLUME:/home/dev" \
  -v "$SSH_AUTH_SOCK:/ssh-agent" \
  -e SSH_AUTH_SOCK=/ssh-agent \
  -e CODEX_HOME=/home/dev/.codex \
  -e MISE_DATA_DIR=/home/dev/.local/share/mise \
  -e MISE_CONFIG_DIR=/home/dev/.config/mise \
  -w /workspace \
  "$IMAGE" \
  bash
