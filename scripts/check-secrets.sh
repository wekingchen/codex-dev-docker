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

if ! git -C "$REPO_ROOT" check-ignore -q .codex-ssh/authorized_keys; then
  echo ".gitignore没有排除.codex-ssh/authorized_keys。" >&2
  failed=true
fi

if ! grep -Eq '^\.codex-ssh/?$' "$REPO_ROOT/.dockerignore"; then
  echo ".dockerignore没有排除.codex-ssh。" >&2
  failed=true
fi

if [ "$failed" = true ]; then
  echo "秘密材料检查失败。" >&2
  exit 1
fi

echo "秘密材料检查通过：未跟踪本地SSH目录、私钥文件或私钥内容。"
