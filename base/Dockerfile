# syntax=docker/dockerfile:1.7
FROM ubuntu:26.04@sha256:651ba3fe3a830441e3deaf70fafac40d808a6bd2800a6f2c43130055159f23e6 AS runtime

ARG TARGETARCH
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=$USER_UID
ARG MISE_VERSION=v2026.7.7
ARG MISE_SHA256_AMD64=429f71e7e989908bf975aafac9066329c16e2d8fc7cd8e74fdf21dd6300ffe7c
ARG MISE_SHA256_ARM64=1b4ef061d25f0ceb508f11169482f3074e55c1698a1494f666386b2fcfb46b9b
ARG CODEX_RELEASE=latest
ARG CODEX_RELEASE_ID=latest
ARG CODEX_RELEASE_TAG=latest

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=zh_CN.UTF-8
ENV LC_ALL=zh_CN.UTF-8
ENV HOME=/home/${USERNAME}
ENV DEV_USER=${USERNAME}
ENV DEV_HOME=/home/${USERNAME}
ENV CODEX_HOME=/home/${USERNAME}/.codex
ENV MISE_DATA_DIR=/home/${USERNAME}/.local/share/mise
ENV MISE_CONFIG_DIR=/home/${USERNAME}/.config/mise
ENV PATH=/home/${USERNAME}/.local/share/mise/shims:/usr/local/bin:/home/${USERNAME}/.local/bin:${PATH}

# 共享 runtime 只提供 Codex 通用工具，不预装完整技术栈。
# 项目需要的语言运行时和依赖，后续由 Codex 根据项目内容在容器内安装。
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
    bash \
    bash-completion \
    ca-certificates \
    curl \
    wget \
    git \
    git-lfs \
    sudo \
    gosu \
    zsh \
    openssh-client \
    gnupg \
    lsb-release \
    software-properties-common \
    build-essential \
    pkg-config \
    make \
    cmake \
    autoconf \
    automake \
    libtool \
    patch \
    python3 \
    python3-pip \
    python3-venv \
    python-is-python3 \
    jq \
    yq \
    unzip \
    zip \
    xz-utils \
    zstd \
    file \
    rsync \
    ripgrep \
    fd-find \
    fzf \
    nano \
    vim \
    less \
    htop \
    tmux \
    tree \
    procps \
    psmisc \
    iproute2 \
    iputils-ping \
    dnsutils \
    netcat-openbsd \
    direnv \
    shellcheck \
    bc \
    locales \
    tzdata \
    util-linux \
    && locale-gen en_US.UTF-8 zh_TW.UTF-8 zh_CN.UTF-8 \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 基础镜像中可能已经存在 UID/GID 1000。
# 这里会优先复用或重命名已有用户/用户组，避免 groupadd 因 GID 冲突导致构建失败。
RUN set -eux; \
    if getent passwd "${USERNAME}" >/dev/null; then \
        true; \
    elif getent passwd "${USER_UID}" >/dev/null; then \
        EXISTING_USER="$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
        usermod -l "${USERNAME}" -d "/home/${USERNAME}" -m "${EXISTING_USER}"; \
    else \
        if getent group "${USER_GID}" >/dev/null; then \
            GROUP_NAME="$(getent group "${USER_GID}" | cut -d: -f1)"; \
        else \
            groupadd --gid "${USER_GID}" "${USERNAME}"; \
            GROUP_NAME="${USERNAME}"; \
        fi; \
        useradd --uid "${USER_UID}" --gid "${GROUP_NAME}" -m -s /bin/bash "${USERNAME}"; \
    fi; \
    if ! getent group "${USERNAME}" >/dev/null; then \
        if getent group "${USER_GID}" >/dev/null; then \
            EXISTING_GROUP="$(getent group "${USER_GID}" | cut -d: -f1)"; \
            groupmod -n "${USERNAME}" "${EXISTING_GROUP}" || true; \
        else \
            groupadd --gid "${USER_GID}" "${USERNAME}"; \
        fi; \
    fi; \
    usermod -g "${USERNAME}" "${USERNAME}" || true; \
    usermod -aG sudo "${USERNAME}"; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}; \
    chmod 0440 /etc/sudoers.d/${USERNAME}; \
    mkdir -p /workspace \
        "/home/${USERNAME}/.codex" \
        "/home/${USERNAME}/.local/bin"; \
    chown -R "${USERNAME}:${USERNAME}" /workspace "/home/${USERNAME}"

USER root
WORKDIR /home/${USERNAME}

# mise：固定官方 release 和两个目标架构的 SHA-256，不执行浮动远程安装脚本。
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) MISE_ARCH="x64"; MISE_SHA256="${MISE_SHA256_AMD64}" ;; \
        arm64) MISE_ARCH="arm64"; MISE_SHA256="${MISE_SHA256_ARM64}" ;; \
        *) echo "Unsupported TARGETARCH for mise: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    MISE_ASSET="mise-${MISE_VERSION}-linux-${MISE_ARCH}"; \
    curl --fail --location --silent --show-error --retry 3 \
        "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/${MISE_ASSET}" \
        --output "/tmp/${MISE_ASSET}"; \
    printf '%s  %s\n' "${MISE_SHA256}" "/tmp/${MISE_ASSET}" | sha256sum --check --strict; \
    install -m 0755 "/tmp/${MISE_ASSET}" /usr/local/bin/mise; \
    rm -f "/tmp/${MISE_ASSET}"; \
    ACTUAL_MISE_VERSION="$(mise --version | awk '{print $1}')"; \
    test "${ACTUAL_MISE_VERSION}" = "${MISE_VERSION#v}"

USER ${USERNAME}

# Codex CLI 始终通过 OpenAI 官方独立安装脚本安装。
# CI 动态传入当时的官方 latest；release 身份进入本层缓存键，避免复用旧 Codex 层。
RUN echo "Installing official Codex release ${CODEX_RELEASE_TAG} (id=${CODEX_RELEASE_ID}, version=${CODEX_RELEASE})" \
    && CODEX_NON_INTERACTIVE=1 \
       CODEX_RELEASE="${CODEX_RELEASE}" \
       CODEX_INSTALL_DIR="/home/${USERNAME}/.local/bin" \
       sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' \
    && command -v codex | tee /tmp/codex-path \
    && codex --version

USER root
RUN install -m 0755 "$(cat /tmp/codex-path)" /usr/local/bin/codex \
    && rm -f /tmp/codex-path

LABEL io.codex-dev.mise.source="https://github.com/jdx/mise" \
      io.codex-dev.mise.version="${MISE_VERSION}" \
      io.codex-dev.codex.source="https://github.com/openai/codex" \
      io.codex-dev.codex.release-id="${CODEX_RELEASE_ID}" \
      io.codex-dev.codex.release-tag="${CODEX_RELEASE_TAG}" \
      io.codex-dev.codex.version="${CODEX_RELEASE}"

COPY --chmod=0755 scripts/dev-init.sh /usr/local/lib/codex-dev/dev-init.sh

USER ${USERNAME}
RUN mkdir -p "${CODEX_HOME}" "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}" /home/${USERNAME}/.cache \
    && printf '\n# mise\nif command -v mise >/dev/null 2>&1; then\n  eval "$(mise activate bash)"\nfi\n\n# direnv\nif command -v direnv >/dev/null 2>&1; then\n  eval "$(direnv hook bash)"\nfi\n' >> /home/${USERNAME}/.bashrc \
    && printf '\n# mise\nif command -v mise >/dev/null 2>&1; then\n  eval "$(mise activate bash)"\nfi\n' >> /home/${USERNAME}/.profile

# 远程镜像独立增加 sshd，base 镜像不承担服务端 SSH 攻击面。
FROM runtime AS remote

USER root
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends openssh-server \
    && rm -f /etc/ssh/ssh_host_* \
    && install -d -m 0700 /etc/ssh/codex-host-keys \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0644 remote/sshd_config /etc/ssh/codex_sshd_config
COPY --chmod=0755 scripts/remote-entrypoint.sh /usr/local/bin/remote-entrypoint.sh
COPY --chmod=0755 scripts/remote-hostkey-init.sh /usr/local/bin/remote-hostkey-init.sh
COPY --chmod=0755 scripts/validate-authorized-keys.sh /usr/local/bin/validate-authorized-keys.sh

LABEL io.codex-dev.image.role="remote"

WORKDIR /workspace
EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/remote-entrypoint.sh"]

# base 必须保持为最后一个 target，使未指定 --target 的现有构建行为不变。
FROM runtime AS base

USER root
COPY --chmod=0755 scripts/dev-entrypoint.sh /usr/local/bin/dev-entrypoint.sh

LABEL io.codex-dev.image.role="base"

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/dev-entrypoint.sh"]
CMD ["/bin/bash"]
