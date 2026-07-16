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

私有镜像从同一次公开发布的不可变 base/remote 根 digest 派生，再加入经过官方签名 manifest 和 SHA-256 验证的 Claude Code native binary。

```text
公开 codex-dev-base@sha256:...
  └── codex-dev-personal-base

公开 codex-dev-remote@sha256:...
  └── codex-dev-personal-remote
```

容器结构不变：

- workspace：`/workspace`
- 共享 home：`/home/dev`
- Codex 状态：`/home/dev/.codex`
- Claude Code主要状态：`/home/dev/.claude`
- Claude Code其他用户状态：`/home/dev/.claude.json`

不增加第二个 Compose service、第二个 SSH 端口或第二个 home volume。两个 CLI 共享 Git、mise、shell配置、项目文件和缓存，但认证目录彼此独立。

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
Actions → 构建私有 Codex + Claude personal 镜像 → Run workflow
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

登录后任选：

```bash
codex
claude
```

仍然只有一个 `codex-ssh` 服务和一个loopback端口。原有key-only登录、host fingerprint、禁止forwarding、共享home锁和`NOPASSWD sudo`边界不变。

## 9. Portainer拉取 private GHCR

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

不要修改仓库公开模板。复制现有Stack为本人私有版本，只把两处image同时替换为：

```yaml
image: ghcr.io/wekingchen/codex-dev-personal-remote:latest
```

更可重复的部署应固定同一个已验证remote根digest：

```yaml
image: ghcr.io/wekingchen/codex-dev-personal-remote@sha256:<remote-root-digest>
```

必须同时修改：

- `codex-ssh-hostkey-init`
- `codex-ssh`

其他端口、volume、authorized keys、host keys、tmpfs、capabilities和healthcheck全部保持公开模板原样。

## 10. 更新与回滚

更新前记录当前运行digest：

```bash
running_image_id="$(docker inspect codex-ssh --format '{{.Image}}')"
docker image inspect "$running_image_id" --format '{{json .RepoDigests}}'
```

更新：

1. 确认private workflow最新发布成功。
2. Portainer选择Re-pull/Pull latest。
3. Update Stack或Recreate容器。
4. 验证：

   ```bash
   docker exec --user dev codex-ssh codex --version
   docker exec --user dev codex-ssh claude --version
   ```

回滚时把host-key-init和codex-ssh同时改回同一个历史remote根digest，再重新部署。

镜像回滚不会回滚 `/home/dev`。新版Claude Code可能迁移用户状态，因此重大版本更新前应备份整个dev-home目录或volume。

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
