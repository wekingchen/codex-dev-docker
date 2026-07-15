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
- provenance、SBOM 和漏洞扫描必须针对最终 registry candidate 根 digest，并在 promotion 前完成。
- 未确认 OCI referrer 可达关系前，GHCR cleanup 必须继续保护所有 untagged versions。
