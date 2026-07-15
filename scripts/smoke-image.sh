#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "用法：$0 <镜像引用> [期望 Codex 版本|latest] [平台]" >&2
  exit 1
fi

IMAGE="$1"
EXPECTED_VERSION="${2:-latest}"
PLATFORM="${3:-linux/amd64}"
HOME_VOLUME="codex-smoke-home-$$-${RANDOM:-0}"

cleanup() {
  docker volume rm -f "$HOME_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker volume create "$HOME_VOLUME" >/dev/null

# 先制造一个 root 拥有的旧 home，验证正常 entrypoint 能修复它。
docker run --rm --platform "$PLATFORM" \
  --entrypoint /bin/bash \
  --volume "$HOME_VOLUME:/home/dev" \
  "$IMAGE" -lc 'mkdir -p /home/dev/.codex && touch /home/dev/root-owned && chown -R 0:0 /home/dev'

output="$(docker run --rm --platform "$PLATFORM" \
  --volume "$HOME_VOLUME:/home/dev" \
  "$IMAGE" bash -lc '
    set -euo pipefail
    test "$(id -u)" -ne 0
    test -w "$HOME"
    test -w "$CODEX_HOME"
    touch "$CODEX_HOME/smoke-write"
    touch /workspace/.smoke-write
    rm -f /workspace/.smoke-write
    command -v codex >/dev/null
    command -v mise >/dev/null
    codex_output="$(codex --version)"
    printf "CODEX_OUTPUT=%s\n" "$codex_output"
    printf "CODEX_VERSION=%s\n" "${codex_output##* }"
    printf "MISE_OUTPUT=%s\n" "$(mise --version)"
    printf "USER_ID=%s:%s\n" "$(id -u)" "$(id -g)"
    printf "ARCH=%s\n" "$(uname -m)"
  ')"

printf '%s\n' "$output"

actual_version=""
actual_arch=""
while IFS= read -r line; do
  case "$line" in
    CODEX_VERSION=*) actual_version="${line#*=}" ;;
    ARCH=*) actual_arch="${line#*=}" ;;
  esac
done <<< "$output"

if [ -z "$actual_version" ]; then
  echo "无法从 smoke 输出解析 Codex 版本。" >&2
  exit 1
fi

if [ "$EXPECTED_VERSION" != "latest" ] && [ "$actual_version" != "$EXPECTED_VERSION" ]; then
  echo "Codex 版本不匹配：期望 $EXPECTED_VERSION，实际 $actual_version" >&2
  exit 1
fi

case "$PLATFORM:$actual_arch" in
  linux/amd64:x86_64|linux/arm64:aarch64|linux/arm64:arm64) ;;
  *)
    echo "镜像架构不匹配：平台 $PLATFORM，容器报告 $actual_arch" >&2
    exit 1
    ;;
esac

# 验证原生 Linux 包装脚本会用到的运行时 UID/GID 重映射路径。
remap_output="$(docker run --rm --platform "$PLATFORM" \
  --volume "$HOME_VOLUME:/home/dev" \
  --env HOST_UID=12345 \
  --env HOST_GID=12345 \
  "$IMAGE" bash -lc '
    set -euo pipefail
    test "$(id -u)" -eq 12345
    test "$(id -g)" -eq 12345
    test -w "$HOME"
    test -w "$CODEX_HOME"
    printf "REMAPPED_USER_ID=%s:%s\n" "$(id -u)" "$(id -g)"
  ')"
printf '%s\n' "$remap_output"

echo "镜像 smoke test 通过：$IMAGE ($PLATFORM, Codex $actual_version)"
