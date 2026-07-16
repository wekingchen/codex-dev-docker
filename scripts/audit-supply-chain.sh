#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
FAILURES=0

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '缺少命令：%s\n' "$1" >&2
    exit 1
  fi
}

for command_name in curl git grep jq; do
  require_command "$command_name"
done

report_ok() {
  printf 'OK: %s\n' "$1"
  printf -- '- ✅ %s\n' "$1" >> "$SUMMARY_FILE"
}

report_error() {
  printf 'ERROR: %s\n' "$1" >&2
  printf -- '- ❌ %s\n' "$1" >> "$SUMMARY_FILE"
  FAILURES=$((FAILURES + 1))
}

github_api() {
  local url="$1"
  local curl_args=(--fail --silent --show-error --retry 3 \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28")

  if [ -n "${GH_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi

  curl "${curl_args[@]}" "$url"
}

resolve_action_tag() {
  local repository="$1"
  local version="$2"
  local sha

  sha="$(git ls-remote "https://github.com/${repository}.git" "refs/tags/${version}^{}" | cut -f1)"
  if [ -z "$sha" ]; then
    sha="$(git ls-remote "https://github.com/${repository}.git" "refs/tags/${version}" | cut -f1)"
  fi
  printf '%s\n' "$sha"
}

printf '### Supply-chain audit\n' >> "$SUMMARY_FILE"

# 所有外部 Actions 必须使用完整 SHA，并以同行注释声明对应版本。
while IFS= read -r match; do
  file_and_line="${match%%:*}:${match#*:}"
  file="${match%%:*}"
  remainder="${match#*:}"
  line_number="${remainder%%:*}"
  line="${remainder#*:}"
  value="${line#*uses: }"

  if [ "$value" = "$line" ]; then
    report_error "$file_and_line 无法解析 uses"
    continue
  fi

  action_ref="${value%% #*}"
  if [ "$action_ref" = "$value" ]; then
    report_error "$file:$line_number 的 Action 缺少精确版本注释"
    continue
  fi

  version="${value##*# }"
  action_path="${action_ref%@*}"
  pinned_sha="${action_ref##*@}"
  owner="${action_path%%/*}"
  repository_and_path="${action_path#*/}"
  repository_name="${repository_and_path%%/*}"
  repository="${owner}/${repository_name}"

  if ! [[ "$pinned_sha" =~ ^[0-9a-f]{40}$ ]]; then
    report_error "$file:$line_number 未使用 40 位 Action SHA：$action_ref"
    continue
  fi

  if ! [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
    report_error "$file:$line_number 的版本注释格式无效：$version"
    continue
  fi

  resolved_sha="$(resolve_action_tag "$repository" "$version")"
  if [ -z "$resolved_sha" ]; then
    report_error "$file:$line_number 无法从官方仓库解析 $repository $version"
  elif [ "$resolved_sha" != "$pinned_sha" ]; then
    report_error "${file}:${line_number} 的 ${version} 应为 ${resolved_sha}，当前为 ${pinned_sha}"
  else
    report_ok "$repository $version 固定到 $pinned_sha"
  fi
done < <(grep -RInE '^[[:space:]]*uses:[[:space:]]+[^./][^[:space:]]*@' "$REPO_ROOT/.github/workflows" | sort)

# Ubuntu 必须固定当前 tag 的多架构根 index，并包含 amd64/arm64。
from_line="$(grep -E '^FROM ubuntu:[^@]+@sha256:[0-9a-f]{64}([[:space:]]+AS[[:space:]]+[A-Za-z0-9._-]+)?$' "$REPO_ROOT/base/Dockerfile" || true)"
if [ -z "$from_line" ]; then
  report_error "Dockerfile 未使用 ubuntu tag + 64 位根 digest"
else
  ubuntu_ref="${from_line#FROM ubuntu:}"
  ubuntu_ref="${ubuntu_ref%% AS *}"
  ubuntu_tag="${ubuntu_ref%@sha256:*}"
  pinned_ubuntu_digest="sha256:${ubuntu_ref##*@sha256:}"
  ubuntu_response="$(curl --fail --silent --show-error --retry 3 \
    "https://hub.docker.com/v2/repositories/library/ubuntu/tags/${ubuntu_tag}")"
  current_ubuntu_digest="$(jq -r '.digest // empty' <<< "$ubuntu_response")"
  ubuntu_media_type="$(jq -r '.media_type // empty' <<< "$ubuntu_response")"
  has_amd64="$(jq '[.images[] | select(.os == "linux" and .architecture == "amd64")] | length' <<< "$ubuntu_response")"
  has_arm64="$(jq '[.images[] | select(.os == "linux" and .architecture == "arm64")] | length' <<< "$ubuntu_response")"

  if [ "$current_ubuntu_digest" != "$pinned_ubuntu_digest" ]; then
    report_error "ubuntu:${ubuntu_tag} 根 digest 已漂移：当前 ${current_ubuntu_digest}，仓库 ${pinned_ubuntu_digest}"
  elif [ "$ubuntu_media_type" != "application/vnd.oci.image.index.v1+json" ] \
    && [ "$ubuntu_media_type" != "application/vnd.docker.distribution.manifest.list.v2+json" ]; then
    report_error "ubuntu:${ubuntu_tag} 不是多架构根 index：$ubuntu_media_type"
  elif [ "$has_amd64" -lt 1 ] || [ "$has_arm64" -lt 1 ]; then
    report_error "ubuntu:${ubuntu_tag} 根 index 缺少 amd64 或 arm64"
  else
    report_ok "ubuntu:${ubuntu_tag} 根 index $pinned_ubuntu_digest 包含 amd64/arm64"
  fi
fi

# mise 版本和两个架构 asset digest必须与官方 latest稳定release一致。
mise_version="$(grep -E '^ARG MISE_VERSION=v' "$REPO_ROOT/base/Dockerfile" | cut -d= -f2 || true)"
mise_sha_amd64="$(grep -E '^ARG MISE_SHA256_AMD64=[0-9a-f]{64}$' "$REPO_ROOT/base/Dockerfile" | cut -d= -f2 || true)"
mise_sha_arm64="$(grep -E '^ARG MISE_SHA256_ARM64=[0-9a-f]{64}$' "$REPO_ROOT/base/Dockerfile" | cut -d= -f2 || true)"
mise_release="$(github_api https://api.github.com/repos/jdx/mise/releases/latest)"
latest_mise_version="$(jq -r '.tag_name // empty' <<< "$mise_release")"
latest_mise_sha_amd64="$(jq -r --arg name "mise-${mise_version}-linux-x64" '.assets[] | select(.name == $name) | .digest // empty' <<< "$mise_release")"
latest_mise_sha_arm64="$(jq -r --arg name "mise-${mise_version}-linux-arm64" '.assets[] | select(.name == $name) | .digest // empty' <<< "$mise_release")"
latest_mise_sha_amd64="${latest_mise_sha_amd64#sha256:}"
latest_mise_sha_arm64="${latest_mise_sha_arm64#sha256:}"

if [ -z "$mise_version" ] || [ -z "$mise_sha_amd64" ] || [ -z "$mise_sha_arm64" ]; then
  report_error "Dockerfile 中 mise 版本或双架构 SHA-256 缺失"
elif [ "$mise_version" != "$latest_mise_version" ]; then
  report_error "mise 已有新稳定版本：官方 ${latest_mise_version}，仓库 ${mise_version}"
elif [ "$mise_sha_amd64" != "$latest_mise_sha_amd64" ]; then
  report_error "mise ${mise_version} amd64 SHA不匹配：官方 ${latest_mise_sha_amd64}，仓库 ${mise_sha_amd64}"
elif [ "$mise_sha_arm64" != "$latest_mise_sha_arm64" ]; then
  report_error "mise ${mise_version} arm64 SHA不匹配：官方 ${latest_mise_sha_arm64}，仓库 ${mise_sha_arm64}"
else
  report_ok "mise $mise_version 双架构 asset SHA-256 与官方 release一致"
fi

# Trivy binary固定版本应跟随官方最新稳定release；Action pin由通用检查覆盖。
trivy_version="$(grep -E '^[[:space:]]+TRIVY_VERSION:' "$REPO_ROOT/.github/workflows/docker.yml" | sed -E 's/.*"(v[^"]+)".*/\1/' || true)"
trivy_release="$(github_api https://api.github.com/repos/aquasecurity/trivy/releases/latest)"
latest_trivy_version="$(jq -r '.tag_name // empty' <<< "$trivy_release")"
if [ -z "$trivy_version" ]; then
  report_error "docker workflow 未固定 TRIVY_VERSION"
elif [ "$trivy_version" != "$latest_trivy_version" ]; then
  report_error "Trivy 已有新稳定版本：官方 ${latest_trivy_version}，仓库 ${trivy_version}"
else
  report_ok "Trivy binary固定为官方最新稳定版本 $trivy_version"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '供应链审计失败：发现 %s 个问题。\n' "$FAILURES" >&2
  exit 1
fi

printf '供应链审计通过。\n'
