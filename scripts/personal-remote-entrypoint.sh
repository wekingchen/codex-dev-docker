#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/remote-entrypoint.sh
source /usr/local/bin/remote-entrypoint.sh

XRAY_CONFIG_SOURCE="${XRAY_CONFIG_SOURCE:-/etc/xray/config.json}"
XRAY_CONFIG_RUNTIME="${XRAY_CONFIG_RUNTIME:-/run/xray/config.json}"
XRAY_PROXY_ENABLED="${XRAY_PROXY_ENABLED:-false}"
PROXY_ENV_RUNTIME="${PROXY_ENV_RUNTIME:-/run/codex-proxy/env.sh}"
PROXY_HTTP_URL="http://127.0.0.1:10809"
PROXY_NO_PROXY="localhost,127.0.0.1,::1"
xray_pid=""
shutdown_requested=false

validate_proxy_switch() {
  case "$XRAY_PROXY_ENABLED" in
    true|false) ;;
    *)
      echo "XRAY_PROXY_ENABLED必须严格设置为true或false，实际为：$XRAY_PROXY_ENABLED" >&2
      exit 1
      ;;
  esac
}

validate_reserved_xray_identity() {
  if [ "${HOST_UID:-}" = 65532 ] || [ "${HOST_GID:-}" = 65532 ]; then
    echo "HOST_UID/HOST_GID不得使用Xray保留的65532。" >&2
    exit 1
  fi
}

validate_no_external_proxy_environment() {
  local variable

  for variable in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
    if [ -n "${!variable:-}" ]; then
      echo "不要在Stack中直接设置$variable；请只使用XRAY_PROXY_ENABLED开关。" >&2
      exit 1
    fi
  done
}

clear_proxy_environment() {
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
  unset http_proxy https_proxy all_proxy no_proxy
}

write_proxy_environment() {
  local runtime_dir

  runtime_dir="$(dirname "$PROXY_ENV_RUNTIME")"
  install -d -m 0755 -o root -g root "$runtime_dir"
  if [ "$XRAY_PROXY_ENABLED" = true ]; then
    cat > "$PROXY_ENV_RUNTIME" <<EOF
export HTTP_PROXY='$PROXY_HTTP_URL'
export HTTPS_PROXY='$PROXY_HTTP_URL'
export NO_PROXY='$PROXY_NO_PROXY'
export http_proxy='$PROXY_HTTP_URL'
export https_proxy='$PROXY_HTTP_URL'
export no_proxy='$PROXY_NO_PROXY'
unset ALL_PROXY all_proxy
EOF
  else
    cat > "$PROXY_ENV_RUNTIME" <<'EOF'
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy
EOF
  fi
  chmod 0644 "$PROXY_ENV_RUNTIME"
  chown root:root "$PROXY_ENV_RUNTIME"
}

append_proxy_to_sshd_setenv() {
  local setenv_count

  setenv_count="$(grep -Ec '^SetEnv[[:space:]]+' "$SSHD_CONFIG_RUNTIME" || true)"
  if [ "$setenv_count" -ne 1 ]; then
    echo "personal runtime sshd配置必须且只能包含一条SetEnv，实际${setenv_count}条。" >&2
    exit 1
  fi
  if grep -Eiq '(^|[[:space:]])(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy)=' "$SSHD_CONFIG_RUNTIME"; then
    echo "baked sshd模板不得预置代理变量。" >&2
    exit 1
  fi

  sed -i \
    "/^SetEnv[[:space:]]/s|$| HTTP_PROXY=${PROXY_HTTP_URL} HTTPS_PROXY=${PROXY_HTTP_URL} NO_PROXY=${PROXY_NO_PROXY} http_proxy=${PROXY_HTTP_URL} https_proxy=${PROXY_HTTP_URL} no_proxy=${PROXY_NO_PROXY}|" \
    "$SSHD_CONFIG_RUNTIME"

  if [ "$(grep -Ec '^SetEnv[[:space:]]+' "$SSHD_CONFIG_RUNTIME")" -ne 1 ]; then
    echo "追加代理变量后sshd配置出现重复SetEnv。" >&2
    exit 1
  fi
}

validate_xray_config_source() {
  local mode routing_policy

  if [ ! -f "$XRAY_CONFIG_SOURCE" ] || [ -L "$XRAY_CONFIG_SOURCE" ]; then
    echo "代理已启用但Xray配置缺失、不是普通文件或是符号链接：$XRAY_CONFIG_SOURCE" >&2
    exit 1
  fi

  mode="$(stat -c %a "$XRAY_CONFIG_SOURCE")"
  if (( (8#$mode & 0400) == 0 || (8#$mode & 0077) != 0 )); then
    echo "Xray配置必须仅允许owner读取，可选owner写入；group/other不得有任何权限：$XRAY_CONFIG_SOURCE mode=$mode" >&2
    exit 1
  fi

  if ! routing_policy="$(/usr/local/bin/validate-xray-config.sh "$XRAY_CONFIG_SOURCE")"; then
    exit 1
  fi
  printf 'Xray路由策略验证通过：%s\n' "$routing_policy"
}

install_xray_runtime_config() {
  install -d -m 0750 -o root -g xray "$(dirname "$XRAY_CONFIG_RUNTIME")"
  install -m 0640 -o root -g xray "$XRAY_CONFIG_SOURCE" "$XRAY_CONFIG_RUNTIME"
  (
    cd /
    exec env HOME=/nonexistent USER=xray LOGNAME=xray \
      gosu xray:xray /usr/local/bin/xray run -test -c "$XRAY_CONFIG_RUNTIME"
  )
}

start_xray() {
  (
    cd /
    exec env \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
      -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
      HOME=/nonexistent USER=xray LOGNAME=xray \
      gosu xray:xray /usr/local/bin/xray run -c "$XRAY_CONFIG_RUNTIME"
  ) &
  xray_pid="$!"
}

wait_for_xray_readiness() {
  local _attempt

  for _attempt in $(seq 1 30); do
    if ! kill -0 "$xray_pid" 2>/dev/null; then
      wait "$xray_pid" || true
      echo "Xray在HTTP inbound就绪前退出。" >&2
      exit 1
    fi
    if nc -z 127.0.0.1 10809 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "等待Xray HTTP inbound就绪超时。" >&2
  return 1
}

# shellcheck disable=SC2317,SC2329  # 由下面的signal trap间接调用。
forward_all_signal() {
  local signal="$1"

  shutdown_requested=true
  if [ -n "$xray_pid" ] && kill -0 "$xray_pid" 2>/dev/null; then
    kill "-$signal" "$xray_pid"
  fi
  remote_forward_sshd_signal "$signal"
}

wait_for_dual_processes() {
  local first_status xray_status sshd_status

  set +e
  wait -n "$xray_pid" "$sshd_pid"
  first_status="$?"
  set -e

  if [ "$shutdown_requested" = false ]; then
    echo "Xray或sshd意外退出，正在停止同容器中的另一个服务。" >&2
  fi

  if [ -n "$xray_pid" ] && kill -0 "$xray_pid" 2>/dev/null; then
    kill -TERM "$xray_pid" 2>/dev/null || true
  fi
  remote_forward_sshd_signal TERM

  set +e
  wait "$xray_pid"
  xray_status="$?"
  wait "$sshd_pid"
  sshd_status="$?"
  set -e

  if [ "$shutdown_requested" = true ]; then
    return 0
  fi
  if [ "$first_status" -eq 0 ]; then
    echo "长期服务不应正常提前退出：xray=$xray_status sshd=$sshd_status" >&2
    return 1
  fi
  return "$first_status"
}

run_sshd_only() {
  local sshd_status

  trap 'remote_forward_sshd_signal TERM' TERM
  trap 'remote_forward_sshd_signal INT' INT
  trap 'remote_forward_sshd_signal HUP' HUP

  remote_start_sshd
  set +e
  remote_wait_for_sshd
  sshd_status="$?"
  set -e
  trap - TERM INT HUP
  return "$sshd_status"
}

main() {
  local status

  validate_proxy_switch
  validate_reserved_xray_identity
  validate_no_external_proxy_environment
  clear_proxy_environment
  remote_prepare_runtime
  write_proxy_environment

  if [ "$XRAY_PROXY_ENABLED" = false ]; then
    remote_validate_sshd_config
    run_sshd_only
    return $?
  fi

  validate_xray_config_source
  install_xray_runtime_config
  append_proxy_to_sshd_setenv
  remote_validate_sshd_config

  trap 'forward_all_signal TERM' TERM
  trap 'forward_all_signal INT' INT
  trap 'forward_all_signal HUP' HUP

  start_xray
  if ! wait_for_xray_readiness; then
    kill -TERM "$xray_pid" 2>/dev/null || true
    wait "$xray_pid" 2>/dev/null || true
    exit 1
  fi
  remote_start_sshd

  set +e
  wait_for_dual_processes
  status="$?"
  set -e
  trap - TERM INT HUP
  return "$status"
}

main "$@"
