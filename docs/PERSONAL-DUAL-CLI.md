# 个人私有 Codex + Claude Code 双 CLI 镜像

本文说明如何在不改变公开 Codex 镜像的前提下，使用本人专属的私有 GHCR 镜像，在同一个容器中按需运行：

```text
codex
claude
```

公开镜像和公开 Portainer 模板仍然只包含 Codex：

```text
ghcr.io/wekingchen/codex-dev-base
ghcr.io/wekingchen/codex-dev-remote
```

私有派生镜像为：

```text
ghcr.io/wekingchen/codex-dev-personal-base
ghcr.io/wekingchen/codex-dev-personal-remote
```

> GHCR visibility 是 package 级，不是 tag 级。不能在公开 package 中创建所谓“私有 tag”；Claude Code 必须放在独立的 private package 中。

## 1. 架构与状态目录

私有镜像从同一次公开发布的不可变 base/remote 根 digest 派生，再加入经过官方签名 manifest 和 SHA-256 验证的 Claude Code native binary。`personal-remote` 还会在每次 workflow 中解析 XTLS/Xray-core 发布时间最新的非draft release（包含prerelease），把它固定为本次构建的exact tag、双架构asset digest和size后安装；`personal-base`不包含Xray。

```text
公开 codex-dev-base@sha256:...
  └── codex-dev-personal-base

公开 codex-dev-remote@sha256:...
  └── codex-dev-personal-remote
      ├── claude
      └── xray（运行时可开关）
```

容器结构不变：

- workspace：`/workspace`
- 共享 home：`/home/dev`
- Codex 状态：`/home/dev/.codex`
- Claude Code主要状态：`/home/dev/.claude`
- Claude Code其他用户状态：`/home/dev/.claude.json`

不增加第二个 Compose service、第二个 SSH 端口或第二个 home volume。`personal-remote`在同一个容器内按开关运行Xray与sshd；Xray固定以UID/GID `65532:65532` 运行；配置必须恰好包含一个容器 `127.0.0.1:10809` HTTP inbound，所有inbound都只能监听loopback，且不发布宿主端口。代理开启时，Xray或sshd任一异常退出都会停止另一个进程并使容器fail closed退出。两个 CLI 共享 Git、mise、shell配置、项目文件和缓存，但认证目录彼此独立。

私有镜像设置：

```text
DISABLE_AUTOUPDATER=1
DISABLE_UPDATES=1
```

Claude Code版本由镜像发布链管理，不能在运行容器中自行升级。升级时重新构建并拉取新的私有镜像。

## 2. Claude Code供应链验证

构建流程不执行：

```text
curl ... | bash
bootstrap.sh
```

而是：

1. 解析官方 `latest` 为精确版本。
2. 下载该版本的 `manifest.json` 和 `manifest.json.sig`。
3. 核对 Anthropic release key指纹：

   ```text
   31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE
   ```

4. 验证 detached GPG signature。
5. 从已验签 manifest读取 `linux-x64`、`linux-arm64` checksum和size。
6. 下载精确平台的 `claude` binary并再次核对SHA-256和size。
7. 安装为root-owned `0755` 的 `/usr/local/bin/claude`。
8. 双架构分别执行本地和registry smoke、provenance、SBOM与Trivy检查。
9. promotion前重新确认公开父digest、Claude latest/signature和private visibility均未漂移。

构建选择官方 `latest`；`stable` 只作为证据记录，不参与版本选择。为保证存在可验证的签名manifest，当前供应链门禁还要求解析出的Claude Code版本不低于 `2.1.89`。

### Xray latest供应链

Xray不是按固定版本长期构建，也不直接使用浮动 `latest` tag。每次personal workflow会：

1. 查询 `XTLS/Xray-core` releases API列表。
2. 选择 `draft=false` 且 `published_at` 最新的release，包含官方标记为prerelease的版本。
3. 从该exact tag读取 `Xray-linux-64.zip`、`Xray-linux-arm64-v8a.zip` 的GitHub asset SHA-256与size。
4. 交叉检查同名 `.dgst`，再由Docker构建层下载exact URL并核对SHA-256与size。
5. promotion前重新解析最新release；构建期间如出现更新版本，本次candidate不移动正式标签。

Xray release没有独立的binary detached signature；`.dgst`只是同一release中的哈希清单。发布证据会如实记录这一信任边界，不能把它描述为“已验签”。文档不固定某个历史tag；部署或审计前可运行 `./scripts/audit-xray-private-supply-chain.sh --resolve-only` 查看当前workflow将固定的exact release、asset digest和size。

## 3. 一次性准备 GitHub Secrets

在仓库：

```text
Settings → Secrets and variables → Actions
```

创建：

### `GHCR_PRIVATE_PUBLISH_TOKEN`

用途：由private workflow登录GHCR、推送candidate、拉取验证并移动正式标签。必须使用owner本人账号的classic PAT，并至少授予：

```text
read:packages
write:packages
```

private workflow刻意不使用公开仓库的 `GITHUB_TOKEN`，也会清空继承自公开父镜像的 `org.opencontainers.image.source` label，避免personal package自动关联公开repository并继承其访问权限。

### `GHCR_PRIVATE_GUARD_TOKEN`

用途：只读查询本人GHCR package metadata并确认：

```json
{
  "visibility": "private",
  "repository": null
}
```

建议使用本人账号的classic PAT，最小权限为：

```text
read:packages
```

workflow会先查询 `/user`，要求token持有人与仓库owner一致，并拒绝任何已关联repository的package。private但关联public repository仍可能继承额外访问权限，因此不满足owner-only边界。

GitHub当前API不能完整枚举Package Settings中的显式用户授权和Manage Actions access。自动门禁只能证明private、owner匹配且没有linked repository；owner仍须人工保持两类ACL为空。该限制会在供应链审计中明确提示，不能把自动检查视为完整的owner-only密码学证明。

### `GHCR_PRIVATE_CLEANUP_TOKEN`（可选）

只有将来手动真正删除未提升candidate时才需要。使用单独classic PAT，并授予 `read:packages` 与 `delete:packages`。日常构建、visibility检查和定时cleanup dry-run不需要该token。

不要把任何PAT写入：

- `.env`
- Dockerfile
- Portainer Stack YAML
- build args或OCI labels

## 4. 首次建立 private package

首次不能直接推送含Claude的镜像。先运行：

```text
Actions → 构建私有 Codex + Claude + Xray personal 镜像 → Run workflow
mode: bootstrap
promote: false
```

bootstrap只推送不含Codex、Claude或文件层的scratch visibility probe：

```text
codex-dev-personal-base:visibility-probe
codex-dev-personal-remote:visibility-probe
```

workflow随后使用guard token确认两个package均为private且API没有返回linked repository。

还应人工复核：

1. GitHub个人主页 → Packages。
2. 打开两个personal package。
3. 确认 Visibility 为 `Private`。
4. 确认没有连接/继承公开 `codex-dev-docker` repository的权限。
5. Package的Actions access中不要授予public repository或其他repository访问权。
6. 未登录GHCR时尝试pull应失败。
7. 使用非owner账号或fork workflow也不应能够pull。

如果package被错误设为public或关联到公开repository，不要推送Claude镜像。移除关联与继承权限后重新运行bootstrap检查；若package已经公开，通常不能恢复为private，应删除probe package或改用新package名称重新bootstrap。

## 5. 首次构建 private candidate

公开父镜像必须先通过新版公开workflow发布一次，使base与remote都带有相同的：

```text
io.codex-dev.release-set
org.opencontainers.image.revision
```

然后手动运行private workflow：

```text
mode: build
promote: false
```

这次只生成并验证candidate，不移动 `latest`。确认以下job成功：

- 公开父base/remote digest配对。
- Claude exact manifest验签。
- amd64/arm64本地base与remote smoke。
- 两个private candidate push。
- registry digest双架构smoke。
- provenance/SBOM和关键labels验证。
- Trivy报告。
- candidate发布证据artifact。

验证完成后，再运行：

```text
mode: build
promote: true
```

正式标签只会从已验证candidate根digest创建：

```text
latest
YYYYMMDD
<短-commit>
```

每日UTC 06:17定时任务会在公开构建之后自动执行并promotion。若公开父镜像、Claude latest或package visibility在构建期间变化，本次candidate保留，但不会移动正式标签。

GHCR不支持跨package事务。极少数情况下base标签可能已移动而remote失败；release evidence会使用本次workflow开始时固定的UTC日期重新查询两个package，并分别记录 `promoted`、`partial`、`unchanged`、`blocked`、`not-requested` 或 `unknown`。失败run不能视为有效发布，应按证据检查并统一回滚或重跑。

private cleanup只删除保留数量之外、仍然只有 `candidate-...` 标签的未提升candidate。带有日期或commit正式标签的历史版本永久保护，可继续作为digest回滚点；全部untagged平台manifest和attestations也继续保护。

## 6. 本地使用

复制公开示例后，只在不受Git跟踪的 `.env` 中覆盖镜像：

```dotenv
CODEX_DEV_IMAGE=ghcr.io/wekingchen/codex-dev-personal-base:latest
CODEX_REMOTE_IMAGE=ghcr.io/wekingchen/codex-dev-personal-remote:latest
```

先登录私有GHCR：

```bash
echo "$GHCR_READ_TOKEN" | docker login ghcr.io -u wekingchen --password-stdin
```

`GHCR_READ_TOKEN` 使用只读 `read:packages` PAT。不要把token写入 `.env`。

使用：

```bash
./scripts/run.sh
./scripts/run.sh codex
./scripts/run.sh claude
./scripts/run.sh claude --version
```

无参数仍进入Bash；有参数时会原样传给容器，因此也可以运行：

```bash
./scripts/run.sh bash -lc 'codex --version && claude --version'
```

## 7. 首次登录 Claude Code

进入私有容器后运行：

```bash
claude
```

按终端提示完成登录。远程或无浏览器环境通常会显示授权URL；在本地浏览器打开并把授权结果返回终端即可。

登录状态保存在home volume中，不进入镜像。可以检查：

```bash
claude auth status --text
```

不要把以下值写入仓库或普通Portainer environment：

```text
ANTHROPIC_API_KEY
ANTHROPIC_AUTH_TOKEN
CLAUDE_CODE_OAUTH_TOKEN
```

## 8. Remote SSH使用

`.env` 指向private remote后，现有远程管理方式不变：

```bash
./scripts/remote.sh update
ssh codex
cd /workspace
```

stock `compose.remote.yaml`/`scripts/remote.sh` 只会把远程服务切换为personal双CLI镜像；它们没有挂载 `/etc/xray/config.json`，也没有传入 `XRAY_PROXY_ENABLED`，因此Xray保持默认关闭。仅在 `.env` 中增加该变量不会自动注入容器。仓库提供的完整Xray接入路径是下一节的 `templates/portainer-personal-stack.yaml`。

登录后任选：

```bash
codex
claude
```

仍然只有一个 `codex-ssh` 服务和一个loopback端口。原有key-only登录、host fingerprint、禁止forwarding、共享home锁和`NOPASSWD sudo`边界不变。

## 9. Portainer拉取 private GHCR

本节补充private GHCR和Xray配置，不替代 [`PORTAINER.md`](PORTAINER.md) 的首次部署步骤。部署personal Stack前，必须先按该文档准备 `/root/codex/workspace`、`/root/codex/dev-home`、SSH目录、`authorized_keys` 和持久化host key目录；personal路径还要完成本节的registry credential与Xray源文件准备。专用模板全部使用 `create_host_path:false`，任何缺失的bind源都会在entrypoint启动前导致部署失败。

在Portainer中添加registry：

```text
Registries → Add registry → Custom registry
```

填写：

| 项目 | 值 |
|---|---|
| Registry URL | `ghcr.io` |
| Username | `wekingchen` |
| Password/Token | Portainer专用classic PAT，至少`read:packages` |

如果账号或组织启用了SSO，还需为PAT完成SSO授权。

不要修改仓库公开模板。直接复制私有专用模板：

```text
templates/portainer-personal-stack.yaml
```

其中 `codex-ssh-hostkey-init` 与 `codex-ssh` 已同时使用：

```yaml
image: ghcr.io/wekingchen/codex-dev-personal-remote:latest
```

更可重复的部署应把两处同时固定为同一个已验证remote根digest：

```yaml
image: ghcr.io/wekingchen/codex-dev-personal-remote@sha256:<remote-root-digest>
```

模板中的 `HOST_UID`/`HOST_GID` 必须与宿主workspace和dev-home的实际所有者一致，均不得为0；personal-remote还保留 `65532:65532` 给Xray，因此任一值也不得使用65532，否则容器会fail closed拒绝启动。

### Xray宿主配置

先在Docker宿主机准备root-only目录：

```bash
mkdir -p /root/codex/xray
chown root:root /root/codex/xray
chmod 0700 /root/codex/xray
```

将真实Xray JSON配置保存为：

```text
/root/codex/xray/config.json
```

并设置：

```bash
chown root:root /root/codex/xray/config.json
chmod 0600 /root/codex/xray/config.json
```

`root:root 0600` 是推荐且最清晰的宿主部署值；源文件必须是普通文件，不能是符号链接。代理启用后，entrypoint会把它复制到tmpfs中的 `/run/xray/config.json`，固定为 `root:xray 0640`，再以UID/GID `65532:65532` 的 `xray` 用户执行配置测试和正式运行。不要直接修改容器内runtime副本。

配置必须满足公共启动契约：

- 严格JSON，不使用JSONC/YAML或相对文件路径。
- 所有inbound只能监听 `127.0.0.1` 或 `::1`。
- 必须恰好有一个HTTP inbound精确监听 `127.0.0.1:10809`；当前验证器不禁止其他仅监听loopback的inbound。
- `log.access` 必须为 `none`，`loglevel`只能为 `warning`、`error` 或 `none`，`dnsLog`不能为true。
- 第一个/default outbound不能是 `freedom` 或 `blackhole`；严格 `cn-direct` 还会把它限制为受支持的远端代理协议。

验证器支持两种配置档案：

1. `all-proxy`：禁止任何 `freedom` outbound，且第一个/default outbound不能是 `blackhole`；未被其他非直连规则处理的流量使用第一个非直连outbound。验证器不会证明每条流量都到达同一个远端节点，额外routing、balancer或其他非直连outbound仍需人工审计。
2. `cn-direct`：只允许中国域名和中国IP直连，必须严格使用下面的规范化结构。不能添加第四个outbound、额外routing rule、balancer、catch-all direct，或通过 `proxySettings`/`dialerProxy` 间接引用direct。

`cn-direct` 的 `outbounds` 顺序必须精确为 `proxy`、`direct`、`block`，routing rules顺序必须精确为“私网阻断、中国域名直连、中国IP直连”。不同远端协议的schema差异很大，因此不要从本文复制一个伪通用 `proxy.settings`；请把你已经通过 `xray run -test` 的真实VLESS、VMess、Trojan、Shadowsocks或SOCKS outbound放在 `outbounds[0]`，并把tag设为 `proxy`。

公共HTTP inbound至少包含以下精确对象：

```json
{
  "tag": "local-http",
  "listen": "127.0.0.1",
  "port": 10809,
  "protocol": "http",
  "settings": {}
}
```

真实proxy outbound之后的两个对象必须精确为：

```json
[
  {
    "tag": "direct",
    "protocol": "freedom",
    "settings": {
      "domainStrategy": "UseIP",
      "finalRules": [
        {
          "action": "block",
          "ip": ["geoip:private"]
        }
      ]
    }
  },
  {
    "tag": "block",
    "protocol": "blackhole",
    "settings": {}
  }
]
```

routing对象必须精确为：

```json
{
  "domainStrategy": "IPOnDemand",
  "rules": [
    {
      "type": "field",
      "ip": ["geoip:private"],
      "outboundTag": "block"
    },
    {
      "type": "field",
      "domain": ["geosite:cn"],
      "outboundTag": "direct"
    },
    {
      "type": "field",
      "ip": ["geoip:cn"],
      "outboundTag": "direct"
    }
  ]
}
```

`IPOnDemand`使域名在规则匹配需要IP时被解析；实现通常可以把查询延迟到遇到第一条IP规则。由于本契约第一条规则就是 `geoip:private -> block`，解析到私网地址的域名会先被阻断，然后才继续考虑 `geosite:cn`中国域名直连和 `geoip:cn`中国IP直连；其余未匹配流量落到第一个 `proxy` outbound。`direct` 的 `finalRules` 还会在最终解析后再次阻断 `geoip:private`，形成第二层防护。Xray使用容器resolver完成必要的IP解析，本契约不提供高级split-DNS或防DNS泄漏保证。

真实节点地址、UUID、密码、私钥和订阅URL只应存在于宿主机root-only配置。镜像内置的 `geoip.dat` 和 `geosite.dat` 已保证Xray用户可读；若配置引用额外CA、证书、私钥或自定义geo asset，应使用容器内绝对路径单独只读挂载，并只授予UID/GID 65532所需的最小权限。例如私密文件可使用 `root:65532 0640`，父目录使用 `root:65532 0750`；公开CA或geo asset可使用 `root:root 0644`。不要为了读取一个秘密文件而把整个 `/root/codex/xray` 目录改成全局可读。

```bash
chown root:65532 /root/codex/xray/client.key
chmod 0640 /root/codex/xray/client.key
```

容器内的 `dev` 用户保留 `NOPASSWD sudo`，因此本来就等价于该容器root；Xray以UID/GID 65532运行是进程最小权限，不是对 `dev` 隐藏节点配置的边界。不要把容器SSH公钥授权给不可信用户。

### 代理开关

Stack中只有一个开关：

```yaml
XRAY_PROXY_ENABLED: "true"
```

- `"true"`：验证并启动Xray，等待10809就绪后再启动sshd；SSH中的Codex和Claude Code获得大小写 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY`。实际出站由配置档案决定：`all-proxy`禁止 `freedom` 且未被其他非直连规则处理的流量使用第一个非直连outbound；`cn-direct`先阻断私网、中国域名/IP直连、其他未匹配流量使用远端代理。Xray或sshd任一异常退出都会停止另一个进程并使容器失败退出。
- `"false"`：不解析或验证Xray配置内容、不启动Xray、不监听10809，也不向SSH/login shell注入代理变量，两个CLI直接联网；healthcheck若发现残留Xray进程或10809监听会判定失败。
- 其他值：容器拒绝启动。
- 不要在Stack中另外设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 或 `NO_PROXY`（包括小写形式）；personal entrypoint会拒绝这些旁路配置，代理只由单一开关管理。

专用模板无论开关值如何都会声明 `/root/codex/xray/config.json` bind mount，并设置 `create_host_path:false`。因此关闭模式不要求内容有效，但源文件仍必须存在，否则Docker会在entrypoint启动前拒绝创建容器。若关闭时希望完全移除该挂载，需要删除对应volume项并Update Stack；再次启用前必须恢复挂载和有效配置。

切换后必须在Portainer中Update整个Stack/Recreate，不能只修改运行中进程或点击Restart。旧Stack没有设置该变量时默认按 `false` 启动。容器开关只管理本方案生成的代理环境；如果你曾在持久化home的 `.bashrc`、`.profile` 或Claude settings中手工写过代理变量，应先删除这些自定义设置，否则它们仍可覆盖关闭模式。

Xray端口绝不能加入 `ports` 或 `expose`。宿主机仍只能看到：

```yaml
ports:
  - "127.0.0.1:2222:2222"
```

不同入口获得代理环境的方式不同：

| 入口 | 动态代理环境 |
|---|---|
| SSH `dev` shell或remote command | 有，由sshd `SetEnv` 注入；这是CLI真实E2E的标准入口 |
| `bash -l` / `bash -lc` login shell | 有，由 `/etc/profile.d/codex-xray-proxy.sh` 读取 `/run/codex-proxy/env.sh` |
| Portainer root Console普通 `bash`/`sh` | 通常没有；它不经过sshd，也不会自动加载login profile |
| 普通 `docker exec --user dev ...` | 不能假定存在，除非显式启动login shell |
| Xray进程 | 所有proxy变量被显式清除，防止递归代理 |

因此Portainer root Console中 `HTTPS_PROXY` 为空不代表Xray失效。真实Codex/Claude Code验证应通过SSH `dev` 会话；临时诊断可显式执行 `bash -lc 'env | grep -i proxy'`，或在root Console中加载 `. /run/codex-proxy/env.sh`。普通exec需要写成：

```bash
docker exec --user dev codex-ssh bash -lc 'codex --version'
docker exec --user dev codex-ssh bash -lc 'claude --version'
```

### 真实代理E2E

以下命令必须按执行位置分组，不能把宿主机Docker管理命令粘贴到容器SSH会话中。

#### Docker宿主机

先绕过宿主机自身可能存在的代理变量，记录直接出口并检查容器边界：

```bash
curl -4 --fail --show-error --noproxy '*' https://api.ipify.org

docker inspect codex-ssh \
  --format '{{json .NetworkSettings.Ports}}'

docker exec codex-ssh \
  /usr/local/bin/personal-remote-healthcheck.sh

docker exec codex-ssh \
  stat -c '%U:%G %a %n' /run/xray/config.json

docker exec codex-ssh \
  gosu xray:xray test -r /usr/local/share/xray/geoip.dat

docker exec codex-ssh \
  gosu xray:xray test -r /usr/local/share/xray/geosite.dat

docker logs --tail=200 codex-ssh
```

开启模式下，runtime配置应显示 `root:xray 640`；两个geo asset读取检查应成功。端口映射只能包含宿主 `127.0.0.1:2222`，不能出现10809；日志不应包含UUID、密码、订阅URL或长期access log。

#### SSH `dev` 会话

通过PuTTY/SSH进入容器后执行：

```bash
whoami
printf 'HTTPS_PROXY=%s\n' "$HTTPS_PROXY"
env | grep -Ei '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)='
curl -4 --fail --show-error https://api.ipify.org
codex
claude
```

需要同时确认：

- `whoami` 为 `dev`，`HTTPS_PROXY` 为 `http://127.0.0.1:10809`，且没有 `ALL_PROXY`。
- 对经过人工审计、没有额外非直连路由的 `all-proxy` 配置，境外IP回显应等于预期远端节点出口。
- `cn-direct` 档案下，使用可信中国境内IP回显端点时，结果应等于宿主机直连出口；使用 `api.ipify.org` 等未匹配中国规则的端点时，结果应等于远端代理出口。
- 访问私有IP的请求被 `geoip:private -> block` 阻断；只使用无害测试目标，不要探测或影响生产内网服务。
- Codex真实Responses请求成功，包括WebSocket路径及必要时的HTTPS fallback；Claude Code真实请求成功。

仅访问中国网站不能证明发生了直连，必须使用可信的中国境内IP回显端点比较出口。`IPOnDemand`可能通过容器resolver解析域名，本方案不声称隐藏所有DNS查询。

#### 关闭代理后的新SSH会话

将开关设为 `false` 并Update整个Stack后，重新建立SSH会话，再执行：

```bash
env | grep -Ei '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)='
pgrep -x xray
```

两条命令均应无输出；随后确认Codex和Claude Code仍能直接联网。不要使用宽泛的 `env | grep -i proxy`，因为它会把正常存在的 `XRAY_PROXY_ENABLED=false` 也匹配出来。

## 10. 更新与回滚

更新前记录当前运行digest：

```bash
running_image_id="$(docker inspect codex-ssh --format '{{.Image}}')"
docker image inspect "$running_image_id" --format '{{json .RepoDigests}}'
```

Portainer操作的含义不同：

- **Restart**：只重启现有容器，不拉取新镜像，也不应用新的Stack环境或bind定义。
- **Re-pull/Pull latest**：获取标签当前指向的镜像，但只有重新部署后运行容器才会切换。
- **Update Stack**：比较当前Stack定义和镜像，只在检测到变化时重建受影响服务；YAML和镜像均未变化时可能保留现有容器。
- **Recreate/force recreate**：无论YAML是否变化都生成新容器；原子替换bind源文件时必须使用。

更新：

1. 确认private workflow最新发布成功。
2. 确认host-key-init与codex-ssh两处镜像引用完全一致。
3. Portainer选择Re-pull/Pull latest。
4. 在Stack Editor中Update整个Stack；不要只Restart，也不要只重建单个codex-ssh容器。
5. 验证：

   ```bash
   docker exec --user dev codex-ssh bash -lc 'codex --version'
   docker exec --user dev codex-ssh bash -lc 'claude --version'
   docker exec codex-ssh xray version
   docker exec codex-ssh /usr/local/bin/personal-remote-healthcheck.sh
   ```

修改Xray配置后必须让entrypoint重新执行。若确认是在原inode上原地写入，Restart会重新复制配置；但编辑器或WinSCP常以“写新文件再rename”方式保存，此时同一容器的bind可能继续引用旧inode。最稳妥的做法是明确执行可保证生成新容器的 **Recreate/force recreate**。普通 `Update the stack` 在YAML和镜像均未变化时不保证重建，不能单独作为配置已生效的证据；操作后应核对容器ID或创建时间已变化，再复查 `/run/xray/config.json` 与healthcheck。

回滚时把host-key-init和codex-ssh同时改回同一个历史remote根digest，再重新部署整个Stack。镜像回滚不会回滚 `/home/dev` 或 `/root/codex/xray/config.json`；新版Claude Code可能迁移用户状态，因此重大版本更新前应备份整个dev-home目录和当前Xray配置。

## 11. Home重置影响

共享home同时包含：

```text
.codex
.claude
.claude.json
mise runtime
Git配置
缓存与历史
```

执行：

```bash
./scripts/reset-home-volume.sh codex-dev-home
```

会同时删除Codex和Claude Code登录状态。Portainer bind mount方案删除 `/root/codex/dev-home` 内容也有相同影响。

## 12. 许可边界

Claude Code是专有软件，官方公开条款没有明确授予把binary打入公开OCI镜像进行第三方再分发的权利。因此本方案限定为：

- owner本人使用。
- private GHCR package。
- 不转售、不向第三方提供镜像。
- 不共享Claude订阅OAuth或API凭据。

私有registry托管仍不是官方明确授权的再分发场景，只是显著降低暴露。若未来扩展到团队、客户或其他用户，应先向Anthropic sales/legal取得书面确认。
