#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "用法：$0 <authorized_keys或SSH公钥文件>" >&2
  exit 1
fi

KEYS_FILE="$1"

if [ ! -f "$KEYS_FILE" ]; then
  echo "找不到SSH公钥文件：$KEYS_FILE" >&2
  exit 1
fi

if grep -Eq -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$KEYS_FILE"; then
  echo "文件疑似包含私钥，拒绝使用：$KEYS_FILE" >&2
  exit 1
fi

temp_file="$(mktemp)"
trap 'rm -f "$temp_file"' EXIT
key_count=0
line_number=0

while IFS= read -r line || [ -n "$line" ]; do
  line_number=$((line_number + 1))

  if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
    continue
  fi

  if ! [[ "$line" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa)[[:space:]] ]]; then
    echo "第${line_number}行不是不带options的SSH公钥：$KEYS_FILE" >&2
    exit 1
  fi

  printf '%s\n' "$line" > "$temp_file"
  if ! ssh-keygen -l -f "$temp_file" >/dev/null 2>&1; then
    echo "第${line_number}行不是有效的SSH公钥：$KEYS_FILE" >&2
    exit 1
  fi

  key_count=$((key_count + 1))
done < "$KEYS_FILE"

if [ "$key_count" -eq 0 ]; then
  echo "文件不包含有效的SSH公钥：$KEYS_FILE" >&2
  exit 1
fi
