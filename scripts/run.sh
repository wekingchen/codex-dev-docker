#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/minjue2017/codex-dev-base:latest}"
WORKSPACE="${WORKSPACE:-$PWD/workspace}"

mkdir -p "$WORKSPACE"

docker run --rm -it \
  -v "$WORKSPACE:/workspace" \
  -v codex-home:/home/dev/.codex \
  -v mise-data:/home/dev/.local/share/mise \
  -v mise-config:/home/dev/.config/mise \
  -v dev-cache:/home/dev/.cache \
  -v git-config:/home/dev/.config/git \
  -v npm-cache:/home/dev/.npm \
  -v pnpm-store:/home/dev/.local/share/pnpm \
  -v pip-cache:/home/dev/.cache/pip \
  -v go-cache:/home/dev/go \
  -v cargo-cache:/home/dev/.cargo \
  -v rustup-cache:/home/dev/.rustup \
  -e CODEX_HOME=/home/dev/.codex \
  -e MISE_DATA_DIR=/home/dev/.local/share/mise \
  -e MISE_CONFIG_DIR=/home/dev/.config/mise \
  -w /workspace \
  "$IMAGE" \
  bash
