#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100&page=1"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
RUN_STATIC=true
RUN_RELEASE=true
EVIDENCE_DIR="${AUDIT_EVIDENCE_DIR:-}"
TEMP_DIR=""

usage() {
  cat <<'USAGE'
用法：audit-xray-private-supply-chain.sh [--resolve-only|--static-only] [--evidence-dir DIR]

默认执行Xray私有派生链静态检查，并从XTLS/Xray-core releases API解析最新非draft release。
解析包含官方标记为prerelease的版本；构建始终使用本次解析出的精确tag、asset digest和size。
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve-only)
      RUN_STATIC=false
      RUN_RELEASE=true
      ;;
    --static-only)
      RUN_STATIC=true
      RUN_RELEASE=false
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

check_static_contract() {
  local private_dockerfile="${REPO_ROOT}/private/Dockerfile"
  local personal_workflow="${REPO_ROOT}/.github/workflows/docker-personal.yml"
  local validator="${REPO_ROOT}/scripts/validate-xray-config.sh"
  local file

  for file in "$private_dockerfile" "$personal_workflow" "$validator"; do
    if [ ! -f "$file" ]; then
      echo "缺少文件：$file" >&2
      exit 1
    fi
  done

  for required in \
    'ARG XRAY_TAG' \
    'ARG XRAY_VERSION' \
    'ARG XRAY_SHA256_AMD64' \
    'ARG XRAY_SHA256_ARM64' \
    'ARG XRAY_SIZE_AMD64' \
    'ARG XRAY_SIZE_ARM64' \
    "https://github.com/XTLS/Xray-core/releases/download/\${XRAY_TAG}/" \
    'XRAY_PROXY_ENABLED=false' \
    'COPY --chmod=0755 scripts/validate-xray-config.sh /usr/local/bin/validate-xray-config.sh' \
    'ENTRYPOINT ["/usr/local/bin/personal-remote-entrypoint.sh"]' \
    'io.codex-dev.xray.signed="false"'; do
    if ! grep -Fq "$required" "$private_dockerfile"; then
      echo "private/Dockerfile缺少Xray精确构建契约：$required" >&2
      exit 1
    fi
  done

  if grep -Eiq 'xray-install|install-release\.sh|releases/latest/download|xray-core:latest' "$private_dockerfile"; then
    echo "private/Dockerfile不得使用Xray安装脚本或浮动latest输入。" >&2
    exit 1
  fi

  if ! grep -Fq 'audit-xray-private-supply-chain.sh --resolve-only' "$personal_workflow"; then
    echo "personal workflow没有调用Xray latest解析与证据脚本。" >&2
    exit 1
  fi

  for required in \
    'all-proxy' \
    'cn-direct' \
    '["proxy", "direct", "block"]' \
    '"geoip:private"' \
    '"geosite:cn"' \
    '"geoip:cn"' \
    '"IPOnDemand"' \
    '"finalRules"'; do
    if ! grep -Fq "$required" "$validator"; then
      echo "Xray配置验证器缺少中国直连安全契约：$required" >&2
      exit 1
    fi
  done

  for file in \
    "${REPO_ROOT}/base/Dockerfile" \
    "${REPO_ROOT}/compose.yaml" \
    "${REPO_ROOT}/compose.remote.yaml" \
    "${REPO_ROOT}/templates/portainer-stack.yaml"; do
    if [ -f "$file" ] && grep -Eiq '(^|[^[:alnum:]_])(xray|XRAY_PROXY_ENABLED)([^[:alnum:]_]|$)' "$file"; then
      echo "公开镜像或默认运行配置不得安装或启用Xray：${file#"${REPO_ROOT}"/}" >&2
      exit 1
    fi
  done

  report_ok "Xray只进入private remote派生链，公开镜像与默认配置保持不变"
}

asset_field() {
  local release_file="$1"
  local asset_name="$2"
  local field="$3"

  jq -r --arg name "$asset_name" --arg field "$field" '
    [.assets[] | select(.name == $name)] as $matches |
    if ($matches | length) == 1 then ($matches[0][$field] // empty) else empty end
  ' "$release_file"
}

resolve_latest_xray() {
  local releases_file="${TEMP_DIR}/releases.json"
  local release_file="${EVIDENCE_DIR}/release.json"
  local tag version published_at prerelease release_count latest_count github_token
  local arch asset_name digest_file_name digest size url digest_url sha256
  local -a api_headers

  for command_name in curl jq grep; do
    require_command "$command_name"
  done

  api_headers=(
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
  )
  github_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -n "$github_token" ]; then
    api_headers+=(-H "Authorization: Bearer $github_token")
  fi

  curl --fail --location --silent --show-error --retry 3 \
    --proto '=https' --tlsv1.2 \
    "${api_headers[@]}" \
    "$XRAY_RELEASES_API" --output "$releases_file"
  if ! jq -e 'type == "array" and length > 0' "$releases_file" >/dev/null; then
    echo "Xray releases API没有返回有效数组。" >&2
    exit 1
  fi

  release_count="$(jq '[.[] | select(.draft == false and (.published_at | type == "string"))] | length' "$releases_file")"
  if [ "$release_count" -lt 1 ]; then
    echo "Xray releases API中没有可用的非draft release。" >&2
    exit 1
  fi

  jq '[.[] | select(.draft == false and (.published_at | type == "string"))] | max_by(.published_at)' \
    "$releases_file" > "$release_file"

  tag="$(jq -r '.tag_name // empty' "$release_file")"
  published_at="$(jq -r '.published_at // empty' "$release_file")"
  prerelease="$(jq -r '.prerelease // empty' "$release_file")"
  version="${tag#v}"

  if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Xray最新release tag格式无效：${tag:-<空>}" >&2
    exit 1
  fi
  if ! [[ "$published_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "Xray最新release published_at格式无效：${published_at:-<空>}" >&2
    exit 1
  fi
  latest_count="$(jq --arg published_at "$published_at" '[.[] | select(.draft == false and .published_at == $published_at)] | length' "$releases_file")"
  if [ "$latest_count" -ne 1 ]; then
    echo "Xray releases API中最新published_at不唯一：$published_at count=$latest_count" >&2
    exit 1
  fi
  if [ "$prerelease" != true ] && [ "$prerelease" != false ]; then
    echo "Xray最新release prerelease字段无效：${prerelease:-<空>}" >&2
    exit 1
  fi

  emit_output tag "$tag"
  emit_output version "$version"
  emit_output published_at "$published_at"
  emit_output prerelease "$prerelease"

  for arch in amd64 arm64; do
    case "$arch" in
      amd64) asset_name='Xray-linux-64.zip' ;;
      arm64) asset_name='Xray-linux-arm64-v8a.zip' ;;
    esac
    digest_file_name="${asset_name}.dgst"

    digest="$(asset_field "$release_file" "$asset_name" digest)"
    size="$(asset_field "$release_file" "$asset_name" size)"
    url="$(asset_field "$release_file" "$asset_name" browser_download_url)"
    digest_url="$(asset_field "$release_file" "$digest_file_name" browser_download_url)"

    if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "Xray $arch asset digest无效：${digest:-<空>}" >&2
      exit 1
    fi
    if ! [[ "$size" =~ ^[1-9][0-9]*$ ]]; then
      echo "Xray $arch asset size无效：${size:-<空>}" >&2
      exit 1
    fi
    if [ "$url" != "https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset_name}" ]; then
      echo "Xray $arch asset URL不是exact tag官方地址：${url:-<空>}" >&2
      exit 1
    fi
    if [ "$digest_url" != "https://github.com/XTLS/Xray-core/releases/download/${tag}/${digest_file_name}" ]; then
      echo "Xray $arch digest URL不是exact tag官方地址：${digest_url:-<空>}" >&2
      exit 1
    fi

    sha256="${digest#sha256:}"
    fetch_file "$digest_url" "${TEMP_DIR}/${digest_file_name}"
    if [ "$(grep -Fxc "SHA2-256= ${sha256}" "${TEMP_DIR}/${digest_file_name}" || true)" -ne 1 ]; then
      echo "Xray $arch .dgst没有唯一匹配GitHub asset SHA-256。" >&2
      exit 1
    fi

    emit_output "sha256_${arch}" "$sha256"
    emit_output "size_${arch}" "$size"
    emit_output "url_${arch}" "$url"
  done

  {
    echo
    echo "### Xray release evidence"
    echo "- Tag: \`$tag\`"
    echo "- Version: \`$version\`"
    echo "- Published: \`$published_at\`"
    echo "- Prerelease: \`$prerelease\`"
    echo "- Trust: GitHub release asset digest/size + exact asset本地校验；.dgst不是签名"
  } | tee -a "$EVIDENCE_SUMMARY" >> "$SUMMARY_FILE"

  report_ok "Xray最新非draft release已解析为exact tag并验证双架构asset元数据"
}

printf '### Xray private supply-chain audit\n' >> "$SUMMARY_FILE"
printf '### Xray private supply-chain audit\n' >> "$EVIDENCE_SUMMARY"

if [ "$RUN_STATIC" = true ]; then
  check_static_contract
fi

if [ "$RUN_RELEASE" = true ]; then
  resolve_latest_xray
fi

report_ok "Xray私有供应链审计完成"
