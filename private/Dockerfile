# syntax=docker/dockerfile:1.7

ARG PUBLIC_BASE_REF
ARG PUBLIC_REMOTE_REF

FROM ${PUBLIC_BASE_REF} AS claude-fetch

ARG TARGETARCH
ARG CLAUDE_VERSION
ARG CLAUDE_COMMIT
ARG CLAUDE_BUILD_DATE
ARG CLAUDE_MANIFEST_SHA256
ARG CLAUDE_SHA256_AMD64
ARG CLAUDE_SHA256_ARM64
ARG CLAUDE_SIZE_AMD64
ARG CLAUDE_SIZE_ARM64
ARG CLAUDE_RELEASE_KEY_FINGERPRINT=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE

USER root

# Claude Code Linux release 通过官方 detached signature 和平台 SHA-256 验证，
# 不执行 bootstrap.sh，也不允许安装层再次解析浮动 latest。
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) CLAUDE_PLATFORM="linux-x64"; EXPECTED_SHA256="${CLAUDE_SHA256_AMD64}"; EXPECTED_SIZE="${CLAUDE_SIZE_AMD64}" ;; \
        arm64) CLAUDE_PLATFORM="linux-arm64"; EXPECTED_SHA256="${CLAUDE_SHA256_ARM64}"; EXPECTED_SIZE="${CLAUDE_SIZE_ARM64}" ;; \
        *) echo "Unsupported TARGETARCH for Claude Code: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    test -n "${CLAUDE_VERSION}"; \
    test -n "${CLAUDE_COMMIT}"; \
    test -n "${CLAUDE_BUILD_DATE}"; \
    test -n "${CLAUDE_MANIFEST_SHA256}"; \
    test -n "${EXPECTED_SHA256}"; \
    test -n "${EXPECTED_SIZE}"; \
    RELEASE_ROOT="https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}"; \
    GNUPGHOME="$(mktemp -d)"; \
    export GNUPGHOME; \
    chmod 0700 "${GNUPGHOME}"; \
    curl --fail --location --silent --show-error --retry 3 \
        https://downloads.claude.ai/keys/claude-code.asc \
        --output /tmp/claude-code.asc; \
    ACTUAL_FINGERPRINT="$(gpg --batch --with-colons --import-options show-only --import /tmp/claude-code.asc | awk -F: '$1 == "fpr" {print $10; exit}')"; \
    test "${ACTUAL_FINGERPRINT}" = "${CLAUDE_RELEASE_KEY_FINGERPRINT}"; \
    gpg --batch --import /tmp/claude-code.asc; \
    curl --fail --location --silent --show-error --retry 3 \
        "${RELEASE_ROOT}/manifest.json" \
        --output /tmp/claude-manifest.json; \
    curl --fail --location --silent --show-error --retry 3 \
        "${RELEASE_ROOT}/manifest.json.sig" \
        --output /tmp/claude-manifest.json.sig; \
    gpg --batch --verify /tmp/claude-manifest.json.sig /tmp/claude-manifest.json; \
    printf '%s  %s\n' "${CLAUDE_MANIFEST_SHA256}" /tmp/claude-manifest.json | sha256sum --check --strict; \
    test "$(jq -r '.version // empty' /tmp/claude-manifest.json)" = "${CLAUDE_VERSION}"; \
    test "$(jq -r '.commit // empty' /tmp/claude-manifest.json)" = "${CLAUDE_COMMIT}"; \
    test "$(jq -r '.buildDate // empty' /tmp/claude-manifest.json)" = "${CLAUDE_BUILD_DATE}"; \
    test "$(jq -r --arg platform "${CLAUDE_PLATFORM}" '.platforms[$platform].binary // empty' /tmp/claude-manifest.json)" = claude; \
    MANIFEST_SHA256="$(jq -r --arg platform "${CLAUDE_PLATFORM}" '.platforms[$platform].checksum // empty' /tmp/claude-manifest.json)"; \
    MANIFEST_SIZE="$(jq -r --arg platform "${CLAUDE_PLATFORM}" '.platforms[$platform].size // empty' /tmp/claude-manifest.json)"; \
    test "${MANIFEST_SHA256}" = "${EXPECTED_SHA256}"; \
    test "${MANIFEST_SIZE}" = "${EXPECTED_SIZE}"; \
    curl --fail --location --silent --show-error --retry 3 \
        "${RELEASE_ROOT}/${CLAUDE_PLATFORM}/claude" \
        --output /tmp/claude; \
    printf '%s  %s\n' "${EXPECTED_SHA256}" /tmp/claude | sha256sum --check --strict; \
    test "$(stat -c %s /tmp/claude)" = "${EXPECTED_SIZE}"; \
    install -d -m 0755 /opt/claude; \
    install -o root -g root -m 0755 /tmp/claude /opt/claude/claude; \
    ACTUAL_VERSION="$(/opt/claude/claude --version | awk '{print $1}')"; \
    test "${ACTUAL_VERSION}" = "${CLAUDE_VERSION}"; \
    rm -rf "${GNUPGHOME}" /tmp/claude /tmp/claude-code.asc /tmp/claude-manifest.json /tmp/claude-manifest.json.sig

FROM ${PUBLIC_BASE_REF} AS personal-base

ARG PUBLIC_BASE_REF
ARG PUBLIC_RELEASE_SET
ARG PERSONAL_RELEASE_SET
ARG CLAUDE_VERSION
ARG CLAUDE_COMMIT
ARG CLAUDE_MANIFEST_SHA256

USER root
COPY --from=claude-fetch --chown=0:0 --chmod=0755 /opt/claude/claude /usr/local/bin/claude

ENV DISABLE_AUTOUPDATER=1 \
    DISABLE_UPDATES=1

LABEL org.opencontainers.image.source="" \
      io.codex-dev.build.repository="https://github.com/wekingchen/codex-dev-docker" \
      io.codex-dev.image.flavor="personal-dual-cli" \
      io.codex-dev.parent.base="${PUBLIC_BASE_REF}" \
      io.codex-dev.parent.release-set="${PUBLIC_RELEASE_SET}" \
      io.codex-dev.release-set="${PERSONAL_RELEASE_SET}" \
      io.codex-dev.claude.source="https://downloads.claude.ai/claude-code-releases" \
      io.codex-dev.claude.version="${CLAUDE_VERSION}" \
      io.codex-dev.claude.commit="${CLAUDE_COMMIT}" \
      io.codex-dev.claude.manifest-sha256="${CLAUDE_MANIFEST_SHA256}"

FROM ${PUBLIC_REMOTE_REF} AS personal-remote

ARG PUBLIC_REMOTE_REF
ARG PUBLIC_RELEASE_SET
ARG PERSONAL_RELEASE_SET
ARG CLAUDE_VERSION
ARG CLAUDE_COMMIT
ARG CLAUDE_MANIFEST_SHA256

USER root
COPY --from=claude-fetch --chown=0:0 --chmod=0755 /opt/claude/claude /usr/local/bin/claude

# OpenSSH只采用第一条SetEnv；规范化已发布的旧父模板后，在唯一指令中扩展私有更新禁用变量。
RUN set -eux; \
    config=/etc/ssh/codex_sshd_config; \
    canonical_setenv='SetEnv CODEX_HOME=__DEV_HOME__/.codex MISE_DATA_DIR=__DEV_HOME__/.local/share/mise MISE_CONFIG_DIR=__DEV_HOME__/.config/mise'; \
    final_setenv="${canonical_setenv} DISABLE_AUTOUPDATER=1 DISABLE_UPDATES=1"; \
    test -f "${config}"; \
    setenv_count="$(grep -Ec '^SetEnv[[:space:]]+' "${config}")"; \
    if [ "${setenv_count}" -eq 1 ] && grep -Fqx "${canonical_setenv}" "${config}"; then \
        :; \
    elif [ "${setenv_count}" -eq 3 ] \
        && grep -Fqx 'SetEnv CODEX_HOME=__DEV_HOME__/.codex' "${config}" \
        && grep -Fqx 'SetEnv MISE_DATA_DIR=__DEV_HOME__/.local/share/mise' "${config}" \
        && grep -Fqx 'SetEnv MISE_CONFIG_DIR=__DEV_HOME__/.config/mise' "${config}"; then \
        sed -i \
            -e "s|^SetEnv CODEX_HOME=__DEV_HOME__/.codex$|${canonical_setenv}|" \
            -e '/^SetEnv MISE_DATA_DIR=__DEV_HOME__\/.local\/share\/mise$/d' \
            -e '/^SetEnv MISE_CONFIG_DIR=__DEV_HOME__\/.config\/mise$/d' \
            "${config}"; \
    else \
        echo '公开remote父模板的SetEnv结构不受支持。' >&2; \
        exit 1; \
    fi; \
    test "$(grep -Ec '^SetEnv[[:space:]]+' "${config}")" -eq 1; \
    grep -Fqx "${canonical_setenv}" "${config}"; \
    sed -i '/^SetEnv[[:space:]]/s/$/ DISABLE_AUTOUPDATER=1 DISABLE_UPDATES=1/' "${config}"; \
    test "$(grep -Ec '^SetEnv[[:space:]]+' "${config}")" -eq 1; \
    grep -Fqx "${final_setenv}" "${config}"

ENV DISABLE_AUTOUPDATER=1 \
    DISABLE_UPDATES=1

LABEL org.opencontainers.image.source="" \
      io.codex-dev.build.repository="https://github.com/wekingchen/codex-dev-docker" \
      io.codex-dev.image.flavor="personal-dual-cli" \
      io.codex-dev.parent.remote="${PUBLIC_REMOTE_REF}" \
      io.codex-dev.parent.release-set="${PUBLIC_RELEASE_SET}" \
      io.codex-dev.release-set="${PERSONAL_RELEASE_SET}" \
      io.codex-dev.claude.source="https://downloads.claude.ai/claude-code-releases" \
      io.codex-dev.claude.version="${CLAUDE_VERSION}" \
      io.codex-dev.claude.commit="${CLAUDE_COMMIT}" \
      io.codex-dev.claude.manifest-sha256="${CLAUDE_MANIFEST_SHA256}"
