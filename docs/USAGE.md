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

## 6. SSH Agent

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

## 7. Linux UID/GID

原生 Linux 上，包装脚本自动传递宿主用户的 UID/GID。entrypoint 会：

1. 要求 `HOST_UID`、`HOST_GID` 同时存在且为非零整数。
2. 安全复用已存在的目标 GID。
3. 如果目标 UID 被其他用户占用则停止启动。
4. 调整 `dev` 用户身份。
5. 只递归修复 `/home/dev`。
6. 通过 `gosu dev` 执行用户命令。

它不会修改 `/workspace` 的宿主机所有权。macOS/Windows 默认不启用自动 UID/GID 重映射。

## 8. 第一次登录和项目依赖

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

## 9. GitHub Actions 发布

PR 只运行静态检查和双架构构建/smoke，不登录或推送 GHCR。

受信任事件先发布：

```text
candidate-<run-id>-<run-attempt>
```

验证通过且官方 latest 未变化后，再提升为：

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

为避免在旧 commit 上补打版本 tag 时回退 `latest`，tag 构建不会移动 `latest`。手动 workflow 的 `promote` 默认为 `false`，适合先演练完整 candidate 流程。

## 10. GHCR 安全清理

清理 workflow 会：

- 根据 owner 类型选择 User 或 Organization API。
- 分页读取超过 100 个版本。
- 保护 latest、semver、未知标签和 untagged/referrer。
- 只清理旧 candidate、日期和 commit 临时标签。
- 保留最近 10 个临时版本。
- 限制单次删除数量，硬上限为 10。

每周 schedule 当前固定 dry-run。手动真实删除时：

1. 设置 `dry_run=false`。
2. 设置较小的 `max_delete`，首次建议为 1。
3. 在 `confirm` 中精确填写 `codex-dev-base`。
4. 执行后到 GHCR 人工核对结果。

## 11. 验证命令

静态检查：

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh
./scripts/check-hardcoded.sh
git diff --check
```

Compose：

```bash
docker compose config
docker compose config --volumes
```

本地镜像 smoke：

```bash
./scripts/smoke-image.sh <镜像引用> <期望-Codex-版本> linux/amd64
```

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
