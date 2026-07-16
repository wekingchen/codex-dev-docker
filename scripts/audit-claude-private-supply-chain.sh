#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLAUDE_RELEASE_ROOT="https://downloads.claude.ai/claude-code-releases"
CLAUDE_KEY_URL="https://downloads.claude.ai/keys/claude-code.asc"
EXPECTED_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
MIN_SIGNED_VERSION="2.1.89"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
RUN_STATIC=true
RUN_RELEASE=true
RUN_VISIBILITY=true
EVIDENCE_DIR="${AUDIT_EVIDENCE_DIR:-}"
TEMP_DIR=""

usage() {
  cat <<'USAGE'
用法：audit-claude-private-supply-chain.sh [--resolve-only|--static-only] [--evidence-dir DIR]

默认执行私有派生链的本地静态检查、Claude latest签名审计，以及可选GHCR私有可见性检查。
未设置GHCR_PRIVATE_GUARD_TOKEN时，仅跳过可见性检查，不影响本地运行。
设置token时可通过GHCR_PRIVATE_OWNER固定目标owner；CI会将其设为repository owner。
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve-only)
      RUN_STATIC=false
      RUN_RELEASE=true
      RUN_VISIBILITY=false
      ;;
    --static-only)
      RUN_STATIC=true
      RUN_RELEASE=false
      RUN_VISIBILITY=false
      ;;
    --evidence-dir)
      if [ "$#" -lt 2 ]; then
        echo "--evidence-dir需要目录参数。" >&2
        exit 2
      fi
      EVIDENCE_DIR="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

TEMP_DIR="$(mktemp -d)"
if [ -z "$EVIDENCE_DIR" ]; then
  EVIDENCE_DIR="${TEMP_DIR}/evidence"
fi
mkdir -p "$EVIDENCE_DIR"
EVIDENCE_SUMMARY="${EVIDENCE_DIR}/summary.md"
: > "$EVIDENCE_SUMMARY"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令：$1" >&2
    exit 1
  fi
}

report_ok() {
  printf 'OK: %s\n' "$1"
  printf -- '- OK: %s\n' "$1" >> "$EVIDENCE_SUMMARY"
  printf -- '- OK: %s\n' "$1" >> "$SUMMARY_FILE"
}

report_info() {
  printf 'INFO: %s\n' "$1"
  printf -- '- INFO: %s\n' "$1" >> "$EVIDENCE_SUMMARY"
  printf -- '- INFO: %s\n' "$1" >> "$SUMMARY_FILE"
}

sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    echo "缺少SHA-256工具：需要sha256sum或shasum。" >&2
    exit 1
  fi
}

version_at_least() {
  local actual="$1"
  local minimum="$2"
  local actual_major actual_minor actual_patch
  local minimum_major minimum_minor minimum_patch

  IFS=. read -r actual_major actual_minor actual_patch <<< "$actual"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<< "$minimum"

  if [ "$actual_major" -ne "$minimum_major" ]; then
    [ "$actual_major" -gt "$minimum_major" ]
  elif [ "$actual_minor" -ne "$minimum_minor" ]; then
    [ "$actual_minor" -gt "$minimum_minor" ]
  else
    [ "$actual_patch" -ge "$minimum_patch" ]
  fi
}

emit_output() {
  local key="$1"
  local value="$2"

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$key" "$value"
}

fetch_file() {
  local url="$1"
  local output="$2"

  curl --fail --location --silent --show-error --retry 3 \
    --proto '=https' --tlsv1.2 \
    "$url" --output "$output"
}

check_private_dockerfile() {
  local normalized="${TEMP_DIR}/private-dockerfile.instructions"
  local source_reset_count personal_workflow

  if [ ! -f "${REPO_ROOT}/private/Dockerfile" ]; then
    echo "缺少private/Dockerfile。" >&2
    exit 1
  fi

  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      buffer = buffer line " "
      if (line !~ /\\[[:space:]]*$/) {
        print buffer
        buffer = ""
      }
    }
    END { if (buffer != "") print buffer }
  ' "${REPO_ROOT}/private/Dockerfile" > "$normalized"

  if grep -Eiq '^(RUN|CMD|ENTRYPOINT)[[:space:]].*bootstrap([^[:alnum:]_]|$)' "$normalized"; then
    echo "private/Dockerfile不得执行bootstrap安装器。" >&2
    exit 1
  fi

  if grep -Eiq '^(RUN|CMD|ENTRYPOINT)[[:space:]].*curl[^|]*\|[[:space:]]*(ba)?sh([^[:alnum:]_]|$)' "$normalized"; then
    echo "private/Dockerfile不得使用curl管道执行shell。" >&2
    exit 1
  fi

  source_reset_count="$(grep -Ec 'org\.opencontainers\.image\.source=""' "$normalized" || true)"
  if [ "$source_reset_count" -ne 2 ]; then
    echo "两个private target都必须清空继承的org.opencontainers.image.source，避免自动关联公开repository。" >&2
    exit 1
  fi

  personal_workflow="${REPO_ROOT}/.github/workflows/docker-personal.yml"
  if grep -Fq 'secrets.GITHUB_TOKEN' "$personal_workflow"; then
    echo "private workflow不得使用公开仓库GITHUB_TOKEN发布或拉取personal package。" >&2
    exit 1
  fi
  if grep -Fq 'org.opencontainers.image.source=https://github.com/' "$personal_workflow"; then
    echo "private workflow不得设置会自动关联公开repository的OCI source label。" >&2
    exit 1
  fi

  report_ok "private Dockerfile与workflow不执行浮动安装，也不关联公开repository"
}

check_visibility_probe() {
  local probe_file="${REPO_ROOT}/private/visibility-probe.Dockerfile"
  local normalized="${TEMP_DIR}/visibility-probe.instructions"
  local from_count

  if [ ! -f "$probe_file" ]; then
    echo "缺少private/visibility-probe.Dockerfile。" >&2
    exit 1
  fi

  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      buffer = buffer line " "
      if (line !~ /\\[[:space:]]*$/) {
        print buffer
        buffer = ""
      }
    }
    END { if (buffer != "") print buffer }
  ' "$probe_file" > "$normalized"

  from_count="$(grep -Eic '^FROM[[:space:]]+' "$normalized" || true)"
  if [ "$from_count" -ne 1 ] || ! grep -Eiq '^FROM[[:space:]]+scratch[[:space:]]*$' "$normalized"; then
    echo "visibility probe必须只以FROM scratch为基础。" >&2
    exit 1
  fi

  if ! awk '
    {
      instruction = toupper($1)
      if (instruction != "FROM" && instruction != "LABEL" && instruction != "CMD") {
        exit 1
      }
    }
  ' "$normalized"; then
    echo "visibility probe只允许FROM、LABEL和CMD，不得包含任何文件层或执行步骤。" >&2
    exit 1
  fi

  if ! grep -Eq 'io\.codex-dev\.image\.flavor="visibility-probe"' "$normalized"; then
    echo "visibility probe缺少固定flavor label。" >&2
    exit 1
  fi

  report_ok "visibility probe为无文件层的scratch镜像且不包含Claude二进制"
}

check_public_defaults() {
  local file remote_sshd_config expected_setenv setenv_count
  local public_defaults=(
    ".env.example"
    "compose.yaml"
    "compose.remote.yaml"
    "templates/portainer-stack.yaml"
  )

  for file in "${public_defaults[@]}"; do
    if [ -f "${REPO_ROOT}/${file}" ] \
      && grep -Ein 'codex-dev-personal-(base|remote)|claude([[:space:]_-]*code)?' "${REPO_ROOT}/${file}"; then
      echo "公开默认运行配置不得引用私有package或Claude：$file" >&2
      exit 1
    fi
  done

  if grep -Ein 'claude([[:space:]_-]*code)?|downloads\.claude\.ai' "${REPO_ROOT}/base/Dockerfile"; then
    echo "公开base/Dockerfile不得安装或引用Claude。" >&2
    exit 1
  fi

  remote_sshd_config="${REPO_ROOT}/remote/sshd_config"
  expected_setenv='SetEnv CODEX_HOME=__DEV_HOME__/.codex MISE_DATA_DIR=__DEV_HOME__/.local/share/mise MISE_CONFIG_DIR=__DEV_HOME__/.config/mise'
  setenv_count="$(grep -Ec '^SetEnv[[:space:]]+' "$remote_sshd_config" || true)"
  if [ "$setenv_count" -ne 1 ]; then
    echo "公开remote sshd模板必须且只能包含一条SetEnv，实际${setenv_count}条。" >&2
    exit 1
  fi
  if ! grep -Fqx "$expected_setenv" "$remote_sshd_config"; then
    echo "公开remote sshd模板的唯一SetEnv未完整设置Codex与mise状态目录。" >&2
    exit 1
  fi
  if grep -Eiq 'DISABLE_AUTOUPDATER|DISABLE_UPDATES|claude([[:space:]_-]*code)?' "$remote_sshd_config"; then
    echo "公开remote sshd模板不得包含Claude或私有更新禁用变量。" >&2
    exit 1
  fi

  report_ok "公开默认配置、base/Dockerfile与remote sshd模板未引入私有package或Claude"
}

resolve_and_verify_claude() {
  local latest_file="${TEMP_DIR}/latest"
  local stable_file="${TEMP_DIR}/stable"
  local manifest_file="${TEMP_DIR}/manifest.json"
  local signature_file="${TEMP_DIR}/manifest.json.sig"
  local key_file="${TEMP_DIR}/claude-code.asc"
  local gnupg_home="${TEMP_DIR}/gnupg"
  local latest_version stable_version key_fingerprint verify_status signer_fingerprint
  local manifest_sha256 commit build_date sha256_amd64 sha256_arm64 size_amd64 size_arm64

  for command_name in curl gpg jq; do
    require_command "$command_name"
  done

  fetch_file "${CLAUDE_RELEASE_ROOT}/latest" "$latest_file"
  fetch_file "${CLAUDE_RELEASE_ROOT}/stable" "$stable_file"
  latest_version="$(tr -d '\r\n' < "$latest_file")"
  stable_version="$(tr -d '\r\n' < "$stable_file")"

  if ! [[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Claude latest格式无效：${latest_version:-<空>}" >&2
    exit 1
  fi
  if ! [[ "$stable_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Claude stable格式无效：${stable_version:-<空>}" >&2
    exit 1
  fi
  if ! version_at_least "$latest_version" "$MIN_SIGNED_VERSION"; then
    echo "Claude latest低于强制签名最低版本：$latest_version < $MIN_SIGNED_VERSION" >&2
    exit 1
  fi

  fetch_file "$CLAUDE_KEY_URL" "$key_file"
  key_fingerprint="$(gpg --batch --with-colons --import-options show-only --import "$key_file" 2>/dev/null \
    | awk -F: '$1 == "fpr" {print toupper($10); exit}')"
  if [ "$key_fingerprint" != "$EXPECTED_FINGERPRINT" ]; then
    echo "Claude release key指纹不匹配：期望$EXPECTED_FINGERPRINT，实际${key_fingerprint:-<空>}" >&2
    exit 1
  fi

  mkdir -m 0700 "$gnupg_home"
  export GNUPGHOME="$gnupg_home"
  gpg --batch --import "$key_file" >/dev/null 2>&1

  fetch_file "${CLAUDE_RELEASE_ROOT}/${latest_version}/manifest.json" "$manifest_file"
  fetch_file "${CLAUDE_RELEASE_ROOT}/${latest_version}/manifest.json.sig" "$signature_file"

  if ! verify_status="$(gpg --batch --status-fd 1 --verify "$signature_file" "$manifest_file" 2>&1)"; then
    printf '%s\n' "$verify_status" >&2
    echo "Claude manifest detached signature验证失败。" >&2
    exit 1
  fi
  signer_fingerprint="$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {print toupper($3); exit}' <<< "$verify_status")"
  if [ "$signer_fingerprint" != "$EXPECTED_FINGERPRINT" ]; then
    echo "Claude manifest签名者指纹不匹配：${signer_fingerprint:-<空>}" >&2
    exit 1
  fi

  if ! jq -e --arg version "$latest_version" '
    def platform_ok($name):
      (.platforms[$name] | type == "object") and
      (.platforms[$name].binary | type == "string" and length > 0) and
      (.platforms[$name].checksum | type == "string" and test("^[0-9a-f]{64}$")) and
      (.platforms[$name].size | type == "number" and . > 0 and floor == .);
    type == "object" and
    .version == $version and
    (.commit | type == "string" and test("^[0-9a-f]{40}$")) and
    (.buildDate | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    platform_ok("linux-x64") and
    platform_ok("linux-arm64")
  ' "$manifest_file" >/dev/null; then
    echo "Claude manifest不满足最小schema。" >&2
    exit 1
  fi

  manifest_sha256="$(sha256_file "$manifest_file")"
  commit="$(jq -r '.commit' "$manifest_file")"
  build_date="$(jq -r '.buildDate' "$manifest_file")"
  sha256_amd64="$(jq -r '.platforms["linux-x64"].checksum' "$manifest_file")"
  sha256_arm64="$(jq -r '.platforms["linux-arm64"].checksum' "$manifest_file")"
  size_amd64="$(jq -r '.platforms["linux-x64"].size' "$manifest_file")"
  size_arm64="$(jq -r '.platforms["linux-arm64"].size' "$manifest_file")"

  cp "$manifest_file" "${EVIDENCE_DIR}/manifest.json"
  cp "$signature_file" "${EVIDENCE_DIR}/manifest.json.sig"
  printf '%s\n' "$EXPECTED_FINGERPRINT" > "${EVIDENCE_DIR}/fingerprint.txt"

  emit_output version "$latest_version"
  emit_output stable_version "$stable_version"
  emit_output commit "$commit"
  emit_output build_date "$build_date"
  emit_output manifest_sha256 "$manifest_sha256"
  emit_output sha256_amd64 "$sha256_amd64"
  emit_output sha256_arm64 "$sha256_arm64"
  emit_output size_amd64 "$size_amd64"
  emit_output size_arm64 "$size_arm64"

  report_ok "Claude latest/stable版本格式有效"
  report_ok "Claude latest $latest_version manifest由固定指纹签名"
  report_ok "Claude latest manifest包含linux-x64与linux-arm64完整元数据"
  {
    echo
    echo "### Claude release evidence"
    echo "- Latest: \`$latest_version\`"
    echo "- Stable: \`$stable_version\`"
    echo "- Commit: \`$commit\`"
    echo "- Build date: \`$build_date\`"
    echo "- Manifest SHA-256: \`$manifest_sha256\`"
    echo "- Signing fingerprint: \`$EXPECTED_FINGERPRINT\`"
    echo "- linux-x64: \`$sha256_amd64\`, $size_amd64 bytes"
    echo "- linux-arm64: \`$sha256_arm64\`, $size_arm64 bytes"
  } | tee -a "$EVIDENCE_SUMMARY" >> "$SUMMARY_FILE"
}

check_private_visibility() {
  local package response visibility package_owner linked_repository guard_login expected_owner
  local token="${GHCR_PRIVATE_GUARD_TOKEN:-}"

  if [ -z "$token" ]; then
    report_info "未设置GHCR_PRIVATE_GUARD_TOKEN，跳过两个个人package的visibility检查"
    return 0
  fi

  require_command curl
  require_command jq

  expected_owner="${GHCR_PRIVATE_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
  expected_owner="$(tr '[:upper:]' '[:lower:]' <<< "$expected_owner")"
  guard_login="$(curl --fail --silent --show-error --retry 3 \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${token}" \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    'https://api.github.com/user' | jq -r '.login // empty' | tr '[:upper:]' '[:lower:]')"
  if [ -z "$guard_login" ]; then
    echo "无法读取GHCR guard token持有人。" >&2
    exit 1
  fi
  if [ -n "$expected_owner" ] && [ "$guard_login" != "$expected_owner" ]; then
    echo "GHCR guard token持有人不匹配：期望$expected_owner，实际$guard_login" >&2
    exit 1
  fi
  if [ -z "$expected_owner" ]; then
    expected_owner="$guard_login"
    report_info "未指定GHCR_PRIVATE_OWNER，按guard token持有人$guard_login执行本地visibility检查"
  fi

  for package in codex-dev-personal-base codex-dev-personal-remote; do
    response="$(curl --fail --silent --show-error --retry 3 \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer ${token}" \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "https://api.github.com/user/packages/container/${package}")"
    visibility="$(jq -r '.visibility // empty' <<< "$response")"
    package_owner="$(jq -r '.owner.login // empty' <<< "$response" | tr '[:upper:]' '[:lower:]')"
    linked_repository="$(jq -r '.repository.full_name // empty' <<< "$response")"
    if { [ -n "$package_owner" ] && [ "$package_owner" != "$expected_owner" ]; } \
      || [ "$visibility" != private ] || [ -n "$linked_repository" ]; then
      echo "GHCR package必须属于owner、visibility为private且不关联repository：$package owner=${package_owner:-<无法读取>} visibility=${visibility:-<无法读取>} repository=${linked_repository:-<无>}" >&2
      exit 1
    fi
    report_ok "GHCR package $expected_owner/$package 为private且未关联repository"
  done
  report_info "GitHub API无法完整枚举显式用户与Manage Actions access；owner必须人工保持两类ACL为空"
}

printf '### Claude private supply-chain audit\n' >> "$SUMMARY_FILE"
printf '### Claude private supply-chain audit\n' >> "$EVIDENCE_SUMMARY"

if [ "$RUN_STATIC" = true ]; then
  check_private_dockerfile
  check_visibility_probe
  check_public_defaults
fi

if [ "$RUN_RELEASE" = true ]; then
  resolve_and_verify_claude
fi

if [ "$RUN_VISIBILITY" = true ]; then
  check_private_visibility
fi

report_ok "私有Claude供应链审计完成"
