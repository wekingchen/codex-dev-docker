#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/minjue2017/codex-dev-base:latest}"

docker pull "$IMAGE"
