#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 6 ]; then
  echo "用法：$0 <remote镜像> [期望Codex版本|latest] [平台] [期望mise版本] [base镜像] [远程用户名]" >&2
  exit 1
fi

REMOTE_IMAGE="$1"
EXPECTED_VERSION="${2:-latest}"
PLATFORM="${3:-linux/amd64}"
EXPECTED_MISE_VERSION="${4:-}"
BASE_IMAGE="${5:-}"
REMOTE_USER="${6:-dev}"
REMOTE_HOME="/home/${REMOTE_USER}"
TEST_ID="codex-remote-smoke-$$-${RANDOM:-0}"
CONTAINER_NAME="${TEST_ID}"
HOME_VOLUME="${TEST_ID}-home"
HOST_KEY_VOLUME="${TEST_ID}-hostkeys"
TEMP_DIR="$(mktemp -d)"
WORKSPACE_DIR="${TEMP_DIR}/workspace"
CLIENT_KEY="${TEMP_DIR}/client_ed25519"
WRONG_KEY="${TEMP_DIR}/wrong_ed25519"
KNOWN_HOSTS="${TEMP_DIR}/known_hosts"
SSH_PORT=""

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker volume rm -f "$HOME_VOLUME" "$HOST_KEY_VOLUME" >/dev/null 2>&1 || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

mkdir -p "$WORKSPACE_DIR"
ssh-keygen -q -t ed25519 -N '' -C 'codex-remote-smoke' -f "$CLIENT_KEY"
ssh-keygen -q -t ed25519 -N '' -C 'codex-remote-wrong-key' -f "$WRONG_KEY"
docker volume create "$HOME_VOLUME" >/dev/null
docker volume create "$HOST_KEY_VOLUME" >/dev/null

docker run --rm --platform "$PLATFORM" \
  --entrypoint /usr/local/bin/remote-hostkey-init.sh \
  --volume "$HOST_KEY_VOLUME:/etc/ssh/codex-host-keys" \
  "$REMOTE_IMAGE"

volume_fingerprint="$(docker run --rm --platform "$PLATFORM" \
  --entrypoint ssh-keygen \
  --volume "$HOST_KEY_VOLUME:/keys:ro" \
  "$REMOTE_IMAGE" -l -E sha256 -f /keys/ssh_host_ed25519_key.pub | awk '{print $2}')"

start_remote() {
  docker run -d --platform "$PLATFORM" \
    --name "$CONTAINER_NAME" \
    --publish 127.0.0.1::2222 \
    --volume "$HOME_VOLUME:$REMOTE_HOME" \
    --volume "$HOST_KEY_VOLUME:/etc/ssh/codex-host-keys:ro" \
    --volume "$CLIENT_KEY.pub:/etc/codex-ssh/authorized_keys.input:ro" \
    --volume "$WORKSPACE_DIR:/workspace" \
    --tmpfs /run:rw,nosuid,nodev,mode=0755 \
    --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
    --env "HOST_UID=$(id -u)" \
    --env "HOST_GID=$(id -g)" \
    "$REMOTE_IMAGE" >/dev/null

  SSH_PORT="$(docker port "$CONTAINER_NAME" 2222/tcp | awk -F: 'NR == 1 {print $NF}')"
  if [ -z "$SSH_PORT" ]; then
    echo "无法读取 SSH 映射端口。" >&2
    exit 1
  fi
}

wait_for_ssh() {
  : > "$KNOWN_HOSTS"
  for _attempt in $(seq 1 60); do
    if ! docker inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
      docker logs "$CONTAINER_NAME" >&2 || true
      echo "remote容器在 SSH 就绪前退出。" >&2
      exit 1
    fi

    if ssh-keyscan -T 2 -p "$SSH_PORT" 127.0.0.1 > "$KNOWN_HOSTS" 2>/dev/null \
      && [ -s "$KNOWN_HOSTS" ]; then
      return 0
    fi
    sleep 1
  done

  docker logs "$CONTAINER_NAME" >&2 || true
  echo "等待 SSH 就绪超时。" >&2
  exit 1
}

ssh_run() {
  ssh \
    -p "$SSH_PORT" \
    -i "$CLIENT_KEY" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$KNOWN_HOSTS" \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o PreferredAuthentications=publickey \
    "${REMOTE_USER}@127.0.0.1" "$@"
}

start_remote
wait_for_ssh

scanned_fingerprint="$(ssh-keygen -l -E sha256 -f "$KNOWN_HOSTS" | awk 'NR == 1 {print $2}')"
if [ "$scanned_fingerprint" != "$volume_fingerprint" ]; then
  echo "SSH host fingerprint不匹配：volume=$volume_fingerprint scan=$scanned_fingerprint" >&2
  exit 1
fi

remote_check_script="$(cat <<'EOF'
set -euo pipefail
test "$(id -u)" -eq "$EXPECTED_UID"
test "$(id -g)" -eq "$EXPECTED_GID"
test "$HOME" = "$EXPECTED_HOME"
test "$CODEX_HOME" = "$EXPECTED_HOME/.codex"
test -w "$HOME"
test -w /workspace
touch /workspace/.remote-smoke-write
rm -f /workspace/.remote-smoke-write
sudo -n true
codex_output="$(codex --version)"
mise_output="$(mise --version)"
printf "CODEX_VERSION=%s\n" "${codex_output##* }"
printf "MISE_VERSION=%s\n" "${mise_output%% *}"
printf "USER_ID=%s:%s\n" "$(id -u)" "$(id -g)"
printf "ARCH=%s\n" "$(uname -m)"
test -z "${SSH_AUTH_SOCK:-}"
EOF
)"
printf -v remote_check_quoted '%q' "$remote_check_script"
if ! output="$(ssh_run "EXPECTED_UID=$(id -u) EXPECTED_GID=$(id -g) EXPECTED_HOME=$REMOTE_HOME bash -lc $remote_check_quoted")"; then
  docker logs "$CONTAINER_NAME" >&2 || true
  echo "正确公钥无法完成remote SSH smoke。" >&2
  exit 1
fi
printf '%s\n' "$output"

actual_version="$(awk -F= '$1 == "CODEX_VERSION" {print $2; exit}' <<< "$output")"
actual_mise_version="$(awk -F= '$1 == "MISE_VERSION" {print $2; exit}' <<< "$output")"
actual_arch="$(awk -F= '$1 == "ARCH" {print $2; exit}' <<< "$output")"

if [ -z "$actual_version" ] || { [ "$EXPECTED_VERSION" != latest ] && [ "$actual_version" != "$EXPECTED_VERSION" ]; }; then
  echo "Codex版本不匹配：期望$EXPECTED_VERSION，实际${actual_version:-<无法读取>}" >&2
  exit 1
fi

if [ -n "$EXPECTED_MISE_VERSION" ] && [ "$actual_mise_version" != "$EXPECTED_MISE_VERSION" ]; then
  echo "mise版本不匹配：期望$EXPECTED_MISE_VERSION，实际${actual_mise_version:-<无法读取>}" >&2
  exit 1
fi

case "$PLATFORM:$actual_arch" in
  linux/amd64:x86_64|linux/arm64:aarch64|linux/arm64:arm64) ;;
  *)
    echo "镜像架构不匹配：平台$PLATFORM，容器报告$actual_arch" >&2
    exit 1
    ;;
esac

if ssh -p "$SSH_PORT" -i "$WRONG_KEY" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$KNOWN_HOSTS" "${REMOTE_USER}@127.0.0.1" true >/dev/null 2>&1; then
  echo "错误公钥不应能够登录。" >&2
  exit 1
fi

if ssh -p "$SSH_PORT" -i "$CLIENT_KEY" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$KNOWN_HOSTS" root@127.0.0.1 true >/dev/null 2>&1; then
  echo "root不应能够登录。" >&2
  exit 1
fi

if ssh -p "$SSH_PORT" \
  -o BatchMode=yes -o PubkeyAuthentication=no -o PasswordAuthentication=yes \
  -o KbdInteractiveAuthentication=yes -o PreferredAuthentications=password,keyboard-interactive \
  -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS" \
  "${REMOTE_USER}@127.0.0.1" true >/dev/null 2>&1; then
  echo "密码认证不应能够登录。" >&2
  exit 1
fi

docker exec "$CONTAINER_NAME" bash -lc '
  set -euo pipefail
  test "$(stat -c %U:%G /run/codex-ssh/authorized_keys)" = root:root
  test "$(stat -c %a /run/codex-ssh/authorized_keys)" = 644
  effective="$(/usr/sbin/sshd -T -f /run/codex-ssh/sshd_config)"
  grep -qx "permitrootlogin no" <<< "$effective"
  grep -qx "passwordauthentication no" <<< "$effective"
  grep -qx "kbdinteractiveauthentication no" <<< "$effective"
  grep -qx "allowagentforwarding no" <<< "$effective"
  grep -qx "allowtcpforwarding no" <<< "$effective"
  grep -qx "allowstreamlocalforwarding no" <<< "$effective"
  grep -qx "x11forwarding no" <<< "$effective"
  grep -qx "permittunnel no" <<< "$effective"
'

docker run --rm --platform "$PLATFORM" --entrypoint bash "$REMOTE_IMAGE" -lc \
  '! find /etc/ssh -type f -name "ssh_host_*_key" -print -quit | grep -q .'

if [ -n "$BASE_IMAGE" ]; then
  set +e
  docker run --rm --platform "$PLATFORM" \
    --volume "$HOME_VOLUME:$REMOTE_HOME" \
    "$BASE_IMAGE" true >/dev/null 2>&1
  lock_status=$?
  set -e
  if [ "$lock_status" -ne 73 ]; then
    echo "remote运行时，base应因共享home锁退出73，实际退出$lock_status。" >&2
    exit 1
  fi
fi

docker rm -f "$CONTAINER_NAME" >/dev/null
start_remote
wait_for_ssh

restart_fingerprint="$(ssh-keygen -l -E sha256 -f "$KNOWN_HOSTS" | awk 'NR == 1 {print $2}')"
if [ "$restart_fingerprint" != "$volume_fingerprint" ]; then
  echo "重建容器后SSH host fingerprint发生变化。" >&2
  exit 1
fi
ssh_run true

if [ -n "$BASE_IMAGE" ]; then
  docker rm -f "$CONTAINER_NAME" >/dev/null
  docker run --rm --platform "$PLATFORM" \
    --volume "$HOME_VOLUME:$REMOTE_HOME" \
    "$BASE_IMAGE" true
fi

echo "remote SSH smoke通过：$REMOTE_IMAGE ($PLATFORM, Codex $actual_version, mise $actual_mise_version)"
