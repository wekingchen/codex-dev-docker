# codex-dev-docker

这是一个用于运行 Codex 的通用 Docker 开发环境。

它的目标不是预装所有技术栈，而是提供一个干净的 Codex 运行底座。后续打开具体项目时，再让 Codex 根据项目文件识别技术栈，并在容器内安装需要的依赖。

## 设计思路

宿主机只保留：

```text
Docker
workspace 项目目录
一个 dev-home 持久化 volume
```

运行时只挂载两个主要目录：

```text
./workspace  → /workspace
dev-home     → /home/dev
```

`/home/dev` 里会保存 Codex 登录态、mise 运行时、git 配置和各种语言缓存。

基础镜像提供：

```text
Codex CLI
git / git-lfs
ssh client
curl / wget
sudo
mise
build-essential
Python 基础环境
常用命令行工具
```

项目依赖由 Codex 后续在容器内按需安装。

## 默认镜像

本地运行使用的镜像地址集中写在 `.env`：

```text
CODEX_DEV_IMAGE=ghcr.io/wekingchen/codex-dev-base:latest
```

如果以后仓库迁移到其他用户名或组织名，只需要改 `.env`。

正式版本示例：

```text
ghcr.io/wekingchen/codex-dev-base:v0.1.0
```

## 运行

```bash
mkdir -p workspace
docker compose run --rm codex
```

或者：

```bash
./scripts/run.sh
```

默认只挂载：

```text
workspace 项目目录
dev-home 持久化 home volume
```

如果要清空 Codex 登录态、mise 运行时和缓存：

```bash
./scripts/reset-home-volume.sh
```

如果要访问 GitHub 私有仓库，推荐使用 SSH Agent：

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
./scripts/run-with-ssh-agent.sh
```

## 第一次登录 Codex

进入容器后执行：

```bash
codex
```

Codex 登录状态会保存在 Docker volume，不会写进镜像。

## 新项目推荐提示词

进入项目目录后，可以对 Codex 说：

```text
请检查当前项目需要的技术栈和依赖。优先读取 README、package.json、pyproject.toml、go.mod、Cargo.toml、Dockerfile、mise.toml。需要语言运行时时优先用 mise 安装；项目依赖按项目官方方式安装。不要改动系统级配置，除非必要。安装前先说明计划，遇到需要 sudo apt 安装时先告诉我。
```

## 使用 mise 安装语言运行时

示例：Node + Python

```bash
mise use node@lts python@3.12
mise install
```

Go：

```bash
mise use go@latest
mise install
```

Rust：

```bash
mise use rust@stable
mise install
```

## 不建议放入基础镜像的重型技术栈

```text
Flutter / Android SDK
OpenWrt 工具链
数据库服务端
浏览器测试环境
大型交叉编译 SDK
```

这些后续应按项目需要做成派生镜像。

## 发布正式版本

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

发布后可使用：

```bash
docker pull ghcr.io/wekingchen/codex-dev-base:v0.1.0
```


## 自检旧用户名或旧镜像地址

提交前可以运行：

```bash
./scripts/check-hardcoded.sh
```


## 更多说明

```text
docs/USAGE.md
templates/project-AGENTS.md
```
