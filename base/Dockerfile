# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=$USER_UID

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=zh_CN.UTF-8
ENV LC_ALL=zh_CN.UTF-8
ENV CODEX_HOME=/home/${USERNAME}/.codex
ENV MISE_DATA_DIR=/home/${USERNAME}/.local/share/mise
ENV MISE_CONFIG_DIR=/home/${USERNAME}/.config/mise
ENV PATH=/home/${USERNAME}/.local/share/mise/shims:/usr/local/bin:/home/${USERNAME}/.local/bin:${PATH}

# 这个镜像只作为 Codex 通用运行底座，不预装完整技术栈。
# 项目需要的语言运行时和依赖，后续由 Codex 根据项目内容在容器内安装。
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bash-completion \
    ca-certificates \
    curl \
    wget \
    git \
    git-lfs \
    sudo \
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
    && locale-gen en_US.UTF-8 zh_TW.UTF-8 zh_CN.UTF-8 \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 基础镜像中可能已经存在 UID/GID 1000。
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
    mkdir -p /workspace "/home/${USERNAME}"; \
    chown -R "${USERNAME}:${USERNAME}" /workspace "/home/${USERNAME}"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# mise：按项目管理 Node、Python、Go、Rust、Java 等语言运行时。
# 基础镜像不内置这些运行时，避免变成臃肿的全家桶镜像。
RUN curl -fsSL https://mise.run | sh \
    && /home/${USERNAME}/.local/bin/mise --version

USER root
RUN install -m 0755 "/home/${USERNAME}/.local/bin/mise" /usr/local/bin/mise

USER ${USERNAME}

# Codex CLI 官方独立安装脚本。
RUN CODEX_NON_INTERACTIVE=1 sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' \
    && command -v codex | tee /tmp/codex-path \
    && codex --version

USER root
RUN install -m 0755 "$(cat /tmp/codex-path)" /usr/local/bin/codex \
    && rm -f /tmp/codex-path

COPY scripts/dev-entrypoint.sh /usr/local/bin/dev-entrypoint.sh
RUN chmod 0755 /usr/local/bin/dev-entrypoint.sh

USER ${USERNAME}

RUN mkdir -p "${CODEX_HOME}" "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}" /home/${USERNAME}/.cache \
    && printf '\n# mise\nif command -v mise >/dev/null 2>&1; then\n  eval "$(mise activate bash)"\nfi\n\n# direnv\nif command -v direnv >/dev/null 2>&1; then\n  eval "$(direnv hook bash)"\nfi\n' >> /home/${USERNAME}/.bashrc \
    && printf '\n# mise\nif command -v mise >/dev/null 2>&1; then\n  eval "$(mise activate bash)"\nfi\n' >> /home/${USERNAME}/.profile

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/dev-entrypoint.sh"]
CMD ["/bin/bash"]
