# AGENTS.md

This project runs inside the `codex-dev-base` Docker container.

## Dependency setup rules

Before installing anything, inspect the project and identify its stack from:

- README.md
- package.json / pnpm-lock.yaml / yarn.lock / package-lock.json
- pyproject.toml / requirements.txt / poetry.lock / uv.lock
- go.mod
- Cargo.toml / Cargo.lock
- pom.xml / build.gradle / gradle.lockfile
- Dockerfile / compose.yaml
- mise.toml / .tool-versions

## Runtime installation

- Prefer `mise` for language/runtime versions.
- If runtime versions are not specified, choose a current stable LTS where appropriate and write the decision down.
- Do not install heavy SDKs globally unless the project clearly needs them.

## Dependency installation

- Use the package manager indicated by lockfiles.
- For Node:
  - pnpm-lock.yaml → pnpm install
  - yarn.lock → yarn install
  - package-lock.json → npm ci
  - no lockfile → ask before choosing unless the task is clearly exploratory
- For Python:
  - Prefer venv inside the project or the project’s documented tooling.
  - Do not install project packages globally.
- For Go:
  - Use go mod download / go test.
- For Rust:
  - Use cargo fetch / cargo test.
- For Java:
  - Use project wrapper first: ./gradlew or ./mvnw.

## Safety

- Explain before using `sudo apt-get`.
- Do not store secrets in the repository.
- Do not modify files outside `/workspace` unless explicitly needed.
- Keep generated build artifacts out of git unless requested.
