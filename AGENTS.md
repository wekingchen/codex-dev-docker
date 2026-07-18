# AGENTS.md

本仓库用于构建 Codex 通用 Docker 运行底座镜像。

## 目标

基础镜像应保持轻量、稳定、通用。它只需要提供让 Codex 检查项目、修改代码、执行命令、安装项目依赖所需的基础能力，不应该把所有可能的技术栈都预装进去。

## 基础镜像规则

- 应包含：
  - Codex CLI
  - git / git-lfs
  - ssh client
  - curl / wget
  - sudo
  - build-essential
  - Python 基础环境
  - mise
  - 常用排错工具
- 不要把以下内容写进镜像：
  - 密钥
  - token
  - SSH 私钥
  - Codex 登录状态
- 除非明确需要，不要把重型技术栈放进基础镜像：
  - Flutter / Android SDK
  - OpenWrt 工具链
  - 数据库服务端
  - 浏览器测试环境
  - 大型交叉编译 SDK
- 重型技术栈后续应做成派生镜像，而不是塞进基础镜像。

## 项目依赖安装规则

使用此镜像进入具体项目后，Codex 应按以下顺序处理：

1. 安装任何依赖前，先检查项目文件：
   - README.md
   - package.json / pnpm-lock.yaml / yarn.lock / package-lock.json
   - pyproject.toml / requirements.txt / poetry.lock / uv.lock
   - go.mod
   - Cargo.toml / Cargo.lock
   - pom.xml / build.gradle / gradle.lockfile
   - Dockerfile / compose.yaml
   - mise.toml / .tool-versions
2. 优先使用 `mise` 安装语言运行时。
3. 优先使用项目自身的依赖安装方式：
   - Node：根据 lockfile 使用 npm / pnpm / yarn
   - Python：根据项目文件使用 venv + pip / uv / poetry
   - Go：使用 go mod download / go test
   - Rust：使用 cargo fetch / cargo build
4. 只有确实需要系统包时，才使用 `sudo apt-get`。
5. 进行大规模依赖安装前，先说明计划。
6. 缓存应尽量落在已挂载的 volume 中。
7. 不要修改挂载目录之外的宿主机配置。

## 供应链规则

- GitHub Actions 必须固定到官方仓库的完整 40 位 commit SHA，并在同行保留精确版本注释。
- GitHub-hosted runner 必须固定明确的 Ubuntu 版本标签，不使用 `ubuntu-latest`。
- Docker 基础镜像必须同时保留可读 tag 和经过验证的多架构根 index digest；禁止使用单平台子 manifest digest替代根 index。
- 安装第三方工具不得执行未经校验的浮动远程 shell 脚本。
- mise 必须固定官方 release，并分别校验 amd64、arm64 asset 的 SHA-256；两个架构必须在同一提交中更新。
- Codex CLI 是明确例外：必须继续动态解析 `openai/codex` 官方 latest，并通过官方 installer 安装，不得在仓库中静态固定版本。
- Claude Code只能进入owner本人使用的独立private GHCR package；公开base/remote package、Compose默认值和公开模板 `templates/portainer-stack.yaml` 不得包含Claude二进制或指向private package。`templates/portainer-personal-stack.yaml` 是owner-only private package的明确例外。
- Claude Code必须解析官方精确版本，固定release key指纹，验证`manifest.json.sig`与平台checksum/size；禁止执行浮动bootstrap或`curl | sh`。
- GHCR visibility是package级而不是tag级；personal package必须用owner PAT发布、不得使用公开仓库`GITHUB_TOKEN`、不得关联或继承repository权限，并在candidate push前后和promotion前自动确认private且repository为空。GitHub API不能完整枚举显式用户与Actions ACL，owner还必须人工保持Manage access和Manage Actions access为空，不得把自动门禁描述为完整owner-only证明。
- 镜像不得包含Claude登录态、API key、OAuth token或固定model；容器内更新必须关闭，由private镜像发布链管理版本。
- Xray只能进入owner-only `personal-remote`；公开Compose和公开Portainer模板不得接入Xray。文档不得硬编码动态解析的Xray latest版本。
- personal Xray固定使用UID/GID 65532，10809只能监听容器loopback且不得发布宿主端口；节点配置只能从宿主root-controlled文件只读挂载，Xray与sshd任一异常退出时容器必须fail closed。
- 文档中的 `all-proxy` 只能表述为“无 `freedom` outbound，未被其他非直连规则处理的流量使用第一个非直连outbound”；严格 `cn-direct` 必须保持 `IPOnDemand`、私网优先阻断、仅中国域名/IP直连及freedom `finalRules`二次阻断。
- personal Portainer文档必须说明关闭模式下bind源文件仍需存在、HOST_UID/HOST_GID不得使用65532、代理开关或Stack定义变化需Update Stack，而原子替换bind源文件必须force recreate，以及普通Portainer root Console不等于SSH `dev`登录环境。
- provenance、SBOM 和漏洞扫描必须针对最终 registry candidate 根 digest，并在 promotion 前完成。
- 未确认 OCI referrer 可达关系前，GHCR cleanup 必须继续保护所有 untagged versions。

## 远程 SSH 规则

- 默认 base 镜像不得安装或启动 `sshd`；服务端SSH只能存在于独立 `remote` target和 `codex-dev-remote` package。
- 宿主发布端口必须在Compose中固定绑定 `127.0.0.1`，不得提供 `0.0.0.0`、空host IP或公网绑定开关。
- 只允许 `dev` 公钥认证；必须禁止root、password、keyboard-interactive、空密码和用户环境注入。
- 必须禁止SSH Agent、TCP、Unix socket、X11、GatewayPorts和tunnel forwarding。
- SSH host private key只能在运行时生成到独立named volume；不得进入镜像、仓库、build context或home volume。
- 本地授权文件固定放在被Git和Docker排除的 `.codex-ssh/`；容器内生效副本必须位于home之外并由root控制。
- 远程服务不得挂载Docker socket、宿主机私钥、宿主根目录或SSH Agent socket。
- 本地交互和远程服务复用home/workspace时，必须通过共享volume中的 `flock` fail closed；不得仅依赖包装脚本预检查。
- 远程 `dev` 当前保留 `NOPASSWD sudo`，因此文档和审查都必须把授权公钥视为等价于容器root。
- base与remote candidate必须使用同一Codex official latest身份，并在两个package都通过双架构smoke、provenance、SBOM和漏洞扫描后才允许promotion。
