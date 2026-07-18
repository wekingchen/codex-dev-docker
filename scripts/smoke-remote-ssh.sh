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
EXPECTED_CLAUDE_VERSION="${EXPECTED_CLAUDE_VERSION:-}"
EXPECTED_CLAUDE_SHA256="${EXPECTED_CLAUDE_SHA256:-}"
EXPECTED_XRAY_VERSION="${EXPECTED_XRAY_VERSION:-}"
EXPECTED_XRAY_SHA256="${EXPECTED_XRAY_SHA256:-}"
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
XRAY_CONFIG="${TEMP_DIR}/xray-cn-direct.json"
XRAY_ALL_PROXY_CONFIG="${TEMP_DIR}/xray-all-proxy.json"
XRAY_PROXY_ENABLED_FOR_RUN=false
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
cat > "$XRAY_CONFIG" <<'EOF'
{
  "log": {
    "access": "none",
    "loglevel": "warning",
    "dnsLog": false
  },
  "inbounds": [
    {
      "tag": "local-http",
      "listen": "127.0.0.1",
      "port": 10809,
      "protocol": "http",
      "settings": {}
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 9
          }
        ]
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP",
        "finalRules": [
          {
            "action": "block",
            "ip": ["geoip:private"]
          }
        ]
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": ["geosite:cn"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["geoip:cn"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
jq '.outbounds = [.outbounds[0]] | .routing = {"domainStrategy": "AsIs", "rules": []}' \
  "$XRAY_CONFIG" > "$XRAY_ALL_PROXY_CONFIG"
chmod 0600 "$XRAY_CONFIG" "$XRAY_ALL_PROXY_CONFIG"
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
  local -a docker_args
  docker_args=(
    run -d --platform "$PLATFORM"
    --name "$CONTAINER_NAME"
    --publish 127.0.0.1::2222
    --volume "$HOME_VOLUME:$REMOTE_HOME"
    --volume "$HOST_KEY_VOLUME:/etc/ssh/codex-host-keys:ro"
    --volume "$CLIENT_KEY.pub:/etc/codex-ssh/authorized_keys.input:ro"
    --volume "$WORKSPACE_DIR:/workspace"
    --tmpfs "/run:rw,nosuid,nodev,mode=0755"
    --tmpfs "/tmp:rw,nosuid,nodev,mode=1777"
    --env "HOST_UID=$(id -u)"
    --env "HOST_GID=$(id -g)"
  )

  if [ -n "$EXPECTED_XRAY_VERSION" ]; then
    docker_args+=(--env "XRAY_PROXY_ENABLED=$XRAY_PROXY_ENABLED_FOR_RUN")
    if [ "$XRAY_PROXY_ENABLED_FOR_RUN" = true ]; then
      docker_args+=(--volume "$XRAY_CONFIG:/etc/xray/config.json:ro")
    fi
  fi

  docker "${docker_args[@]}" "$REMOTE_IMAGE" >/dev/null

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

validate_xray_policy() {
  local config_file="$1"
  local expected_policy="$2"
  local actual_policy

  actual_policy="$(docker run --rm --platform "$PLATFORM" \
    --entrypoint /usr/local/bin/validate-xray-config.sh \
    --volume "$config_file:/config.json:ro" \
    "$REMOTE_IMAGE" /config.json)"
  if [ "$actual_policy" != "$expected_policy" ]; then
    echo "Xray配置策略识别错误：期望$expected_policy，实际$actual_policy" >&2
    exit 1
  fi
}

expect_xray_policy_rejected() {
  local name="$1"
  local filter="$2"
  local invalid_config="${TEMP_DIR}/xray-invalid-${name}.json"

  jq "$filter" "$XRAY_CONFIG" > "$invalid_config"
  chmod 0600 "$invalid_config"
  if docker run --rm --platform "$PLATFORM" \
    --entrypoint /usr/local/bin/validate-xray-config.sh \
    --volume "$invalid_config:/config.json:ro" \
    "$REMOTE_IMAGE" /config.json >/dev/null 2>&1; then
    echo "Xray不安全配置不应通过验证：$name" >&2
    exit 1
  fi
}

if [ -n "$EXPECTED_XRAY_VERSION" ]; then
  if ! [[ "$EXPECTED_XRAY_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "启用Xray smoke时必须提供有效的EXPECTED_XRAY_SHA256。" >&2
    exit 1
  fi

  validate_xray_policy "$XRAY_ALL_PROXY_CONFIG" all-proxy
  validate_xray_policy "$XRAY_CONFIG" cn-direct
  expect_xray_policy_rejected freedom-default '.outbounds = [.outbounds[1], .outbounds[0], .outbounds[2]]'
  expect_xray_policy_rejected freedom-wrong-tag '.outbounds[1].tag = "bypass"'
  expect_xray_policy_rejected multiple-freedom '.outbounds += [{"tag":"direct2","protocol":"freedom","settings":{"domainStrategy":"UseIP"}}]'
  expect_xray_policy_rejected missing-block '.outbounds |= map(select(.tag != "block"))'
  expect_xray_policy_rejected duplicate-tag '.outbounds[2].tag = "direct"'
  expect_xray_policy_rejected wrong-domain-strategy '.routing.domainStrategy = "AsIs"'
  expect_xray_policy_rejected missing-final-private-block '.outbounds[1].settings |= del(.finalRules)'
  expect_xray_policy_rejected wrong-final-private-block '.outbounds[1].settings.finalRules[0].ip = ["geoip:cn"]'
  expect_xray_policy_rejected private-block-order '.routing.rules = [.routing.rules[1], .routing.rules[0], .routing.rules[2]]'
  expect_xray_policy_rejected private-direct '.routing.rules[0].outboundTag = "direct"'
  expect_xray_policy_rejected broad-domain '.routing.rules[1].domain = ["geosite:geolocation-!cn"]'
  expect_xray_policy_rejected broad-ip '.routing.rules[2].ip = ["0.0.0.0/0"]'
  expect_xray_policy_rejected extra-direct-rule '.routing.rules += [{"type":"field","network":"tcp,udp","outboundTag":"direct"}]'
  expect_xray_policy_rejected direct-balancer '.routing.balancers = [{"tag":"direct-balancer","selector":["direct"]}]'
  expect_xray_policy_rejected direct-dialer '.outbounds[0].streamSettings.sockopt.dialerProxy = "direct"'

  if docker run --rm --platform "$PLATFORM" \
    --env XRAY_PROXY_ENABLED=invalid \
    "$REMOTE_IMAGE" >/dev/null 2>&1; then
    echo "无效XRAY_PROXY_ENABLED不应允许personal-remote启动。" >&2
    exit 1
  fi

  if docker run --rm --platform "$PLATFORM" \
    --env HOST_UID=1000 \
    --env HOST_GID=65532 \
    "$REMOTE_IMAGE" >/dev/null 2>&1; then
    echo "personal-remote不应允许HOST_UID/HOST_GID占用Xray保留身份65532。" >&2
    exit 1
  fi

  if docker run --rm --platform "$PLATFORM" \
    --env HTTP_PROXY=http://untrusted-proxy.invalid:8080 \
    "$REMOTE_IMAGE" >/dev/null 2>&1; then
    echo "personal-remote不应接受绕过XRAY_PROXY_ENABLED的外部代理环境。" >&2
    exit 1
  fi

  if docker run --rm --platform "$PLATFORM" \
    --volume "$HOME_VOLUME:$REMOTE_HOME" \
    --volume "$HOST_KEY_VOLUME:/etc/ssh/codex-host-keys:ro" \
    --volume "$CLIENT_KEY.pub:/etc/codex-ssh/authorized_keys.input:ro" \
    --volume "$WORKSPACE_DIR:/workspace" \
    --tmpfs /run:rw,nosuid,nodev,mode=0755 \
    --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
    --env "HOST_UID=$(id -u)" \
    --env "HOST_GID=$(id -g)" \
    --env XRAY_PROXY_ENABLED=true \
    --env XRAY_CONFIG_SOURCE=/etc/xray/missing.json \
    "$REMOTE_IMAGE" >/dev/null 2>&1; then
    echo "启用代理但缺少Xray配置时不应启动personal-remote。" >&2
    exit 1
  fi

  XRAY_PROXY_ENABLED_FOR_RUN=false
  start_remote
  wait_for_ssh
  # shellcheck disable=SC2016  # 变量必须在远程SSH会话中展开。
  ssh_run 'set -euo pipefail; test -z "${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${NO_PROXY:-}${http_proxy:-}${https_proxy:-}${all_proxy:-}${no_proxy:-}"'
  docker exec "$CONTAINER_NAME" bash -lc '
    set -euo pipefail
    runtime_config=/run/codex-ssh/sshd_config
    ! pgrep -x xray >/dev/null
    ! nc -z 127.0.0.1 10809 >/dev/null 2>&1
    test -z "${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${NO_PROXY:-}${http_proxy:-}${https_proxy:-}${all_proxy:-}${no_proxy:-}"
    test "$(grep -Ec "^SetEnv[[:space:]]+" "$runtime_config")" -eq 1
    ! grep -Eiq "(^|[[:space:]])(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy)=" "$runtime_config"
  '
  docker rm -f "$CONTAINER_NAME" >/dev/null
  XRAY_PROXY_ENABLED_FOR_RUN=true
fi

start_remote
wait_for_ssh

scanned_fingerprint="$(ssh-keygen -l -E sha256 -f "$KNOWN_HOSTS" | awk 'NR == 1 {print $2}')"
if [ "$scanned_fingerprint" != "$volume_fingerprint" ]; then
  echo "SSH host fingerprint不匹配：volume=$volume_fingerprint scan=$scanned_fingerprint" >&2
  exit 1
fi

remote_check_script="$(cat <<'EOF'
set -euo pipefail
trap 'status=$?; printf "remote SSH smoke断言失败：line=%s status=%s command=%q\n" "$LINENO" "$status" "$BASH_COMMAND" >&2; exit "$status"' ERR
test "$(id -u)" -eq "$EXPECTED_UID"
test "$(id -g)" -eq "$EXPECTED_GID"
test "$HOME" = "$EXPECTED_HOME"
test "$CODEX_HOME" = "$EXPECTED_HOME/.codex"
test "$MISE_DATA_DIR" = "$EXPECTED_HOME/.local/share/mise"
test "$MISE_CONFIG_DIR" = "$EXPECTED_HOME/.config/mise"
test -w "$HOME"
test -w /workspace
touch /workspace/.remote-smoke-write
rm -f /workspace/.remote-smoke-write
sudo -n true
codex_output="$(codex --version)"
mise_output="$(mise --version)"
printf "CODEX_VERSION=%s\n" "${codex_output##* }"
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
  touch "$HOME/.claude/remote-smoke-persist"
  claude_output="$(claude --version)"
  read -r claude_sha256 _ < <(sha256sum "$claude_path")
  printf "CLAUDE_VERSION=%s\n" "${claude_output%% *}"
  printf "CLAUDE_SHA256=%s\n" "$claude_sha256"
fi

if [ -n "${SMOKE_EXPECT_XRAY_VERSION:-}" ]; then
  test "${HTTP_PROXY:-}" = http://127.0.0.1:10809
  test "${HTTPS_PROXY:-}" = http://127.0.0.1:10809
  test "${NO_PROXY:-}" = localhost,127.0.0.1,::1
  test "${http_proxy:-}" = http://127.0.0.1:10809
  test "${https_proxy:-}" = http://127.0.0.1:10809
  test "${no_proxy:-}" = localhost,127.0.0.1,::1
  test -z "${ALL_PROXY:-}${all_proxy:-}"
  xray_output="$(xray version | sed -n '1p')"
  printf "XRAY_VERSION=%s\n" "$(awk '{print $2}' <<< "$xray_output")"
fi

printf "USER_ID=%s:%s\n" "$(id -u)" "$(id -g)"
printf "ARCH=%s\n" "$(uname -m)"
test -z "${SSH_AUTH_SOCK:-}"
EOF
)"
printf -v remote_check_quoted '%q' "$remote_check_script"
if ! output="$(ssh_run "EXPECTED_UID=$(id -u) EXPECTED_GID=$(id -g) EXPECTED_HOME=$REMOTE_HOME SMOKE_EXPECT_CLAUDE_VERSION=$EXPECTED_CLAUDE_VERSION SMOKE_EXPECT_XRAY_VERSION=$EXPECTED_XRAY_VERSION bash -lc $remote_check_quoted")"; then
  docker logs "$CONTAINER_NAME" >&2 || true
  echo "正确公钥无法完成remote SSH smoke。" >&2
  exit 1
fi
printf '%s\n' "$output"

actual_version="$(awk -F= '$1 == "CODEX_VERSION" {print $2; exit}' <<< "$output")"
actual_mise_version="$(awk -F= '$1 == "MISE_VERSION" {print $2; exit}' <<< "$output")"
actual_claude_version="$(awk -F= '$1 == "CLAUDE_VERSION" {print $2; exit}' <<< "$output")"
actual_claude_sha256="$(awk -F= '$1 == "CLAUDE_SHA256" {print $2; exit}' <<< "$output")"
actual_xray_version="$(awk -F= '$1 == "XRAY_VERSION" {print $2; exit}' <<< "$output")"
actual_arch="$(awk -F= '$1 == "ARCH" {print $2; exit}' <<< "$output")"

if [ -z "$actual_version" ] || { [ "$EXPECTED_VERSION" != latest ] && [ "$actual_version" != "$EXPECTED_VERSION" ]; }; then
  echo "Codex版本不匹配：期望$EXPECTED_VERSION，实际${actual_version:-<无法读取>}" >&2
  exit 1
fi

if [ -n "$EXPECTED_MISE_VERSION" ] && [ "$actual_mise_version" != "$EXPECTED_MISE_VERSION" ]; then
  echo "mise版本不匹配：期望$EXPECTED_MISE_VERSION，实际${actual_mise_version:-<无法读取>}" >&2
  exit 1
fi

if [ -n "$EXPECTED_CLAUDE_VERSION" ]; then
  if [ "$actual_claude_version" != "$EXPECTED_CLAUDE_VERSION" ]; then
    echo "Claude Code版本不匹配：期望$EXPECTED_CLAUDE_VERSION，实际${actual_claude_version:-<无法读取>}" >&2
    exit 1
  fi

  if ! [[ "$EXPECTED_CLAUDE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "启用Claude smoke时必须提供有效的EXPECTED_CLAUDE_SHA256。" >&2
    exit 1
  fi

  if [ "$actual_claude_sha256" != "$EXPECTED_CLAUDE_SHA256" ]; then
    echo "Claude Code SHA-256不匹配：期望$EXPECTED_CLAUDE_SHA256，实际${actual_claude_sha256:-<无法读取>}" >&2
    exit 1
  fi
fi

if [ -n "$EXPECTED_XRAY_VERSION" ]; then
  if [ "$actual_xray_version" != "$EXPECTED_XRAY_VERSION" ]; then
    echo "Xray版本不匹配：期望$EXPECTED_XRAY_VERSION，实际${actual_xray_version:-<无法读取>}" >&2
    exit 1
  fi

  xray_label_version="$(docker inspect "$CONTAINER_NAME" --format '{{ index .Config.Labels "io.codex-dev.xray.version" }}')"
  case "$PLATFORM" in
    linux/amd64) xray_digest_label='io.codex-dev.xray.sha256-amd64' ;;
    linux/arm64) xray_digest_label='io.codex-dev.xray.sha256-arm64' ;;
    *) echo "不支持的Xray smoke平台：$PLATFORM" >&2; exit 1 ;;
  esac
  xray_label_sha256="$(docker inspect "$CONTAINER_NAME" --format "{{ index .Config.Labels \"$xray_digest_label\" }}")"
  if [ "$xray_label_version" != "$EXPECTED_XRAY_VERSION" ] || [ "$xray_label_sha256" != "$EXPECTED_XRAY_SHA256" ]; then
    echo "Xray OCI label不匹配：version=${xray_label_version:-<空>} sha256=${xray_label_sha256:-<空>}" >&2
    exit 1
  fi
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

docker exec \
  --env "EXPECTED_HOME=$REMOTE_HOME" \
  --env "SMOKE_EXPECT_CLAUDE_VERSION=$EXPECTED_CLAUDE_VERSION" \
  --env "SMOKE_EXPECT_XRAY_VERSION=$EXPECTED_XRAY_VERSION" \
  "$CONTAINER_NAME" bash -lc '
  set -euo pipefail
  runtime_config=/run/codex-ssh/sshd_config
  test "$(stat -c %U:%G /run/codex-ssh/authorized_keys)" = root:root
  test "$(stat -c %a /run/codex-ssh/authorized_keys)" = 644
  test "$(grep -Ec "^SetEnv[[:space:]]+" "$runtime_config")" -eq 1

  expected_setenv="SetEnv CODEX_HOME=$EXPECTED_HOME/.codex MISE_DATA_DIR=$EXPECTED_HOME/.local/share/mise MISE_CONFIG_DIR=$EXPECTED_HOME/.config/mise"
  expected_tokens=(
    "CODEX_HOME=$EXPECTED_HOME/.codex"
    "MISE_DATA_DIR=$EXPECTED_HOME/.local/share/mise"
    "MISE_CONFIG_DIR=$EXPECTED_HOME/.config/mise"
  )
  if [ -n "$SMOKE_EXPECT_CLAUDE_VERSION" ]; then
    expected_setenv+=" DISABLE_AUTOUPDATER=1 DISABLE_UPDATES=1"
    expected_tokens+=("DISABLE_AUTOUPDATER=1" "DISABLE_UPDATES=1")
  fi
  if [ -n "$SMOKE_EXPECT_XRAY_VERSION" ]; then
    expected_setenv+=" HTTP_PROXY=http://127.0.0.1:10809 HTTPS_PROXY=http://127.0.0.1:10809 NO_PROXY=localhost,127.0.0.1,::1 http_proxy=http://127.0.0.1:10809 https_proxy=http://127.0.0.1:10809 no_proxy=localhost,127.0.0.1,::1"
    expected_tokens+=(
      "HTTP_PROXY=http://127.0.0.1:10809"
      "HTTPS_PROXY=http://127.0.0.1:10809"
      "NO_PROXY=localhost,127.0.0.1,::1"
      "http_proxy=http://127.0.0.1:10809"
      "https_proxy=http://127.0.0.1:10809"
      "no_proxy=localhost,127.0.0.1,::1"
    )
  fi
  test "$(grep -E "^SetEnv[[:space:]]+" "$runtime_config")" = "$expected_setenv"

  effective="$(/usr/sbin/sshd -T -f "$runtime_config")"
  test "$(grep -c "^setenv " <<< "$effective")" -eq "${#expected_tokens[@]}"
  for expected_token in "${expected_tokens[@]}"; do
    grep -Fqx "setenv $expected_token" <<< "$effective"
  done

  if [ -n "$SMOKE_EXPECT_XRAY_VERSION" ]; then
    test "$(stat -c %U:%G /usr/local/bin/xray)" = root:root
    test "$(stat -c %a /usr/local/bin/xray)" = 755
    test "$(stat -c %a /usr/local/share/xray)" = 755
    gosu xray:xray test -r /usr/local/share/xray/geoip.dat
    gosu xray:xray test -r /usr/local/share/xray/geosite.dat
    test "$(stat -c %U:%G /run/xray/config.json)" = root:xray
    test "$(stat -c %a /run/xray/config.json)" = 640
    test "$(/usr/local/bin/validate-xray-config.sh /run/xray/config.json)" = cn-direct
    jq -e "
      [.outbounds[].tag] == [\"proxy\", \"direct\", \"block\"] and
      .routing.domainStrategy == \"IPOnDemand\" and
      .routing.rules == [
        {\"type\":\"field\",\"ip\":[\"geoip:private\"],\"outboundTag\":\"block\"},
        {\"type\":\"field\",\"domain\":[\"geosite:cn\"],\"outboundTag\":\"direct\"},
        {\"type\":\"field\",\"ip\":[\"geoip:cn\"],\"outboundTag\":\"direct\"}
      ]
    " /run/xray/config.json >/dev/null
    test "$(ps -o user= -C xray | awk "NF {print \$1; exit}")" = xray
    test "$(xray version | awk "NR == 1 {print \$2}")" = "$SMOKE_EXPECT_XRAY_VERSION"
    nc -z 127.0.0.1 10809
    listeners="$(ss -H -lnt "sport = :10809")"
    test -n "$listeners"
    grep -Fq "127.0.0.1:10809" <<< "$listeners"
    ! grep -Fq "0.0.0.0:10809" <<< "$listeners"
    ! grep -Fq "[::]:10809" <<< "$listeners"
    test "$HTTP_PROXY" = http://127.0.0.1:10809
    test "$HTTPS_PROXY" = http://127.0.0.1:10809
    test "$NO_PROXY" = localhost,127.0.0.1,::1
    test -z "${ALL_PROXY:-}${all_proxy:-}"
  fi

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
if [ -n "$EXPECTED_CLAUDE_VERSION" ]; then
  ssh_run "test -f '$REMOTE_HOME/.claude/remote-smoke-persist'"
fi

if [ -n "$EXPECTED_XRAY_VERSION" ]; then
  docker exec "$CONTAINER_NAME" pkill -TERM -x xray
  for _attempt in $(seq 1 30); do
    if [ "$(docker inspect "$CONTAINER_NAME" --format '{{.State.Running}}')" = false ]; then
      break
    fi
    sleep 1
  done
  if [ "$(docker inspect "$CONTAINER_NAME" --format '{{.State.Running}}')" != false ]; then
    docker logs "$CONTAINER_NAME" >&2 || true
    echo "终止Xray后personal-remote容器没有fail closed退出。" >&2
    exit 1
  fi
fi

if [ -n "$BASE_IMAGE" ]; then
  docker rm -f "$CONTAINER_NAME" >/dev/null
  docker run --rm --platform "$PLATFORM" \
    --volume "$HOME_VOLUME:$REMOTE_HOME" \
    "$BASE_IMAGE" true
fi

if [ -n "$EXPECTED_XRAY_VERSION" ]; then
  echo "remote SSH smoke通过：$REMOTE_IMAGE ($PLATFORM, Codex $actual_version, Claude Code $actual_claude_version, Xray $actual_xray_version, mise $actual_mise_version, proxy on/off)"
elif [ -n "$EXPECTED_CLAUDE_VERSION" ]; then
  echo "remote SSH smoke通过：$REMOTE_IMAGE ($PLATFORM, Codex $actual_version, Claude Code $actual_claude_version, mise $actual_mise_version)"
else
  echo "remote SSH smoke通过：$REMOTE_IMAGE ($PLATFORM, Codex $actual_version, mise $actual_mise_version)"
fi
