# codex-dev-docker

这是一个用于运行 Codex CLI 的通用 Docker 开发环境。

基础镜像只提供 Codex、mise、Git、SSH Client、Python 基础环境、编译工具和常用命令行工具。Node.js、Go、Rust、Java 等项目运行时由 Codex 根据项目配置在容器内按需安装。

## 设计概览

```text
宿主机 workspace  ── bind mount ──> /workspace
Docker home volume ── named volume ─> /home/dev
SSH Agent socket   ── 可选转发 ────> /ssh-agent
```

`/home/dev` 会持久化：

- Codex 登录状态
- mise 安装的语言运行时
- Git 配置
- npm、pnpm、pip、Go、Cargo 等缓存

容器入口脚本以 root 初始化 home volume，随后通过 `gosu` 降权为 `dev` 用户执行命令。它不会递归修改 bind-mounted `/workspace` 的所有权。

## Codex 官方 latest 保证

Codex 只通过 OpenAI 官方安装入口安装：

```text
https://chatgpt.com/codex/install.sh
```

GitHub Actions 在每次构建时从 `openai/codex` 官方 `releases/latest` API 动态解析 latest release，并让 release ID、tag 和版本进入 Codex 安装层的缓存键。发布前会：

1. 分别构建并运行 amd64、arm64 smoke test。
2. 把双架构镜像推为唯一 candidate tag。
3. 按 candidate digest 再次验证两个架构。
4. 再次查询官方 latest；如果构建期间上游已更新，本次不移动正式标签。
5. 只有全部通过后，才把已验证 digest 提升为 `latest`、日期和 commit 标签。

因此，每次新发布的 GHCR `latest` 都与该次发布流程确认的 OpenAI 官方 latest 一致。每日定时任务负责追踪上游更新；它不承诺 OpenAI 发版与本项目镜像在同一瞬间完成更新。

## 配置

本地配置不受 Git 跟踪。首次使用可以复制示例：

```bash
cp .env.example .env
```

默认配置：

```dotenv
CODEX_DEV_IMAGE=ghcr.io/wekingchen/codex-dev-base:latest
HOME_VOLUME=codex-dev-home
WORKSPACE=./workspace
CODEX_DEV_PULL_POLICY=always
```

默认 `pull_policy=always`，每次启动都会检查 GHCR 中是否有新的 `latest`。离线使用时，可以在本地 `.env` 中临时设置：

```dotenv
CODEX_DEV_PULL_POLICY=missing
```

不要在 `.env` 中保存 token、私钥或其他秘密。

## 运行

```bash
mkdir -p workspace
./scripts/run.sh
```

也可以直接使用 Compose：

```bash
docker compose run --rm codex
```

两个入口使用相同的 Compose 配置和实际 home volume。

只拉取镜像：

```bash
./scripts/pull-latest.sh
```

## 使用 SSH Agent

宿主机启动 agent 并添加密钥：

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
./scripts/run-with-ssh-agent.sh
```

脚本只转发 SSH Agent socket，不挂载私钥。原生 Linux 上会同步宿主机 UID/GID，以便容器内 `dev` 用户访问 workspace 和 agent socket。

## Linux UID/GID

在原生 Linux 上，运行脚本默认向容器传递：

```text
HOST_UID=$(id -u)
HOST_GID=$(id -g)
```

entrypoint 会安全调整 `dev` 用户身份，只修复 `/home/dev`，不会 `chown -R /workspace`。如果目标 UID 已被容器内其他用户占用，容器会明确失败而不是接管该用户。

macOS 和 Windows Docker Desktop 默认保持镜像内的 UID/GID 1000，不自动重映射。

## 迁移旧 Compose home volume

旧版本的 Compose 可能创建了带项目名前缀的 volume，例如：

```text
codex-dev-docker_codex-dev-home
```

先查询准确名称：

```bash
docker volume ls
```

然后执行只复制、不删除源数据的迁移：

```bash
./scripts/migrate-home-volume.sh <旧-volume-名称> codex-dev-home
```

迁移脚本会拒绝覆盖非空目标。验证 Codex 登录状态、mise 和 Git 配置正常后，至少保留旧 volume 一个稳定发布周期。需要回滚时，在本地 `.env` 中设置：

```dotenv
HOME_VOLUME=<旧-volume-名称>
```

## 重置 home volume

以下操作会删除 Codex 登录状态、mise runtime、Git 配置和缓存：

```bash
./scripts/reset-home-volume.sh codex-dev-home
```

脚本要求显式传入通过 `docker volume ls` 确认的实际名称，并要求输入 `DELETE <volume-name>`。它会先停止本项目容器、拒绝删除仍被其他容器占用的 volume，并在删除后再次复核。

## 第一次登录 Codex

进入容器后执行：

```bash
codex
```

登录状态保存在 Docker volume 中，不会写入镜像。

## 项目运行时

示例：

```bash
mise use node@lts python@3.12
mise install

mise use go@latest
mise install

mise use rust@stable
mise install
```

不建议把 Flutter、Android SDK、OpenWrt 工具链、数据库服务端、浏览器测试环境等重型技术栈加入基础镜像，应按项目制作派生镜像。

## 发布标签

默认分支、定时任务和受信任的手动构建通过验证后会发布：

```text
ghcr.io/wekingchen/codex-dev-base:latest
ghcr.io/wekingchen/codex-dev-base:YYYYMMDD
ghcr.io/wekingchen/codex-dev-base:<短-commit>
```

推送 Git tag：

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

还会发布 `v0.1.0` 和 `0.1.0`。版本 tag 可能补打在较旧 commit 上，因此 tag 构建不会移动 `latest`。手动运行 workflow 时，`promote` 默认关闭，只构建和验证 candidate；明确启用后才移动正式标签。

## GHCR 清理

`.github/workflows/cleanup-ghcr.yml` 会完整分页读取版本，并且只把明确的 candidate、日期和 commit 标签列为临时版本。以下内容始终保护：

- `latest`
- semver 标签
- 未知标签
- untagged 版本
- 无法确认用途的 OCI referrer

定时任务当前只做 dry-run。手动真实删除时需要关闭 `dry_run`、填写确认值 `codex-dev-base`，并受单次硬删除上限保护。

## 自检

```bash
./scripts/check-hardcoded.sh
bash -n scripts/*.sh
shellcheck scripts/*.sh
```

更多操作细节见 [`docs/USAGE.md`](docs/USAGE.md)。
