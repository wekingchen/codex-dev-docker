#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 4 ]; then
  echo "用法：$0 <镜像引用> [期望 Codex 版本|latest] [平台] [期望 mise 版本]" >&2
  exit 1
fi

IMAGE="$1"
EXPECTED_VERSION="${2:-latest}"
PLATFORM="${3:-linux/amd64}"
EXPECTED_MISE_VERSION="${4:-}"
EXPECTED_CLAUDE_VERSION="${EXPECTED_CLAUDE_VERSION:-}"
EXPECTED_CLAUDE_SHA256="${EXPECTED_CLAUDE_SHA256:-}"
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
  --env "SMOKE_EXPECT_CLAUDE_VERSION=$EXPECTED_CLAUDE_VERSION" \
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
    mise_output="$(mise --version)"
    printf "CODEX_OUTPUT=%s\n" "$codex_output"
    printf "CODEX_VERSION=%s\n" "${codex_output##* }"
    printf "MISE_OUTPUT=%s\n" "$mise_output"
    printf "MISE_VERSION=%s\n" "${mise_output%% *}"

    if [ -n "${SMOKE_EXPECT_CLAUDE_VERSION:-}" ]; then
      claude_path="$(command -v claude)"
      test "$claude_path" = /usr/local/bin/claude
      test "$(stat -c %u:%g "$claude_path")" = 0:0
      test "$(stat -c %a "$claude_path")" = 755
      test ! -w "$claude_path"
      test "${DISABLE_AUTOUPDATER:-}" = 1
      test "${DISABLE_UPDATES:-}" = 1
      for variable in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_MODEL CLAUDE_MODEL; do
        test -z "${!variable:-}"
      done
      test ! -e "$HOME/.claude/.credentials.json"
      mkdir -p "$HOME/.claude"
      test -w "$HOME/.claude"
      touch "$HOME/.claude/smoke-persist"
      claude_output="$(claude --version)"
      read -r claude_sha256 _ < <(sha256sum "$claude_path")
      printf "CLAUDE_OUTPUT=%s\n" "$claude_output"
      printf "CLAUDE_VERSION=%s\n" "${claude_output%% *}"
      printf "CLAUDE_SHA256=%s\n" "$claude_sha256"
    fi

    printf "USER_ID=%s:%s\n" "$(id -u)" "$(id -g)"
    printf "ARCH=%s\n" "$(uname -m)"
  ')"

printf '%s\n' "$output"

actual_version=""
actual_mise_version=""
actual_claude_version=""
actual_claude_sha256=""
actual_arch=""
while IFS= read -r line; do
  case "$line" in
    CODEX_VERSION=*) actual_version="${line#*=}" ;;
    MISE_VERSION=*) actual_mise_version="${line#*=}" ;;
    CLAUDE_VERSION=*) actual_claude_version="${line#*=}" ;;
    CLAUDE_SHA256=*) actual_claude_sha256="${line#*=}" ;;
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

if [ -z "$actual_mise_version" ]; then
  echo "无法从 smoke 输出解析 mise 版本。" >&2
  exit 1
fi

if [ -n "$EXPECTED_MISE_VERSION" ] && [ "$actual_mise_version" != "$EXPECTED_MISE_VERSION" ]; then
  echo "mise 版本不匹配：期望 $EXPECTED_MISE_VERSION，实际 $actual_mise_version" >&2
  exit 1
fi

if [ -n "$EXPECTED_CLAUDE_VERSION" ]; then
  if [ "$actual_claude_version" != "$EXPECTED_CLAUDE_VERSION" ]; then
    echo "Claude Code 版本不匹配：期望 $EXPECTED_CLAUDE_VERSION，实际 ${actual_claude_version:-<无法读取>}" >&2
    exit 1
  fi

  if ! [[ "$EXPECTED_CLAUDE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "启用 Claude smoke 时必须提供有效的 EXPECTED_CLAUDE_SHA256。" >&2
    exit 1
  fi

  if [ "$actual_claude_sha256" != "$EXPECTED_CLAUDE_SHA256" ]; then
    echo "Claude Code SHA-256 不匹配：期望 $EXPECTED_CLAUDE_SHA256，实际 ${actual_claude_sha256:-<无法读取>}" >&2
    exit 1
  fi
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
  --env "SMOKE_EXPECT_CLAUDE_VERSION=$EXPECTED_CLAUDE_VERSION" \
  "$IMAGE" bash -lc '
    set -euo pipefail
    test "$(id -u)" -eq 12345
    test "$(id -g)" -eq 12345
    test -w "$HOME"
    test -w "$CODEX_HOME"
    if [ -n "${SMOKE_EXPECT_CLAUDE_VERSION:-}" ]; then
      command -v claude >/dev/null
      test -f "$HOME/.claude/smoke-persist"
      test -w "$HOME/.claude"
    fi
    printf "REMAPPED_USER_ID=%s:%s\n" "$(id -u)" "$(id -g)"
  ')"
printf '%s\n' "$remap_output"

if [ -n "$EXPECTED_CLAUDE_VERSION" ]; then
  echo "镜像 smoke test 通过：$IMAGE ($PLATFORM, Codex $actual_version, Claude Code $actual_claude_version, mise $actual_mise_version)"
else
  echo "镜像 smoke test 通过：$IMAGE ($PLATFORM, Codex $actual_version, mise $actual_mise_version)"
fi
