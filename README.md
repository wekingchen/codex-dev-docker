# codex-dev-docker

这是一个用于运行 Codex CLI 的通用 Docker 开发环境。

基础镜像只提供 Codex、mise、Git、SSH Client、Python 基础环境、编译工具和常用命令行工具。Node.js、Go、Rust、Java 等项目运行时由 Codex 根据项目配置在容器内按需安装。

## 设计概览

```text
宿主机 workspace  ── bind mount ──> /workspace
Docker home volume ── named volume ─> /home/dev
SSH Agent socket   ── 可选转发 ────> /ssh-agent
宿主 127.0.0.1:2222 ── remote overlay ─> codex-ssh:2222
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

## 供应链增强

除 Codex official latest 这一明确的动态例外外，构建输入采用以下固定策略：

- GitHub-hosted runner 固定为 `ubuntu-24.04`，不使用 `ubuntu-latest`。runner 内的软件仍会由 GitHub 滚动更新。
- 所有外部 GitHub Actions 固定到官方仓库的完整 40 位 commit SHA，并保留同行版本注释；checkout 不保留 Git 凭据。
- `ubuntu:26.04` 同时保留可读 tag 和经过验证的多架构根 OCI index digest。
- mise 固定官方 release，并分别校验 amd64、arm64 raw binary 的 SHA-256；不再执行 `curl https://mise.run | sh`。
- registry candidate 会生成 BuildKit `mode=min` provenance 和 SBOM；promotion 前必须确认两者可读。
- Trivy 分别扫描base与remote candidate根digest中的amd64、arm64 manifest，生成JSON、table和SARIF。base保持非阻断基线；remote若存在已有修复版本的CRITICAL漏洞会阻断promotion。扫描器、认证、manifest或报告生成失败始终阻断。
- `.github/workflows/supply-chain-audit.yml` 每周只读检查 Actions SHA、Ubuntu digest、mise asset和 Trivy 版本漂移，不自动修改仓库或 registry。

手动运行审计：

```bash
./scripts/audit-supply-chain.sh
```

Dependabot继续更新 GitHub Actions 和 Docker tag；同 tag Ubuntu digest、mise 和 Trivy binary的漂移由审计 workflow提醒后人工更新，并重新通过完整双架构 candidate流程。

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
CODEX_REMOTE_IMAGE=ghcr.io/wekingchen/codex-dev-remote:latest
CODEX_REMOTE_PORT=2222
CODEX_REMOTE_HOST_KEY_VOLUME=codex-dev-remote-hostkeys
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

## 安全远程接入

远程模式使用独立的 `codex-dev-remote` 镜像和 `compose.remote.yaml`，不会给默认 base 镜像安装 `sshd`。它的安全默认值是：

- 宿主端口固定绑定 `127.0.0.1`，不能通过配置改成 `0.0.0.0`。
- 只允许 `dev` 使用公钥登录；禁止 root、密码和 keyboard-interactive认证。
- 禁止 SSH Agent、TCP、Unix socket、X11和 tunnel forwarding。
- SSH host private key只在独立 Docker volume中运行时生成，不进入镜像或仓库。
- authorized keys从本地 `.codex-ssh/authorized_keys` 只读输入，并复制为容器内 root-owned运行时文件。
- 不挂载 Docker socket、宿主机私钥或宿主根目录。

生成专用客户端密钥并启动：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/codex_remote_ed25519
./scripts/remote.sh setup-key ~/.ssh/codex_remote_ed25519.pub
./scripts/remote.sh up
./scripts/remote.sh fingerprint
```

远程服务复用 `${WORKSPACE}` 和 `codex-dev-home`。为避免两个容器同时修改 Codex状态、mise runtime和workspace，本地 `run.sh` 与远程服务通过共享volume上的 `flock` 互斥；使用本地模式前先运行：

```bash
./scripts/remote.sh down
```

客户端应先通过宿主机现有 SSH，再由 `ProxyJump` 连接宿主loopback端口：

```sshconfig
Host codex-host
    HostName <宿主机地址>
    User <宿主机用户>
    IdentityFile ~/.ssh/<宿主机密钥>

Host codex
    HostName 127.0.0.1
    Port 2222
    User dev
    ProxyJump codex-host
    IdentityFile ~/.ssh/codex_remote_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    UserKnownHostsFile ~/.ssh/known_hosts_codex_dev
    ForwardAgent no
```

首次连接前，通过可信的宿主机SSH会话运行 `remote.sh fingerprint` 并核对 fingerprint；不要使用 `StrictHostKeyChecking=no`。日常连接和断线恢复：

```bash
ssh codex
ssh -t codex 'cd /workspace && exec tmux new-session -A -s codex'
```

按用户选择，远程 `dev` 保留 `NOPASSWD sudo`。因此，写入 `.codex-ssh/authorized_keys` 的任何公钥都应视为拥有该容器的 root权限；只部署专用、受保护的密钥。

常用管理命令：

```bash
./scripts/remote.sh status
./scripts/remote.sh logs --tail=200
./scripts/remote.sh update
./scripts/remote.sh down
# 仅在密钥泄露或明确轮换identity时：
./scripts/remote.sh rotate-host-key ROTATE
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

默认分支、定时任务和受信任的手动构建通过验证后，会为base与remote两个package发布相同标签集合：

```text
ghcr.io/wekingchen/codex-dev-base:latest
ghcr.io/wekingchen/codex-dev-base:YYYYMMDD
ghcr.io/wekingchen/codex-dev-base:<短-commit>
ghcr.io/wekingchen/codex-dev-remote:latest
ghcr.io/wekingchen/codex-dev-remote:YYYYMMDD
ghcr.io/wekingchen/codex-dev-remote:<短-commit>
```

GHCR不提供跨package事务：promotion会在所有门禁通过后依次移动base和remote标签，但极少数registry或网络故障仍可能让失败run留下短暂的部分完成状态。此时不要把失败run视为已发布，应修复故障并重跑同一候选流程，直到两个package的正式标签都通过digest与attestation复核。

推送 Git tag：

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

还会发布 `v0.1.0` 和 `0.1.0`。版本 tag 可能补打在较旧 commit 上，因此 tag 构建不会移动 `latest`。手动运行 workflow 时，`promote` 默认关闭，只构建 candidate、验证两个架构、验证 provenance/SBOM并生成 Trivy报告；明确启用后才移动正式标签。所有正式标签必须与已验证 candidate根 digest完全一致。

## GHCR 清理

`.github/workflows/cleanup-ghcr.yml` 会完整分页读取版本，并且只把明确的 candidate、日期和 commit 标签列为临时版本。以下内容始终保护：

- `latest`
- semver 标签
- 未知标签
- 所有 untagged 版本（包括可能的 attestation、SBOM和平台子 manifest）

当前 cleanup 并不解析 OCI referrer可达关系，而是保守地保护全部 untagged versions，因此启用 attestations 后 registry存储会逐步增长。定时任务会对 `codex-dev-base` 和 `codex-dev-remote` 分别做 dry-run。手动真实删除时一次只选择一个package，需要关闭 `dry_run`、在 `confirm` 中精确填写所选package名称，并受单次硬删除上限保护。

## 自检

```bash
./scripts/check-hardcoded.sh
./scripts/check-secrets.sh
./scripts/audit-supply-chain.sh
bash -n scripts/*.sh
shellcheck scripts/*.sh
docker compose -f compose.yaml -f compose.remote.yaml --profile remote config
```

更多操作细节见 [`docs/USAGE.md`](docs/USAGE.md)。
