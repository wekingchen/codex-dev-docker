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

echo "正在拉取最新镜像：$IMAGE"
docker pull "$IMAGE"
echo "镜像拉取完成。"
