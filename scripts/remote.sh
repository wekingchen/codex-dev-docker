#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_ARGS=(
  --project-directory "$REPO_ROOT"
  -f "$REPO_ROOT/compose.yaml"
  -f "$REPO_ROOT/compose.remote.yaml"
  --profile remote
)
AUTHORIZED_KEYS_FILE="$REPO_ROOT/.codex-ssh/authorized_keys"

if [ -f "$REPO_ROOT/.env" ]; then
  COMPOSE_ARGS+=(--env-file "$REPO_ROOT/.env")
fi

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

compose_no_pull() {
  CODEX_DEV_PULL_POLICY=never compose "$@"
}

configure_host_identity() {
  if [ "$(uname -s)" = "Linux" ]; then
    export HOST_UID="${HOST_UID:-$(id -u)}"
    export HOST_GID="${HOST_GID:-$(id -g)}"
  fi
}

validate_public_keys() {
  "$SCRIPT_DIR/validate-authorized-keys.sh" "$1"
}

require_authorized_keys() {
  if ! validate_public_keys "$AUTHORIZED_KEYS_FILE"; then
    echo "请先运行：$0 setup-key ~/.ssh/codex_remote_ed25519.pub" >&2
    exit 1
  fi
}

setup_key() {
  local source_file="$1"
  local temp_file

  validate_public_keys "$source_file"
  mkdir -p "$(dirname "$AUTHORIZED_KEYS_FILE")"
  chmod 0700 "$(dirname "$AUTHORIZED_KEYS_FILE")"

  temp_file="$(mktemp "${AUTHORIZED_KEYS_FILE}.tmp.XXXXXX")"
  trap 'rm -f "$temp_file"' RETURN
  install -m 0600 "$source_file" "$temp_file"
  mv -f "$temp_file" "$AUTHORIZED_KEYS_FILE"
  trap - RETURN

  echo "已安装远程登录公钥：$AUTHORIZED_KEYS_FILE"
  ssh-keygen -l -E sha256 -f "$AUTHORIZED_KEYS_FILE"
}

show_fingerprint() {
  local container_id

  container_id="$(compose ps --status running -q codex-ssh)"
  if [ -n "$container_id" ]; then
    compose exec -T codex-ssh \
      ssh-keygen -l -E sha256 -f /etc/ssh/codex-host-keys/ssh_host_ed25519_key.pub
  else
    compose_no_pull run --rm --no-deps --entrypoint ssh-keygen codex-ssh \
      -l -E sha256 -f /etc/ssh/codex-host-keys/ssh_host_ed25519_key.pub
  fi
}

show_connection() {
  local published

  published="$(compose port codex-ssh 2222)"
  echo "容器SSH仅监听宿主机loopback：$published"
  echo "请通过宿主机SSH ProxyJump连接，不要把该端口转发到公网。"
  echo "首次连接前请核对以下host fingerprint："
  show_fingerprint
}

start_remote() {
  local force_recreate="${1:-false}"
  local pull_image="${2:-true}"
  local -a up_args=(up --detach --wait --wait-timeout 120)

  require_authorized_keys
  mkdir -p "$REPO_ROOT/workspace"
  configure_host_identity

  if [ "$force_recreate" = "true" ]; then
    echo "正在拉取并重建Codex远程服务..."
    up_args+=(--force-recreate)
  else
    echo "正在启动Codex远程服务..."
  fi

  if [ "$pull_image" = "true" ]; then
    compose pull codex-ssh
  fi

  # 已显式处理pull，避免Compose因pull_policy=always在up时再次拉取；
  # host key轮换会传入pull_image=false，确保轮换identity时不意外升级镜像。
  if ! compose_no_pull "${up_args[@]}" codex-ssh; then
    compose logs --tail=200 codex-ssh codex-ssh-hostkey-init >&2 || true
    echo "远程服务启动失败，正在回滚已创建的容器。" >&2
    if ! compose rm -f -s codex-ssh codex-ssh-hostkey-init; then
      echo "回滚失败：请立即检查docker compose ps，服务可能仍在运行。" >&2
    fi
    return 1
  fi

  show_connection
}

stop_remote() {
  local remaining

  compose rm -f -s codex-ssh codex-ssh-hostkey-init
  remaining="$(compose ps --status running -q codex-ssh)"
  if [ -n "$remaining" ]; then
    echo "远程服务仍在运行，停止失败：$remaining" >&2
    exit 1
  fi

  echo "已停止远程服务；home、workspace和SSH host key均保留。"
}

rotate_host_key() {
  local key_dir=/etc/ssh/codex-host-keys

  require_authorized_keys
  configure_host_identity
  stop_remote

  echo "正在备份旧SSH host key并生成新identity..."
  compose_no_pull run --rm --no-deps --entrypoint bash codex-ssh-hostkey-init -lc "
    set -euo pipefail
    test -f '$key_dir/ssh_host_ed25519_key'
    test -f '$key_dir/ssh_host_ed25519_key.pub'
    test ! -e '$key_dir/ssh_host_ed25519_key.rotate-backup'
    test ! -e '$key_dir/ssh_host_ed25519_key.pub.rotate-backup'
    cp -p '$key_dir/ssh_host_ed25519_key' '$key_dir/ssh_host_ed25519_key.rotate-backup'
    cp -p '$key_dir/ssh_host_ed25519_key.pub' '$key_dir/ssh_host_ed25519_key.pub.rotate-backup'
    rm -f '$key_dir/ssh_host_ed25519_key' '$key_dir/ssh_host_ed25519_key.pub'
  "

  if ! compose_no_pull run --rm --no-deps codex-ssh-hostkey-init || ! start_remote false false; then
    echo "host key轮换未完成，正在恢复旧identity。" >&2
    compose_no_pull run --rm --no-deps --entrypoint bash codex-ssh-hostkey-init -lc "
      set -euo pipefail
      test -f '$key_dir/ssh_host_ed25519_key.rotate-backup'
      test -f '$key_dir/ssh_host_ed25519_key.pub.rotate-backup'
      rm -f '$key_dir/ssh_host_ed25519_key' '$key_dir/ssh_host_ed25519_key.pub'
      mv '$key_dir/ssh_host_ed25519_key.rotate-backup' '$key_dir/ssh_host_ed25519_key'
      mv '$key_dir/ssh_host_ed25519_key.pub.rotate-backup' '$key_dir/ssh_host_ed25519_key.pub'
    "
    echo "已恢复旧SSH host identity；远程服务保持停止，请排除故障后重新执行up。" >&2
    return 1
  fi

  if ! compose_no_pull run --rm --no-deps --entrypoint bash codex-ssh-hostkey-init -lc "
    rm -f '$key_dir/ssh_host_ed25519_key.rotate-backup' '$key_dir/ssh_host_ed25519_key.pub.rotate-backup'
  "; then
    echo "SSH host identity已经改变，但旧密钥备份清理失败；请立即检查host-key volume。" >&2
    show_fingerprint >&2 || true
    return 1
  fi

  echo "SSH host key已轮换。所有客户端必须删除旧known_hosts记录并核对新fingerprint。"
}

usage() {
  cat <<EOF
用法：
  $0 setup-key <SSH公钥文件>
  $0 up
  $0 update
  $0 status
  $0 logs [docker compose logs参数]
  $0 fingerprint
  $0 rotate-host-key ROTATE
  $0 down
EOF
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 1
fi

command_name="$1"
shift

case "$command_name" in
  setup-key)
    if [ "$#" -ne 1 ]; then
      usage >&2
      exit 1
    fi
    setup_key "$1"
    ;;
  up)
    if [ "$#" -ne 0 ]; then
      usage >&2
      exit 1
    fi
    start_remote false
    ;;
  update)
    if [ "$#" -ne 0 ]; then
      usage >&2
      exit 1
    fi
    start_remote true
    ;;
  status)
    compose ps --all codex-ssh codex-ssh-hostkey-init
    ;;
  logs)
    compose logs "$@" codex-ssh
    ;;
  fingerprint)
    if [ "$#" -ne 0 ]; then
      usage >&2
      exit 1
    fi
    show_fingerprint
    ;;
  rotate-host-key)
    if [ "$#" -ne 1 ] || [ "$1" != "ROTATE" ]; then
      echo "轮换host key会改变服务器identity，必须精确执行：$0 rotate-host-key ROTATE" >&2
      exit 1
    fi
    rotate_host_key
    ;;
  down)
    if [ "$#" -ne 0 ]; then
      usage >&2
      exit 1
    fi
    stop_remote
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
