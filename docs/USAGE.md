# 使用说明

## 1. 初始化本地配置

`.env` 是本地文件，不受 Git 跟踪：

```bash
cp .env.example .env
```

默认内容：

```dotenv
CODEX_DEV_IMAGE=ghcr.io/wekingchen/codex-dev-base:latest
HOME_VOLUME=codex-dev-home
WORKSPACE=./workspace
CODEX_DEV_PULL_POLICY=always
CODEX_REMOTE_IMAGE=ghcr.io/wekingchen/codex-dev-remote:latest
CODEX_REMOTE_PORT=2222
CODEX_REMOTE_HOST_KEY_VOLUME=codex-dev-remote-hostkeys
```

变量优先级遵循 Docker Compose：调用进程环境高于 `.env`，`.env` 高于 Compose 中的默认值。脚本不会 `source .env`，因此配置文件不会作为宿主机 shell 代码执行。

## 2. 本地启动

推荐入口：

```bash
mkdir -p workspace
./scripts/run.sh
```

等价的 Compose 入口：

```bash
docker compose run --rm codex
```

只拉取镜像：

```bash
./scripts/pull-latest.sh
```

默认每次启动都会检查 GHCR 的 `latest`。离线时可以设置：

```dotenv
CODEX_DEV_PULL_POLICY=missing
```

挂载关系：

```text
${WORKSPACE:-./workspace} → /workspace
${HOME_VOLUME:-codex-dev-home} → /home/dev
```

远程overlay对workspace bind启用 `create_host_path: false`。默认 `./workspace` 会由管理脚本创建；如果 `.env` 使用自定义 `WORKSPACE`，必须先由正确的宿主用户创建该目录，否则启动会明确失败，而不会让Docker daemon创建root-owned目录。

## 3. Codex 官方 latest

Dockerfile 只调用 OpenAI 官方安装入口：

```text
https://chatgpt.com/codex/install.sh
```

CI 发布过程：

1. 查询 `openai/codex` 官方 GitHub `releases/latest`。
2. 把 release ID、tag 和规范化版本作为动态 build args。
3. release 身份进入 Codex 安装 `RUN` 层，防止 BuildKit 缓存旧版本。
4. 构建并运行 amd64、arm64 smoke test。
5. 推送唯一 candidate manifest，并按 digest 再验证两个架构。
6. 发布前再次查询官方 latest；如果 release ID 已变化则停止 promotion。
7. 仅将验证过的 candidate digest 提升为正式标签。

本地直接构建且不传 build args 时，Dockerfile 的 `CODEX_RELEASE` 默认为 `latest`，仍由官方 installer 解析当前 latest。

## 3.1 供应链固定与构建证明

当前策略：

- 所有外部 Actions 使用完整 SHA和同行版本注释。
- runner固定为 `ubuntu-24.04`；这只固定 OS label，不固定 GitHub runner VM镜像内容。
- Dockerfile 的 Ubuntu使用 tag+多架构根 index digest。
- mise固定官方 release，并分别校验 amd64、arm64 asset SHA-256。
- Codex继续动态追踪 official latest，不与 mise采用相同的静态固定策略。

Base与remote candidate push都会生成BuildKit `mode=min` provenance和SBOM。随后CI按各自不可变根digest验证：

1. 两个package的根index都包含amd64和arm64可运行manifest。
2. 两个package的provenance和SBOM都可从registry读取。
3. Base与remote的两个平台registry smoke都通过；remote smoke执行真实key-only SSH认证和共享home锁测试。
4. Trivy分别扫描两个package的amd64、arm64 manifest。
5. promotion后的每个正式标签digest必须与对应candidate根digest一致，并仍可读取attestations。

Base Trivy保持初始非阻断基线：报告HIGH/CRITICAL，但漏洞数量不阻断。Remote包含额外sshd攻击面，若发现已有修复版本的CRITICAL漏洞则阻断promotion；未修复CRITICAL和HIGH继续报告。扫描基础设施失败始终阻断。每个平台会上传JSON、table、SARIF artifact；SARIF还会尝试上传到Code Scanning。

只读供应链审计：

```bash
./scripts/audit-supply-chain.sh
```

它会检查Actions tag/SHA对应关系、Ubuntu根digest和平台、mise最新稳定release及双架构checksum、Trivy固定版本。Codex不做静态版本比较，因为其official latest检查属于构建workflow。

## 4. Home volume 迁移

旧 Compose 配置没有显式 volume `name`，实际名称可能带项目名前缀。先查询：

```bash
docker volume ls
```

停止使用源或目标 volume 的容器，然后迁移：

```bash
./scripts/migrate-home-volume.sh <旧-volume-名称> codex-dev-home
```

迁移脚本会：

- 验证源 volume 存在。
- 拒绝源、目标相同。
- 拒绝迁移仍被容器使用的 volume。
- 创建缺失的目标 volume。
- 拒绝覆盖或合并非空目标。
- 保留 dotfiles 和文件元数据。
- 比较源、目标文件系统对象数量。
- 永不删除源 volume。

迁移后检查：

```bash
codex --version
mise --version
git config --list
```

确认 Codex 登录状态和所需 runtime 正常。回滚时只需在本地 `.env` 中指定旧名称：

```dotenv
HOME_VOLUME=<旧-volume-名称>
```

## 5. 重置 Home volume

```bash
./scripts/reset-home-volume.sh codex-dev-home
```

脚本要求显式传入实际 Docker volume 名并输入 `DELETE <volume-name>`。它会先停止本项目容器、检查是否仍有其他容器引用目标、直接删除并再次复核。不要对仍需保留的登录状态或 runtime 执行该操作。

## 6. 安全远程接入

### 6.1 边界与威胁模型

远程模式不是把容器SSH直接暴露到公网，而是要求两层认证：

1. 客户端先通过宿主机已有SSH服务。
2. `ProxyJump` 再连接宿主机 `127.0.0.1:${CODEX_REMOTE_PORT:-2222}`，由容器验证独立公钥。

`compose.remote.yaml` 把端口的 `host_ip` 固定为 `127.0.0.1`，没有公网绑定变量。容器只允许 `dev` 公钥登录，禁止 root、密码、keyboard-interactive、Agent forwarding、TCP/Unix socket forwarding、X11和tunnel。容器不挂载Docker socket、宿主私钥或宿主根目录。

远程 `dev` 按当前策略保留 `NOPASSWD sudo`，所以授权公钥等价于该容器root。容器边界不能替代宿主机补丁、防火墙、SSH加固和磁盘保护。

### 6.2 部署客户端公钥

建议为Codex远程服务生成独立密钥，不要复用宿主机管理密钥：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/codex_remote_ed25519
./scripts/remote.sh setup-key ~/.ssh/codex_remote_ed25519.pub
```

`setup-key` 只接受不带 `authorized_keys` options 的标准OpenSSH公钥行，会拒绝私钥头、known_hosts格式和任意无效行，并把结果原子写入被Git和Docker build context排除的 `.codex-ssh/authorized_keys`。不要把私钥、密码或token放进 `.env`。

### 6.3 启动与核对host identity

```bash
./scripts/remote.sh up
./scripts/remote.sh status
./scripts/remote.sh fingerprint
```

首次启动时，one-shot init服务会在 `${CODEX_REMOTE_HOST_KEY_VOLUME:-codex-dev-remote-hostkeys}` 中生成Ed25519 host key。主服务只读挂载该volume，因此更新镜像、重建容器或重置home都不会改变host fingerprint。

首次客户端连接前，先通过可信的宿主机SSH会话执行 `remote.sh fingerprint`，再把对应host key写入专用known_hosts。不要使用 `StrictHostKeyChecking=no`。

### 6.4 ProxyJump配置

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

连接：

```bash
ssh codex
ssh -t codex 'cd /workspace && exec tmux new-session -A -s codex'
```

### 6.5 共享home/workspace互斥

远程服务和本地 `docker compose run --rm codex` 复用同一个home与workspace。所有入口会直接对 `${DEV_HOME}` 的稳定volume挂载根目录取得 `flock`；第二个容器会以退出码73失败，避免同时修改Codex登录态、mise runtime、缓存或项目文件。锁定挂载根目录而不是home内可删除的普通文件，可避免同名inode被替换后绕过互斥。

包装脚本还会提供更友好的预检查：

```bash
./scripts/remote.sh down
./scripts/run.sh
```

不要绕过锁文件或给两个模式配置不同锁路径。

### 6.6 更新、日志与停止

```bash
./scripts/remote.sh logs --tail=200
./scripts/remote.sh update
./scripts/remote.sh down
```

`update` 拉取新的remote `latest`并重建服务，保留workspace、home和host key。`down` 只移除远程容器，不删除volume。需要回滚时，可把 `.env` 中的 `CODEX_REMOTE_IMAGE` 固定到已验证digest，再执行 `remote.sh update`。

只有在host private key疑似泄露或明确需要更换服务器identity时才执行：

```bash
./scripts/remote.sh rotate-host-key ROTATE
```

该操作会先停止服务并在host-key volume内备份旧密钥，再生成新Ed25519 key；只有新identity成功启动后才删除备份，普通生成或启动失败会恢复旧identity并保持服务停止。轮换成功后所有客户端都必须删除旧known_hosts记录，并通过可信宿主机SSH会话重新核对 `remote.sh fingerprint`。镜像更新、home重置和普通容器重建不会自动轮换host key。

## 7. SSH Agent

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
./scripts/run-with-ssh-agent.sh
```

脚本要求 `SSH_AUTH_SOCK` 存在且确实是 Unix socket。它只挂载 agent socket，不挂载私钥文件。容器内可验证：

```bash
ssh-add -l
```

任何能访问 socket 的容器进程都可以请求 agent 完成认证或签名，因此只应在可信项目中启用。

## 8. Linux UID/GID

原生 Linux 上，包装脚本自动传递宿主用户的 UID/GID。entrypoint 会：

1. 要求 `HOST_UID`、`HOST_GID` 同时存在且为非零整数。
2. 安全复用已存在的目标 GID。
3. 如果目标 UID 被其他用户占用则停止启动。
4. 调整 `dev` 用户身份。
5. 只递归修复 `/home/dev`。
6. 通过 `gosu dev` 执行用户命令。

它不会修改 `/workspace` 的宿主机所有权。macOS/Windows 默认不启用自动 UID/GID 重映射。

## 9. 第一次登录和项目依赖

进入容器后：

```bash
codex
```

登录状态保存在 `/home/dev/.codex`。

建议让 Codex 先读取 README、lockfile、`package.json`、`pyproject.toml`、`go.mod`、`Cargo.toml`、`Dockerfile`、`mise.toml`，再通过 mise 和项目原生包管理器安装依赖。

新项目可以复制指令模板：

```bash
cp templates/project-AGENTS.md workspace/你的项目/AGENTS.md
```

## 10. GitHub Actions 发布

PR 只运行静态检查和双架构构建/smoke，不登录或推送 GHCR。

受信任事件会向 `codex-dev-base` 与 `codex-dev-remote` 分别发布同名的唯一candidate标签：

```text
candidate-<run-id>-<run-attempt>
```

两个candidate发布后，CI会执行各自的双架构registry smoke、provenance/SBOM验证和双平台Trivy扫描。只有两个package的全部门禁通过且官方latest未变化，统一promotion job才按对应digest提升两边的正式标签：

```text
latest
YYYYMMDD
<短-commit>
```

Git tag 构建还会增加：

```text
v0.1.0
0.1.0
```

为避免在旧commit上补打版本tag时回退 `latest`，tag构建不会移动 `latest`。手动workflow的 `promote` 默认为 `false`，适合先演练完整candidate流程。

GHCR没有跨package事务。统一promotion job只保证在移动任何标签前，base与remote的全部candidate门禁都已成功；它仍需依次修改两个package。若registry或网络故障让job在中途失败，可能暂时出现部分标签已更新。失败run不得视为有效发布，应重跑并确认两个package的所有正式标签digest和attestations都完成复核。

## 11. GHCR 安全清理

清理 workflow 会：

- 根据 owner 类型选择 User 或 Organization API。
- 分页读取超过 100 个版本。
- 保护 latest、semver、未知标签和全部 untagged versions；当前不解析referrer可达关系。
- 只清理旧 candidate、日期和 commit 临时标签。
- 保留最近 10 个临时版本。
- 限制单次删除数量，硬上限为 10。

每周schedule会对 `codex-dev-base` 和 `codex-dev-remote` 分别固定dry-run。手动真实删除一次只处理所选package：

1. 在 `package_name` 选择 `codex-dev-base` 或 `codex-dev-remote`。
2. 设置 `dry_run=false`。
3. 设置较小的 `max_delete`，首次建议为1。
4. 在 `confirm` 中精确填写所选package名称。
5. 执行后到GHCR人工核对结果。

## 12. 验证命令

静态检查：

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh
./scripts/check-hardcoded.sh
./scripts/check-secrets.sh
./scripts/audit-supply-chain.sh
git diff --check
```

Compose：

```bash
docker compose config
docker compose config --volumes
docker compose -f compose.yaml -f compose.remote.yaml --profile remote config
```

本地镜像 smoke：

```bash
./scripts/smoke-image.sh <base镜像> <期望-Codex-版本> linux/amd64 <期望-mise-版本>
./scripts/smoke-remote-ssh.sh <remote镜像> <期望-Codex-版本> linux/amd64 <期望-mise-版本> <base镜像>
```

Candidate构建证明：

```bash
docker buildx imagetools inspect <镜像@digest> --format '{{json .Provenance}}'
docker buildx imagetools inspect <镜像@digest> --format '{{json .SBOM}}'
```

启用attestations后，应再次手动运行cleanup `dry_run=true`，确认新出现的untagged versions仍被保护。

原生 Linux UID/GID 验证：

```bash
./scripts/run.sh
```

容器内：

```bash
id
touch /workspace/.uid-test
stat -c '%u:%g %n' /workspace/.uid-test
rm /workspace/.uid-test
```
