# codex-dev-docker

A generic Docker runtime environment for Codex.

The purpose of this image is **not** to preinstall every possible technology stack. Instead, it provides a clean Codex runtime base. Later, when you open a project, Codex can inspect that project and install the required stack inside the container.

## Design

Host machine:

```text
Docker
workspace directory
persistent Docker volumes
```

Container image:

```text
Codex CLI
git / ssh / curl / sudo
mise
build-essential
Python basics
common CLI/debug tools
```

Project-specific dependencies:

```text
installed later by Codex inside the container
persisted through volumes where useful
```

## Image

Default image name:

```text
ghcr.io/minjue2017/codex-dev-base:latest
```

The GitHub Actions workflow also publishes date and commit tags.

## Run

```bash
mkdir -p workspace
docker compose run --rm codex
```

Or:

```bash
./scripts/run.sh
```

With SSH agent:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
./scripts/run-with-ssh-agent.sh
```

## First Codex login

Inside the container:

```bash
codex
```

The Codex login state is stored in a Docker volume, not in the image.

## Recommended Codex prompt for new projects

```text
请检查当前项目需要的技术栈和依赖。优先读取 README、package.json、pyproject.toml、go.mod、Cargo.toml、Dockerfile、mise.toml。需要语言运行时时优先用 mise 安装；项目依赖按项目官方方式安装。不要改动系统级配置，除非必要。安装前先说明计划，遇到需要 sudo apt 安装时先告诉我。
```

## Example: install runtimes with mise

Inside a project:

```bash
mise use node@lts python@3.12
mise install
```

Go:

```bash
mise use go@latest
mise install
```

Rust:

```bash
mise use rust@stable
mise install
```

## Heavy stacks

Do not put these in the base image by default:

```text
Flutter / Android SDK
OpenWrt toolchains
database servers
browser testing stacks
large cross-compilation SDKs
```

Create derived images later when a project clearly needs them.

## More docs

See:

```text
docs/USAGE.md
templates/project-AGENTS.md
```
