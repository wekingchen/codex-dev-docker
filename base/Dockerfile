# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=$USER_UID

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV CODEX_HOME=/home/${USERNAME}/.codex
ENV MISE_DATA_DIR=/home/${USERNAME}/.local/share/mise
ENV MISE_CONFIG_DIR=/home/${USERNAME}/.config/mise
ENV PATH=/home/${USERNAME}/.local/bin:/home/${USERNAME}/.local/share/mise/shims:${PATH}

# This image is intentionally a Codex runtime base, not a full tech-stack image.
# Project-specific runtimes should be installed later by Codex via mise / project tooling.
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

RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && mkdir -p /workspace \
    && chown -R ${USERNAME}:${USERNAME} /workspace /home/${USERNAME}

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# mise: per-project runtime manager. Keep language runtimes out of the base image.
RUN curl -fsSL https://mise.run | sh \
    && /home/${USERNAME}/.local/bin/mise --version

# Codex CLI official standalone installer.
RUN CODEX_NON_INTERACTIVE=1 sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' \
    && command -v codex \
    && codex --version

RUN mkdir -p "${CODEX_HOME}" "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}" /home/${USERNAME}/.cache \
    && printf '\n# mise\nif [ -x "$HOME/.local/bin/mise" ]; then\n  eval "$($HOME/.local/bin/mise activate bash)"\nfi\n\n# direnv\nif command -v direnv >/dev/null 2>&1; then\n  eval "$(direnv hook bash)"\nfi\n' >> /home/${USERNAME}/.bashrc \
    && printf '\n# mise\nif [ -x "$HOME/.local/bin/mise" ]; then\n  eval "$($HOME/.local/bin/mise activate bash)"\nfi\n' >> /home/${USERNAME}/.profile

WORKDIR /workspace

CMD ["/bin/bash"]
