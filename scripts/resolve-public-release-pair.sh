#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE="${1:-${PUBLIC_BASE_IMAGE:-ghcr.io/wekingchen/codex-dev-base:latest}}"
REMOTE_IMAGE="${2:-${PUBLIC_REMOTE_IMAGE:-ghcr.io/wekingchen/codex-dev-remote:latest}}"
EXPECTED_SOURCE="${EXPECTED_PUBLIC_IMAGE_SOURCE:-https://github.com/wekingchen/codex-dev-docker}"
TEMP_DIR="$(mktemp -d)"

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

require_command docker
require_command jq

resolve_root_digest() {
  local image_ref="$1"
  local digest

  digest="$(docker buildx imagetools inspect "$image_ref" --format '{{.Manifest.Digest}}')"
  if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "无法解析根 digest：$image_ref -> ${digest:-<空>}" >&2
    exit 1
  fi

  printf '%s\n' "$digest"
}

without_digest() {
  printf '%s\n' "${1%@*}"
}

inspect_platform_labels() {
  local image_name="$1"
  local manifest_digest="$2"
  local output_file="$3"

  docker buildx imagetools inspect \
    "${image_name}@${manifest_digest}" \
    --format '{{json .Image.Config.Labels}}' > "$output_file"

  if ! jq -e 'type == "object"' "$output_file" >/dev/null; then
    echo "平台镜像缺少 config labels：${image_name}@${manifest_digest}" >&2
    exit 1
  fi
}

require_single_platform() {
  local index_file="$1"
  local arch="$2"
  local count

  count="$(jq --arg arch "$arch" '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch)] | length' "$index_file")"
  if [ "$count" -ne 1 ]; then
    echo "根索引必须恰好包含一个 linux/${arch} 运行 manifest，实际为 ${count}：$index_file" >&2
    exit 1
  fi
}

platform_digest() {
  local index_file="$1"
  local arch="$2"

  jq -r --arg arch "$arch" '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest' "$index_file"
}

label_value() {
  local labels_file="$1"
  local key="$2"

  jq -r --arg key "$key" '.[$key] // empty' "$labels_file"
}

require_label() {
  local labels_file="$1"
  local key="$2"
  local value

  value="$(label_value "$labels_file" "$key")"
  if [ -z "$value" ]; then
    echo "镜像缺少 label ${key}：$labels_file" >&2
    exit 1
  fi

  printf '%s\n' "$value"
}

verify_attestations() {
  local exact_ref="$1"
  local prefix="$2"

  docker buildx imagetools inspect "$exact_ref" --format '{{json .Provenance}}' > "${TEMP_DIR}/${prefix}-provenance.json"
  docker buildx imagetools inspect "$exact_ref" --format '{{json .SBOM}}' > "${TEMP_DIR}/${prefix}-sbom.json"

  jq -e '. != null and . != {} and . != []' "${TEMP_DIR}/${prefix}-provenance.json" >/dev/null
  jq -e '. != null and . != {} and . != []' "${TEMP_DIR}/${prefix}-sbom.json" >/dev/null
}

emit_output() {
  local key="$1"
  local value="$2"

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$key" "$value"
}

base_name="$(without_digest "$BASE_IMAGE")"
remote_name="$(without_digest "$REMOTE_IMAGE")"
base_digest="$(resolve_root_digest "$BASE_IMAGE")"
remote_digest="$(resolve_root_digest "$REMOTE_IMAGE")"
base_ref="${base_name}@${base_digest}"
remote_ref="${remote_name}@${remote_digest}"

base_index="${TEMP_DIR}/base-index.json"
remote_index="${TEMP_DIR}/remote-index.json"
docker buildx imagetools inspect --raw "$base_ref" > "$base_index"
docker buildx imagetools inspect --raw "$remote_ref" > "$remote_index"

for index_file in "$base_index" "$remote_index"; do
  jq -e '.mediaType == "application/vnd.oci.image.index.v1+json" or .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"' "$index_file" >/dev/null
  require_single_platform "$index_file" amd64
  require_single_platform "$index_file" arm64
  jq -e '[.manifests[] | select(
    (.platform.os == "linux" and (.platform.architecture == "amd64" or .platform.architecture == "arm64")) or
    (.platform.os == "unknown" and .platform.architecture == "unknown")
  )] | length == (.manifests | length)' "$index_file" >/dev/null
  jq -e '[.manifests[] | select(.platform.os == "linux")] | length == 2' "$index_file" >/dev/null
done

base_amd64_digest="$(platform_digest "$base_index" amd64)"
base_arm64_digest="$(platform_digest "$base_index" arm64)"
remote_amd64_digest="$(platform_digest "$remote_index" amd64)"
remote_arm64_digest="$(platform_digest "$remote_index" arm64)"

inspect_platform_labels "$base_name" "$base_amd64_digest" "${TEMP_DIR}/base-amd64-labels.json"
inspect_platform_labels "$base_name" "$base_arm64_digest" "${TEMP_DIR}/base-arm64-labels.json"
inspect_platform_labels "$remote_name" "$remote_amd64_digest" "${TEMP_DIR}/remote-amd64-labels.json"
inspect_platform_labels "$remote_name" "$remote_arm64_digest" "${TEMP_DIR}/remote-arm64-labels.json"

label_files=(
  "${TEMP_DIR}/base-amd64-labels.json"
  "${TEMP_DIR}/base-arm64-labels.json"
  "${TEMP_DIR}/remote-amd64-labels.json"
  "${TEMP_DIR}/remote-arm64-labels.json"
)

for labels_file in "${label_files[@]}"; do
  require_label "$labels_file" org.opencontainers.image.source >/dev/null
  require_label "$labels_file" org.opencontainers.image.revision >/dev/null
  require_label "$labels_file" io.codex-dev.release-set >/dev/null
  require_label "$labels_file" io.codex-dev.codex.release-id >/dev/null
  require_label "$labels_file" io.codex-dev.codex.release-tag >/dev/null
  require_label "$labels_file" io.codex-dev.codex.version >/dev/null
done

for labels_file in "${TEMP_DIR}/base-amd64-labels.json" "${TEMP_DIR}/base-arm64-labels.json"; do
  if [ "$(require_label "$labels_file" io.codex-dev.image.role)" != base ]; then
    echo "公开 base 平台镜像 role 不正确：$labels_file" >&2
    exit 1
  fi
done

for labels_file in "${TEMP_DIR}/remote-amd64-labels.json" "${TEMP_DIR}/remote-arm64-labels.json"; do
  if [ "$(require_label "$labels_file" io.codex-dev.image.role)" != remote ]; then
    echo "公开 remote 平台镜像 role 不正确：$labels_file" >&2
    exit 1
  fi
done

reference_labels="${TEMP_DIR}/base-amd64-labels.json"
release_set="$(require_label "$reference_labels" io.codex-dev.release-set)"
revision="$(require_label "$reference_labels" org.opencontainers.image.revision)"
codex_release_id="$(require_label "$reference_labels" io.codex-dev.codex.release-id)"
codex_release_tag="$(require_label "$reference_labels" io.codex-dev.codex.release-tag)"
codex_version="$(require_label "$reference_labels" io.codex-dev.codex.version)"

for labels_file in "${label_files[@]}"; do
  source="$(require_label "$labels_file" org.opencontainers.image.source)"
  if [ "$source" != "$EXPECTED_SOURCE" ]; then
    echo "公开父镜像 source 不匹配：期望 $EXPECTED_SOURCE，实际 $source" >&2
    exit 1
  fi

  for key in \
    org.opencontainers.image.revision \
    io.codex-dev.release-set \
    io.codex-dev.codex.release-id \
    io.codex-dev.codex.release-tag \
    io.codex-dev.codex.version; do
    expected="$(label_value "$reference_labels" "$key")"
    actual="$(label_value "$labels_file" "$key")"
    if [ "$actual" != "$expected" ]; then
      echo "公开父镜像配对失败：${key} 期望 ${expected}，实际 ${actual}（${labels_file}）" >&2
      exit 1
    fi
  done
done

verify_attestations "$base_ref" base
verify_attestations "$remote_ref" remote

emit_output base_image "$base_name"
emit_output base_digest "$base_digest"
emit_output base_ref "$base_ref"
emit_output remote_image "$remote_name"
emit_output remote_digest "$remote_digest"
emit_output remote_ref "$remote_ref"
emit_output release_set "$release_set"
emit_output revision "$revision"
emit_output codex_release_id "$codex_release_id"
emit_output codex_release_tag "$codex_release_tag"
emit_output codex_version "$codex_version"
