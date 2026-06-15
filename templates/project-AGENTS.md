# AGENTS.md

本项目运行在 `codex-dev-base` Docker 容器中。

## 依赖安装规则

安装任何依赖前，先检查项目并识别技术栈：

- README.md
- package.json / pnpm-lock.yaml / yarn.lock / package-lock.json
- pyproject.toml / requirements.txt / poetry.lock / uv.lock
- go.mod
- Cargo.toml / Cargo.lock
- pom.xml / build.gradle / gradle.lockfile
- Dockerfile / compose.yaml
- mise.toml / .tool-versions

## 语言运行时

- 优先使用 `mise` 安装 Node、Python、Go、Rust、Java 等语言运行时。
- 如果项目没有指定版本，优先选择当前稳定版或 LTS 版，并在执行前说明选择理由。
- 不要把重型 SDK 全局安装到系统里，除非项目确实需要。

## 项目依赖

- 根据 lockfile 选择包管理器。
- Node 项目：
  - `pnpm-lock.yaml` → `pnpm install`
  - `yarn.lock` → `yarn install`
  - `package-lock.json` → `npm ci`
  - 没有 lockfile 时，先说明建议再继续
- Python 项目：
  - 优先使用项目内 venv 或项目文档指定的工具。
  - 不要把项目依赖全局安装到系统 Python。
- Go 项目：
  - 使用 `go mod download` / `go test`。
- Rust 项目：
  - 使用 `cargo fetch` / `cargo test`。
- Java 项目：
  - 优先使用项目自带 wrapper：`./gradlew` 或 `./mvnw`。

## 安全规则

- 使用 `sudo apt-get` 前先说明原因。
- 不要把密钥、token、密码写入仓库。
- 不要修改 `/workspace` 之外的文件，除非明确需要。
- 不要把生成的构建产物加入 git，除非用户明确要求。
