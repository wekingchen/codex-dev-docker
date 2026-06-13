# Usage

## 1. Build image with GitHub Actions

Push this repository to GitHub. The workflow publishes:

```text
ghcr.io/<your-github-username>/codex-dev-base:latest
ghcr.io/<your-github-username>/codex-dev-base:YYYYMMDD
ghcr.io/<your-github-username>/codex-dev-base:<short-sha>
```

For this repo template, the compose file uses:

```text
ghcr.io/minjue2017/codex-dev-base:latest
```

Change it if your GitHub username or image name differs.

## 2. Run locally

```bash
mkdir -p workspace
docker compose run --rm codex
```

Or:

```bash
./scripts/run.sh
```

With SSH agent for private git repositories:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
./scripts/run-with-ssh-agent.sh
```

## 3. First Codex login

Inside the container:

```bash
codex
```

The login state is stored in the Docker volume:

```text
codex-home:/home/dev/.codex
```

Do not bake this into the image.

## 4. Let Codex install project dependencies

Example prompt inside Codex:

```text
请检查当前项目需要的技术栈和依赖。优先读取 README、package.json、pyproject.toml、go.mod、Cargo.toml、Dockerfile、mise.toml。需要语言运行时时优先用 mise 安装；项目依赖按项目官方方式安装。不要改动系统级配置，除非必要。安装前先说明计划，遇到需要 sudo apt 安装时先告诉我。
```

## 5. Optional project AGENTS.md

For a new project, copy:

```bash
cp /path/to/this-repo/templates/project-AGENTS.md /workspace/your-project/AGENTS.md
```

Codex will use it as project-level instruction.
