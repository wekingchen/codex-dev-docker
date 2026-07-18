#!/usr/bin/env bash
set -euo pipefail

proxy_enabled="${XRAY_PROXY_ENABLED:-false}"
case "$proxy_enabled" in
  true|false) ;;
  *)
    echo "XRAY_PROXY_ENABLED必须为true或false。" >&2
    exit 1
    ;;
esac

pgrep -x sshd >/dev/null
nc -z 127.0.0.1 2222

if [ "$proxy_enabled" = true ]; then
  pgrep -x xray >/dev/null
  nc -z 127.0.0.1 10809
else
  if pgrep -x xray >/dev/null || nc -z 127.0.0.1 10809 >/dev/null 2>&1; then
    echo "代理关闭时不应运行Xray或监听10809。" >&2
    exit 1
  fi
fi
