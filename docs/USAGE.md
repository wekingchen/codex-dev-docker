# 使用说明

## 1. 用 GitHub Actions 构建镜像

把本仓库推送到 GitHub 后，Actions 会发布镜像：

```text
ghcr.io/<你的 GitHub 用户名>/codex-dev-base:latest
ghcr.io/<你的 GitHub 用户名>/codex-dev-base:YYYYMMDD
ghcr.io/<你的 GitHub 用户名>/codex-dev-base:<短 commit>
```

如果推送 Git tag，例如：

```text
v0.1.0
```

还会额外发布：

```text
ghcr.io/<你的 GitHub 用户名>/codex-dev-base:v0.1.0
ghcr.io/<你的 GitHub 用户名>/codex-dev-base:0.1.0
```

本模板默认镜像地址集中写在 `.env`：

```text
CODEX_DEV_IMAGE=ghcr.io/wekingchen/codex-dev-base:latest
```

如果你的 GitHub 用户名或镜像名不同，只需要修改 `.env`。

## 2. 本地运行

```bash
mkdir -p workspace
docker compose run --rm codex
```

或者：

```bash
./scripts/run.sh
```

当前版本采用极简挂载：

```text
./workspace  → /workspace
dev-home     → /home/dev
```

`/home/dev` 会统一保存 Codex 登录态、mise、git 配置和各种语言缓存。

## 3. 使用 SSH Agent 访问私有仓库

宿主机先启动 ssh-agent 并添加密钥：

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

然后运行：

```bash
./scripts/run-with-ssh-agent.sh
```

这种方式不会把 SSH 私钥文件直接挂进容器，安全性更好。

## 4. 第一次登录 Codex

进入容器后执行：

```bash
codex
```

Codex 登录状态会保存在 `dev-home` 这个 Docker volume 中：

```text
dev-home:/home/dev
```

不要把登录状态写进镜像。

## 5. 让 Codex 按项目安装依赖

进入项目目录后，可以对 Codex 说：

```text
请检查当前项目需要的技术栈和依赖。优先读取 README、package.json、pyproject.toml、go.mod、Cargo.toml、Dockerfile、mise.toml。需要语言运行时时优先用 mise 安装；项目依赖按项目官方方式安装。不要改动系统级配置，除非必要。安装前先说明计划，遇到需要 sudo apt 安装时先告诉我。
```

## 6. 给具体项目添加 AGENTS.md

新项目可以复制模板：

```bash
cp templates/project-AGENTS.md workspace/你的项目/AGENTS.md
```

Codex 会把它作为项目级指令读取。

## 7. 发布正式版本

创建并推送 Git tag：

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

构建成功后可以固定使用：

```bash
docker pull ghcr.io/wekingchen/codex-dev-base:v0.1.0
```

## 8. 清理旧镜像版本

仓库包含自动清理 workflow：

```text
.github/workflows/cleanup-ghcr.yml
```

默认保留：

```text
latest
v0.1.0 这类正式版本
0.1.0 这类正式版本
最近 10 个非正式版本
```

如需先演练不删除，把 workflow 里的：

```text
DRY_RUN: "false"
```

改成：

```text
DRY_RUN: "true"
```
