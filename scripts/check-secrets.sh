#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
failed=false

tracked_local_ssh="$(git -C "$REPO_ROOT" ls-files -- '.codex-ssh/**')"
if [ -n "$tracked_local_ssh" ]; then
  echo "禁止跟踪本地SSH授权目录：" >&2
  printf '%s\n' "$tracked_local_ssh" >&2
  failed=true
fi

tracked_xray_config="$(git -C "$REPO_ROOT" ls-files -- '.xray/**' 'xray-config.json' 'xray/config.json')"
if [ -n "$tracked_xray_config" ]; then
  echo "禁止跟踪本地Xray节点配置：" >&2
  printf '%s\n' "$tracked_xray_config" >&2
  failed=true
fi

tracked_claude_state="$(git -C "$REPO_ROOT" ls-files -- \
  ':(glob)**/.claude/.credentials.json' \
  ':(glob)**/.claude/settings.local.json' \
  ':(glob)**/.claude.json')"
if [ -n "$tracked_claude_state" ]; then
  echo "禁止跟踪Claude用户状态或凭据文件：" >&2
  printf '%s\n' "$tracked_claude_state" >&2
  failed=true
fi

while IFS= read -r -d '' file; do
  basename="${file##*/}"
  case "$basename" in
    id_rsa|id_dsa|id_ecdsa|id_ed25519|ssh_host_*_key|*.pem|*.key)
      echo "疑似私钥文件名受Git跟踪：$file" >&2
      failed=true
      ;;
  esac
done < <(git -C "$REPO_ROOT" ls-files -z)

private_key_headers="$(
  git -C "$REPO_ROOT" grep -n -I -E \
    '^[[:space:]]*-----BEGIN (OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----[[:space:]]*$' \
    -- . ':(exclude)scripts/check-secrets.sh' || true
)"
if [ -n "$private_key_headers" ]; then
  echo "受Git跟踪的文件中发现私钥头：" >&2
  printf '%s\n' "$private_key_headers" >&2
  failed=true
fi

anthropic_tokens="$(
  git -C "$REPO_ROOT" grep -n -I -E \
    '(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)[[:space:]]*[:=][[:space:]]*"?(sk-ant-|[A-Za-z0-9_-]{32,})' \
    -- . ':(exclude)scripts/check-secrets.sh' || true
)"
if [ -n "$anthropic_tokens" ]; then
  echo "受Git跟踪的文件中发现疑似Anthropic认证值：" >&2
  printf '%s\n' "$anthropic_tokens" >&2
  failed=true
fi

if ! git -C "$REPO_ROOT" check-ignore -q .codex-ssh/authorized_keys; then
  echo ".gitignore没有排除.codex-ssh/authorized_keys。" >&2
  failed=true
fi

if ! grep -Eq '^\.codex-ssh/?$' "$REPO_ROOT/.dockerignore"; then
  echo ".dockerignore没有排除.codex-ssh。" >&2
  failed=true
fi

for path in .xray/config.json xray/config.json xray-config.json; do
  if ! git -C "$REPO_ROOT" check-ignore -q "$path"; then
    echo ".gitignore没有排除本地Xray配置：$path" >&2
    failed=true
  fi
done
for pattern in '.xray' 'xray/config.json' 'xray-config.json'; do
  if ! grep -Fqx "$pattern" "$REPO_ROOT/.dockerignore"; then
    echo ".dockerignore没有排除本地Xray配置：$pattern" >&2
    failed=true
  fi
done

for path in \
  .claude/.credentials.json \
  .claude/settings.local.json \
  .claude.json \
  nested/project/.claude/.credentials.json \
  nested/project/.claude/settings.local.json \
  nested/project/.claude.json; do
  if ! git -C "$REPO_ROOT" check-ignore -q "$path"; then
    echo ".gitignore没有排除Claude用户状态：$path" >&2
    failed=true
  fi
done

for pattern in '**/.claude/.credentials.json' '**/.claude/settings.local.json' '**/.claude.json'; do
  if ! grep -Fqx "$pattern" "$REPO_ROOT/.dockerignore"; then
    echo ".dockerignore没有排除Claude用户状态：$pattern" >&2
    failed=true
  fi
done

if [ "$failed" = true ]; then
  echo "秘密材料检查失败。" >&2
  exit 1
fi

echo "秘密材料检查通过：未跟踪本地SSH/Xray目录、私钥或Claude认证状态。"
