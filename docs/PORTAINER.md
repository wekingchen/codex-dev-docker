# Portainer 远程 Codex 最终部署与使用指南

本文面向使用 **Portainer Standalone Docker Stack**、Windows 客户端、WinSCP 与 PuTTY 的场景。目标是在不向公网暴露容器 SSH 端口的前提下，通过宿主机现有 SSH 服务安全访问 Codex。

> 如果 Portainer Endpoint 使用 Docker Swarm，请不要直接套用本文。Swarm routing mesh、`depends_on` 和 loopback 端口发布语义不同，需要单独设计。

部署前先选择路径，不要混用两个模板：公开Codex-only使用 [`templates/portainer-stack.yaml`](../templates/portainer-stack.yaml)；owner本人使用Codex + Claude Code + 可选Xray时使用 [`templates/portainer-personal-stack.yaml`](../templates/portainer-personal-stack.yaml)，并同时完成 [`PERSONAL-DUAL-CLI.md`](PERSONAL-DUAL-CLI.md) 中的private GHCR认证、bootstrap与Xray配置步骤。

## 1. 最终架构

```text
Windows 客户端
  |
  | WinSCP/PuTTY：宿主机公网 IP:22
  v
Docker 宿主机 SSH
  |
  | SSH Tunnel 内访问宿主机 127.0.0.1:2222
  v
codex-ssh 容器:2222
  |
  +-- 用户：dev
  +-- 认证：独立公钥
  +-- workspace：/root/codex/workspace -> /workspace
  +-- home：/root/codex/dev-home -> /home/dev
  +-- host key：/root/codex/ssh-hostkeys
```

关键边界：

- 容器 SSH 端口固定发布到宿主机 `127.0.0.1`，不允许公网直连。
- 客户端先通过宿主机 SSH，再由 Tunnel 进入容器，形成两层认证。
- 容器只允许 `dev` 公钥登录，禁止 root、密码和 keyboard-interactive认证。
- 禁止 SSH Agent、TCP、Unix socket、X11和 tunnel forwarding。
- 不挂载 Docker socket、宿主机私钥或宿主根目录。
- `dev` 保留 `NOPASSWD sudo`，所以授权公钥应视为等价于该容器 root权限。

## 2. 两个镜像和两个服务的作用

### `codex-dev-remote`

Portainer 远程方案只需要：

```text
ghcr.io/wekingchen/codex-dev-remote:latest
```

该镜像已经包含完整 Codex runtime 与 OpenSSH Server，在运行时不依赖宿主机已有的 `codex-dev-base` 镜像。

### `codex-dev-base`

`codex-dev-base` 用于本地 `docker compose run`、`run.sh`、SSH Agent转发或派生开发镜像。如果这台 Portainer 宿主机只运行远程方案，可以不保留或运行 base 镜像。

### 个人私有 dual-CLI 镜像

如果本人需要在同一远程容器中任选 `codex` 或 `claude`，并可选择使用内置Xray代理，请使用私有专用模板：[`templates/portainer-personal-stack.yaml`](../templates/portainer-personal-stack.yaml)。先在Portainer Registries中添加带 `read:packages` 权限的GHCR凭据；模板中的host-key-init与主服务都使用：

```text
ghcr.io/wekingchen/codex-dev-personal-remote:latest
```

或同时固定为更稳妥的已验证根digest：

```text
ghcr.io/wekingchen/codex-dev-personal-remote@sha256:<remote-root-digest>
```

personal-remote把Xray和sshd运行在同一容器中，Xray固定以UID/GID `65532:65532` 运行；配置必须恰好包含一个 `127.0.0.1:10809` HTTP inbound，所有inbound都只能监听容器loopback，宿主机仍只发布 `127.0.0.1:2222`；代理开启时任一长期进程异常退出都会让容器整体fail closed。`XRAY_PROXY_ENABLED="true"` 启用Xray，`"false"` 完全停用；启用时配置可选择禁止任何 `freedom`、未被其他非直连规则处理的流量使用第一个非直连outbound的 `all-proxy`，或严格的 `cn-direct`（私网阻断、中国域名/IP直连、其他未匹配流量代理）。真实节点配置从宿主机 `/root/codex/xray/config.json` 只读挂载，不能写入Stack environment；专用模板在关闭模式下仍声明该bind，所以源文件必须存在。完整配置契约、目录权限和E2E见 [`PERSONAL-DUAL-CLI.md`](PERSONAL-DUAL-CLI.md)。PAT只保存在Portainer registry credential中；Claude登录保存在 `/root/codex/dev-home`。

### `codex-ssh-hostkey-init`

这是 one-shot 初始化服务，正常状态是：

```text
Exited (0)
```

首次运行时生成 Ed25519 SSH host key；后续 Stack 更新时可以安全地再次运行，它不会覆盖已有 private key，只会验证密钥、修复权限并重新派生匹配的 public key。

因此：

- 它不需要持续运行。
- 不要设置 `restart: always`。
- 建议一直保留在 Stack 中，用于新宿主机、灾难恢复、权限修复和 host-key完整性检查。

### `codex-ssh`

这是长期运行的主服务，正常状态应为：

```text
Running / Healthy
```

## 3. 宿主机目录准备

先停止旧的 base 容器或旧 Stack，避免它继续使用相同的 home/workspace。

以下命令需要 root 权限。若宿主机禁止 root SSH，请先通过普通账号登录并进入 root shell：

```bash
sudo -i
```

然后执行：

```bash
mkdir -p \
  /root/codex/workspace \
  /root/codex/dev-home \
  /root/codex/ssh \
  /root/codex/ssh-hostkeys
```

默认模板把容器开发用户映射为 UID/GID `1000:1000`：

```bash
chown -R 1000:1000 \
  /root/codex/workspace \
  /root/codex/dev-home

chmod 0750 \
  /root/codex/workspace \
  /root/codex/dev-home
```

SSH配置目录必须由root控制：

```bash
chown -R root:root \
  /root/codex/ssh \
  /root/codex/ssh-hostkeys

chmod 0700 \
  /root/codex/ssh \
  /root/codex/ssh-hostkeys
```

personal Xray模板还需要：

```bash
mkdir -p /root/codex/xray
chown root:root /root/codex/xray
chmod 0700 /root/codex/xray
# 写入配置后：
chown root:root /root/codex/xray/config.json
chmod 0600 /root/codex/xray/config.json
```

专用模板全部使用 `create_host_path:false`，所以这些目录和文件必须在Deploy/Update之前存在。模板默认 `XRAY_PROXY_ENABLED="true"`，此时 `config.json` 必须是满足安全契约且能通过 `xray run -test` 的真实配置；若先把开关设为 `"false"`，内容暂时可以不通过Xray验证，但源文件仍必须存在，例如可先创建root-only的 `{}` 占位文件。

中国分流配置不能简单添加宽泛的 `freedom`。严格 `cn-direct` 档案要求outbounds精确按 `proxy`、`direct`、`block` 排列，routing rules精确按 `geoip:private -> block`、`geosite:cn -> direct`、`geoip:cn -> direct` 排列，routing `domainStrategy`为 `IPOnDemand`，并由freedom `finalRules`再次阻断 `geoip:private`；其他未匹配流量默认使用第一个proxy。任何额外direct规则、catch-all direct、balancer或间接dialer引用都会使容器fail closed拒绝启动。完整契约见 [`PERSONAL-DUAL-CLI.md`](PERSONAL-DUAL-CLI.md)。

镜像内置geo asset已保证Xray用户可读。配置引用额外CA、证书、私钥或自定义geo asset时，必须单独只读挂载并让UID/GID 65532具有最小读取/目录遍历权限；秘密文件可使用 `root:65532 0640`，不要把整个root-only配置目录改为全局可读。

如果宿主机实际使用其他非零 UID/GID，应同时修改目录所有权和 Stack 中的：

```yaml
HOST_UID: "1000"
HOST_GID: "1000"
```

禁止把它们设置为 `0`。personal-remote还保留 `65532:65532` 给Xray，因此personal Stack的 `HOST_UID` 或 `HOST_GID` 任一值也不得为65532，否则容器会fail closed拒绝启动。镜像不会递归修改 `/workspace` 的宿主机所有权，所以 workspace 必须提前可写。

## 4. 使用 PuTTYgen 准备容器登录密钥

推荐为容器单独生成 Ed25519 密钥。也可以使用至少3072位的 RSA 密钥，但应使用新版 PuTTY，使其采用 `rsa-sha2-256` 或 `rsa-sha2-512`，不要在服务器端重新启用 RSA/SHA-1。

### 4.1 私钥

PuTTYgen 保存的：

```text
codex_remote_ed25519.ppk
```

是客户端私钥，只能保存在 Windows 客户端。绝不能上传到宿主机、Portainer、容器或仓库。

### 4.2 公钥

在 PuTTYgen 加载 `.ppk` 后，复制顶部文本框：

```text
Public key for pasting into OpenSSH authorized_keys file
```

需要的是一整行：

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... codex-remote
```

或者现代 RSA：

```text
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... codex-remote
```

以下格式不能部署：

```text
PuTTY-User-Key-File-3: ...
<任何 BEGIN ... PRIVATE KEY 私钥头>
---- BEGIN SSH2 PUBLIC KEY ----
example.com ssh-ed25519 AAAA...
```

当前校验器只接受不带 `authorized_keys` options 的标准裸OpenSSH公钥行。

### 4.3 写入宿主机

通过 PuTTY 登录宿主机后执行：

```bash
cat > /root/codex/ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... codex-remote
EOF

chown root:root /root/codex/ssh/authorized_keys
chmod 0600 /root/codex/ssh/authorized_keys
```

将示例公钥替换为 PuTTYgen 中复制的完整一行。

验证：

```bash
ssh-keygen -l -E sha256 \
  -f /root/codex/ssh/authorized_keys
```

如果需要授权多台客户端，把每台客户端的裸公钥逐行写入同一个文件。更新时不要遗漏已有公钥，因为该文件就是完整授权集合。

### 4.4 让公钥变更生效

`codex-ssh` 启动时会校验输入文件，并把它复制成容器内 root-owned 的运行时文件。直接修改宿主机文件不会自动刷新正在运行的 sshd。

添加公钥后，至少应重启主服务：

```bash
docker restart codex-ssh
docker logs --tail=100 codex-ssh
```

撤销疑似泄露的公钥时，应先停止服务以立即阻断新登录，再原地重写完整授权集合并启动：

```bash
docker stop codex-ssh
cat > /root/codex/ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... remaining-authorized-key
EOF
chown root:root /root/codex/ssh/authorized_keys
chmod 0600 /root/codex/ssh/authorized_keys
docker start codex-ssh
```

随后验证保留的密钥可以登录、已撤销的密钥无法登录。若公钥文件曾被编辑器以“写入新文件再重命名”的方式替换，文件bind mount可能仍指向旧inode；此时必须在Portainer中明确 **Recreate/force recreate** `codex-ssh`，普通restart或YAML未变化的普通Update Stack都不能证明已切换到新inode。

## 5. 最终 Portainer Stack

以下服务配置与公开 [`templates/portainer-stack.yaml`](../templates/portainer-stack.yaml) 等效，可直接粘贴到 Portainer Stack Editor；仓库模板额外保留了操作提示注释。personal用户不要在这段公开YAML上零散添加Xray字段，应直接使用完整的 [`templates/portainer-personal-stack.yaml`](../templates/portainer-personal-stack.yaml)。

```yaml
services:
  codex-ssh-hostkey-init:
    container_name: codex-ssh-hostkey-init
    image: ghcr.io/wekingchen/codex-dev-remote:latest
    pull_policy: always
    entrypoint:
      - /usr/local/bin/remote-hostkey-init.sh
    network_mode: none
    restart: "no"
    volumes:
      - type: bind
        source: /root/codex/ssh-hostkeys
        target: /etc/ssh/codex-host-keys
        bind:
          create_host_path: false
    cap_drop:
      - NET_BIND_SERVICE
      - NET_RAW

  codex-ssh:
    container_name: codex-ssh
    image: ghcr.io/wekingchen/codex-dev-remote:latest
    pull_policy: always
    depends_on:
      codex-ssh-hostkey-init:
        condition: service_completed_successfully
    working_dir: /workspace
    init: true
    restart: unless-stopped
    pids_limit: 256
    stop_grace_period: 20s
    ports:
      - "127.0.0.1:2222:2222"
    volumes:
      - type: bind
        source: /root/codex/workspace
        target: /workspace
        bind:
          create_host_path: false
      - type: bind
        source: /root/codex/dev-home
        target: /home/dev
        bind:
          create_host_path: false
      - type: bind
        source: /root/codex/ssh-hostkeys
        target: /etc/ssh/codex-host-keys
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: /root/codex/ssh/authorized_keys
        target: /etc/codex-ssh/authorized_keys.input
        read_only: true
        bind:
          create_host_path: false
    environment:
      CODEX_HOME: /home/dev/.codex
      MISE_DATA_DIR: /home/dev/.local/share/mise
      MISE_CONFIG_DIR: /home/dev/.config/mise
      HOST_UID: "1000"
      HOST_GID: "1000"
    tmpfs:
      - /run:rw,nosuid,nodev,size=16m,mode=0755
      - /tmp:rw,nosuid,nodev,size=256m,mode=1777
    cap_drop:
      - NET_BIND_SERVICE
      - NET_RAW
    healthcheck:
      test:
        - CMD-SHELL
        - nc -z 127.0.0.1 2222
      interval: 5s
      timeout: 3s
      retries: 12
      start_period: 10s
    networks:
      - codex-remote

networks:
  codex-remote:
    driver: bridge
```

### `pull_policy` 兼容性

如果 Portainer 版本不支持：

```yaml
pull_policy: always
```

可以删除这两行，并在每次更新 Stack 时勾选 `Re-pull image` 或 `Pull latest image`。

不要把 `CODEX_DEV_PULL_POLICY` 写进 `environment`。它是本仓库 Compose 包装配置，不是容器运行环境变量。

## 6. Portainer 首次部署

1. 停止并删除旧的 base `codex` 容器或旧 Stack服务。
2. 确认第3至第4节中的workspace、dev-home、SSH目录、host key目录和 `authorized_keys` 均已创建且权限正确。
3. 选择一个完整模板：公开Codex-only使用 `templates/portainer-stack.yaml`；personal双CLI/Xray使用 `templates/portainer-personal-stack.yaml`，并确认Portainer已配置private GHCR credential及Xray源文件。
4. 核对所有 `create_host_path:false` 的bind源都已存在；personal模板还要确认 `HOST_UID/HOST_GID` 不是0或65532，且宿主端口仍只有 `127.0.0.1:2222:2222`。
5. 打开 Portainer → `Stacks` → 新建或编辑 Stack，粘贴所选模板的完整内容。
6. 勾选重新拉取镜像。
7. 点击 `Deploy the stack` 或 `Update the stack`。

部署结果：

```text
codex-ssh-hostkey-init → Exited (0)
codex-ssh              → Running / Healthy
```

查看日志：

```bash
docker logs codex-ssh-hostkey-init
docker logs --tail=200 codex-ssh
```

检查健康状态：

```bash
docker inspect codex-ssh \
  --format '{{.State.Status}} {{.State.Health.Status}}'
```

预期：

```text
running healthy
```

## 7. 确认端口没有暴露到公网

在宿主机执行：

```bash
ss -lntp | grep ':2222'
```

必须看到：

```text
127.0.0.1:2222
```

不能看到：

```text
0.0.0.0:2222
[::]:2222
```

不要在路由器、防火墙或云安全组中开放 `2222`。personal模式的10809只能存在于容器loopback；`docker inspect codex-ssh --format '{{json .NetworkSettings.Ports}}'` 不得显示10809宿主映射，宿主 `ss -lntp` 也不应出现由该Stack发布的10809监听。

## 8. 获取并核对容器 host fingerprint

查看 fingerprint：

```bash
docker exec codex-ssh \
  ssh-keygen -l -E sha256 \
  -f /etc/ssh/codex-host-keys/ssh_host_ed25519_key.pub
```

查看原始 public key：

```bash
docker exec codex-ssh \
  cat /etc/ssh/codex-host-keys/ssh_host_ed25519_key.pub
```

第一次连接时，WinSCP/PuTTY 显示的容器 fingerprint 必须与这里一致。宿主机 fingerprint 和容器 fingerprint 是两把不同的服务器密钥，首次使用 Tunnel 时可能先后看到两次确认。

## 9. WinSCP 内置 SSH Tunnel 配置

你不需要从公网直接连接 `127.0.0.1`。WinSCP 会先连接宿主机公网 IP，再从宿主机内部访问它自己的 `127.0.0.1:2222`。

### 9.1 主连接

WinSCP → `New Site`：

| 设置 | 值 |
|---|---|
| File protocol | `SFTP` |
| Host name | `127.0.0.1` |
| Port number | `2222` |
| User name | `dev` |
| Password | 留空 |

进入 `Advanced` → `SSH` → `Authentication`，在 `Private key file` 选择容器专用：

```text
codex_remote_ed25519.ppk
```

如果使用 RSA，则选择对应的 RSA `.ppk`。

### 9.2 Tunnel

进入 `Advanced` → `Connection` → `Tunnel`，启用：

```text
Connect through SSH tunnel
```

填写平时登录宿主机的信息：

| 设置 | 值 |
|---|---|
| Host name | 宿主机公网 IP 或域名 |
| Port number | `22`，或宿主机实际 SSH 端口 |
| User name | 宿主机 SSH 用户 |
| Private key file | 平时登录宿主机使用的 `.ppk` |

最终关系：

```text
主连接密钥  = Codex 容器专用 .ppk
Tunnel 密钥 = 宿主机登录 .ppk
```

如果两层使用同一把密钥也能工作，但独立密钥更容易单独撤销。

保存站点后点击登录，WinSCP 会自动完成两层连接。

### 9.3 文件目录

WinSCP 登录容器后进入：

```text
/workspace
```

它对应宿主机：

```text
/root/codex/workspace
```

## 10. 使用 PuTTY 进入 Codex 终端

WinSCP 连接成功后使用：

```text
Commands → Open in PuTTY
```

进入终端后验证：

```bash
whoami
id
pwd
echo "$CODEX_HOME"
codex --version
mise --version
sudo -n true
```

如果Stack使用personal双CLI镜像，再执行：

```bash
claude --version
```

预期：

```text
whoami      → dev
pwd         → /home/dev
CODEX_HOME  → /home/dev/.codex
sudo        → 成功
```

SSH 登录会话按系统规则从用户 home `/home/dev` 开始；Compose 的 `working_dir` 只影响容器主进程，不会改变 sshd 登录目录。进入项目后再切换到 workspace。

### Portainer root Console不是SSH `dev` 会话

Portainer的Container Console通常打开容器root的普通非-login shell。它不经过sshd `SetEnv`，也不会自动加载 `/etc/profile.d`，因此personal模式下直接查看 `HTTP_PROXY`/`HTTPS_PROXY` 可能为空；这不代表Xray没有生效。不要在root Console中直接运行日常Codex/Claude Code或修改workspace/home，否则容易创建root-owned文件并得到与真实SSH会话不同的环境。

真实CLI验证应通过PuTTY/SSH登录 `dev`。如必须从Portainer Console进入开发login shell，可执行：

```bash
exec gosu dev env \
  HOME=/home/dev \
  USER=dev \
  LOGNAME=dev \
  bash -l
```

随后确认 `whoami` 为 `dev`。若只想临时诊断root login-shell的动态代理环境，可执行 `bash -lc 'env | grep -i proxy'` 或显式加载 `. /run/codex-proxy/env.sh`，但不要把root Console结果当作SSH `dev` E2E的替代。

推荐使用 tmux：

```bash
cd /workspace
tmux new-session -A -s codex
codex
```

容器不重建时，网络断开后可以重新进入同一个 tmux session。镜像更新会重建容器，因此容器内的 tmux 进程会结束，更新前应保存工作。

## 11. 更简单的宿主机进入方式

如果只想继续用 WinSCP 管理宿主机文件，也可以不让 WinSCP直接登录容器。默认模板位于 `/root/codex`，所以此替代方式只适用于能够访问 `/root` 的宿主机账号；普通 `ubuntu`、`admin` 等账号即使拥有 sudo，SFTP 也通常无法直接浏览 `/root`。

满足该权限前提时：

1. WinSCP 继续连接宿主机公网 IP。
2. 直接管理 `/root/codex/workspace`。
3. PuTTY 登录宿主机并通过 `sudo -i` 进入 root shell后运行：

```bash
docker exec -it \
  --user dev \
  --workdir /workspace \
  codex-ssh \
  bash -l
```

然后执行：

```bash
codex
```

这种方式不需要 WinSCP Tunnel，但容器 SSH 服务仍可作为备用入口。若必须让普通宿主机账号直接用 SFTP 管理 workspace，建议把全部 bind mount 根目录迁移到 `/srv/codex`，再按最小权限设置父目录和 workspace 所有权，并同步修改 Stack 中的四个 `source` 路径；不要为了访问方便放宽整个 `/root` 的权限。

## 12. 日常更新远程 Codex

Portainer中的操作不能混用：**Restart**只重启现有容器，不拉取新镜像，也不应用新的environment或bind定义；**Re-pull/Pull latest**只取得标签当前镜像；**Update Stack**只在检测到Stack定义或镜像变化时重建受影响服务；**Recreate/force recreate**则无论YAML是否变化都生成新容器。更新 `:latest` 必须重新拉取并更新整个Stack；原子替换bind源文件时必须force recreate。

### 12.1 更新前

1. 打开项目 GitHub Actions，确认最新双镜像发布成功：
   <https://github.com/wekingchen/codex-dev-docker/actions>
2. 保存并提交重要项目改动。
3. 在重新拉取前记录**当前运行镜像**的 repository digest：

   ```bash
   running_image_id="$(docker inspect codex-ssh --format '{{.Image}}')"
   docker image inspect "$running_image_id" \
     --format '{{json .RepoDigests}}'
   ```

   在输出中保存这一项：

   ```text
   ghcr.io/wekingchen/codex-dev-remote@sha256:<当前-digest>
   ```

   这是可靠的回滚点。若 `RepoDigests` 为空，不要继续更新；应先从最初部署对应的成功 GitHub Actions run或 GHCR版本页面取得并记录已验证digest。
4. 停止容器内正在运行的 Codex、tmux、构建或安装任务。

### 12.2 Portainer 更新

Portainer → `Stacks` → 当前 Stack → `Editor`：

1. 保持两个服务均使用：

   ```text
   ghcr.io/wekingchen/codex-dev-remote:latest
   ```

2. 勾选 `Re-pull image` 或 `Pull latest image`。
3. 点击 `Update the stack`，完整重建该Stack；不要只在Containers页面重建单个 `codex-ssh`。
4. 等待 `codex-ssh-hostkey-init` 再次正常退出，并确认 `codex-ssh` 变为 `Healthy`。

如果 Portainer 没有重新拉取，可以先在宿主机执行：

```bash
docker pull ghcr.io/wekingchen/codex-dev-remote:latest
```

再回到 Portainer 重新部署。单纯点击 `Restart` 不会切换到新镜像。

personal双CLI Stack使用相同流程，但镜像名应为 `codex-dev-personal-remote`，并先确认最新private workflow已成功。Portainer必须继续使用已配置的GHCR private registry credential。切换 `XRAY_PROXY_ENABLED` 或修改volume定义时应Update整个Stack，配置差异会触发重建。仅替换Xray配置内容时则应明确执行可保证生成新容器的 **Recreate/force recreate**：编辑器或WinSCP常以“写新文件再rename”方式保存，bind源inode会变化，而普通Restart或YAML未变化的普通Update Stack可能继续引用旧文件。操作后核对容器ID或创建时间已变化，再检查runtime配置与healthcheck。

### 12.3 更新后验证

```bash
docker inspect codex-ssh \
  --format '{{.State.Status}} {{.State.Health.Status}}'

docker exec --user dev codex-ssh codex --version
docker exec --user dev codex-ssh mise --version
# personal双CLI Stack执行：
docker exec --user dev codex-ssh bash -lc 'claude --version'
docker exec codex-ssh xray version
docker exec codex-ssh /usr/local/bin/personal-remote-healthcheck.sh
# 仅XRAY_PROXY_ENABLED=true时执行以下权限检查：
docker exec codex-ssh stat -c '%U:%G %a %n' /run/xray/config.json
docker exec codex-ssh gosu xray:xray test -r /usr/local/share/xray/geoip.dat
docker exec codex-ssh gosu xray:xray test -r /usr/local/share/xray/geosite.dat
```

开启Xray时，runtime配置应显示 `root:xray 640`，两个geo asset读取检查应成功。

更新不会删除：

```text
/root/codex/workspace
/root/codex/dev-home
/root/codex/ssh/authorized_keys
/root/codex/ssh-hostkeys
/root/codex/xray/config.json（personal Stack）
```

镜像更新或回滚不会自动回滚Xray节点配置，应单独备份并记录其版本。SSH host fingerprint也不应改变。如果 WinSCP突然报告host key变化，不要直接接受，应检查 `/root/codex/ssh-hostkeys` 是否被删除、替换或挂载到了错误路径。

## 13. 回滚镜像

可靠回滚必须使用更新前记录的 repository digest。把两个服务的镜像同时改为：

```yaml
image: ghcr.io/wekingchen/codex-dev-remote@sha256:<已知正常-digest>
```

personal Stack应把两处同时固定为同一个已知正常的 `ghcr.io/wekingchen/codex-dev-personal-remote@sha256:<digest>`。然后勾选重新拉取并重新部署整个Stack。digest是OCI内容地址，不会被同名标签移动；重新部署后，workspace、home、授权公钥、host fingerprint和宿主Xray配置仍会保留，但镜像回滚不会回滚Xray配置本身。

正式发布也会生成短 commit 标签：

```text
ghcr.io/wekingchen/codex-dev-remote:<短-commit>
```

但该项目会在仓库 commit 不变时继续跟踪新的 Codex official latest，定时发布可能让同一个短 commit 标签指向新镜像。因此短 commit 标签只能用于定位源码版本，**不能视为不可变回滚点**。

回滚验证完成后，可以继续保持digest pin以获得可重复部署；需要再次跟踪最新版本时，再把两个服务一起改回 `:latest` 并按第12节完整执行更新流程。

## 14. Host key 的保存与轮换

普通镜像更新、容器重建和home重置都不应删除：

```text
/root/codex/ssh-hostkeys
```

只有在private key疑似泄露或明确需要更换服务器identity时才轮换。Portainer bind-mount方案应先停止 Stack并备份整个目录：

```bash
cp -a \
  /root/codex/ssh-hostkeys \
  "/root/codex/ssh-hostkeys.backup.$(date -u +%Y%m%dT%H%M%SZ)"
```

然后删除旧的 `ssh_host_ed25519_key` 和 `.pub`，重新部署 Stack，让 init服务生成新密钥。轮换后必须：

1. 通过宿主机可信会话重新读取fingerprint。
2. 删除客户端缓存的旧容器host key。
3. 只在新fingerprint核对一致后接受。

如果轮换部署失败，应立即从备份恢复旧目录，不要让客户端在identity不明确时继续连接。

## 15. 常见问题

### `codex-ssh-hostkey-init` 显示 Exited

`Exited (0)` 是成功，不是故障。它不应长期运行。

### `codex-ssh` 无法启动

查看：

```bash
docker logs codex-ssh-hostkey-init
docker logs --tail=200 codex-ssh
```

常见原因：

- `/root/codex/ssh/authorized_keys` 不存在或格式错误。
- workspace/home/host-key目录未提前创建。
- `HOST_UID/HOST_GID` 与宿主机目录所有权不一致，或personal模式误用了保留值65532。
- personal模板的 `/root/codex/xray/config.json` 源文件不存在；即使开关为 `false`，Docker也会先解析bind mount。
- Xray配置权限不是root-only，或 `cn-direct` 的outbound/routing顺序和内容不符合严格契约。
- `2222` 已被其他宿主机进程占用。

### WinSCP 无法连接 `127.0.0.1`

确认 WinSCP 的 Tunnel 页面已经启用 `Connect through SSH tunnel`。主连接的 `127.0.0.1` 是从宿主机视角访问，不是让公网直接访问客户端本机。

还要确认宿主机SSH允许TCP forwarding。若宿主机配置了 `AllowTcpForwarding no`，WinSCP Tunnel不能工作。

### 公钥被拒绝

公钥文件必须是一行标准格式：

```text
ssh-ed25519 AAAA... comment
```

或：

```text
ssh-rsa AAAA... comment
```

不要上传 `.ppk`，不要使用RFC4716 `BEGIN SSH2 PUBLIC KEY` 格式，也不要在公钥前添加host name。

### 更新后 Codex 版本没变化

说明 Portainer可能只重启了旧容器而没有重新拉取镜像。执行：

```bash
docker pull ghcr.io/wekingchen/codex-dev-remote:latest
```

然后在 Portainer 中重新部署整个 Stack。

### 想切回本地 base 模式

远程容器和本地容器不应同时操作相同home/workspace。先停止Portainer Stack中的 `codex-ssh`，再启动本地base容器。

## 16. 安全检查清单

部署完成后逐项确认：

- [ ] `codex-ssh-hostkey-init` 为 `Exited (0)`。
- [ ] `codex-ssh` 为 `Running / Healthy`。
- [ ] 宿主机只监听 `127.0.0.1:2222`。
- [ ] 防火墙、路由器和云安全组没有开放 `2222`。
- [ ] `.ppk` 私钥只保存在Windows客户端。
- [ ] 宿主机只保存公钥 `authorized_keys`。
- [ ] 每次公钥添加或撤销后都已 restart/recreate主服务并验证结果。
- [ ] WinSCP Tunnel使用宿主机SSH凭据。
- [ ] WinSCP主连接使用容器专用凭据。
- [ ] 首次连接已核对容器host fingerprint。
- [ ] workspace与dev-home由非零UID/GID拥有；personal模式没有使用保留值65532。
- [ ] Stack没有挂载Docker socket、宿主私钥或宿主根目录。
- [ ] personal模板的Xray bind源文件存在，即使当前开关为 `false`。
- [ ] personal代理开启时，Xray源配置为root-only且不是符号链接，runtime副本为 `root:xray 0640`，进程以UID/GID 65532运行。
- [ ] personal代理开启时，所有inbound只监听容器loopback，宿主机没有10809映射；Xray或sshd任一异常退出会让容器整体失败。
- [ ] 使用 `cn-direct` 时，私网已阻断、中国域名/IP直连、其他未匹配流量代理，且没有额外direct规则或balancer。
- [ ] `XRAY_PROXY_ENABLED` 只使用严格的 `"true"` 或 `"false"`，切换后已Update整个Stack/Recreate并验证对应出口。
- [ ] 已知Portainer root Console普通非-login shell没有动态代理变量属于正常现象；真实CLI E2E通过SSH `dev` 会话完成。
- [ ] 每次更新前都已记录当前运行镜像的 repository digest。
- [ ] 更新镜像时两个服务保持同一引用，并使用Re-pull后Update整个Stack，而不是仅Restart。
