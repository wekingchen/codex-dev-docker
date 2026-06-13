# AGENTS.md

This repository builds a generic Codex runtime Docker image.

## Goal

Keep the base image small, stable, and generic. It should provide enough tools for Codex to inspect projects and install project-specific dependencies later, without baking every possible technology stack into the image.

## Base image rules

- Do include Codex CLI, git, ssh client, curl/wget, sudo, build-essential, Python basics, mise, and common debugging tools.
- Do not bake secrets, tokens, SSH private keys, or Codex login state into the image.
- Do not add heavy stacks to the base image unless explicitly requested:
  - Flutter / Android SDK
  - OpenWrt toolchains
  - database servers
  - browsers / Playwright dependencies
  - large cross-compilation SDKs
- Prefer adding heavy stacks later as derived images.

## Project dependency installation policy

When using this image inside a project, Codex should:

1. Inspect project files before installing anything:
   - README.md
   - package.json / pnpm-lock.yaml / yarn.lock
   - pyproject.toml / requirements.txt
   - go.mod
   - Cargo.toml
   - pom.xml / build.gradle
   - Dockerfile / compose.yaml
   - mise.toml / .tool-versions
2. Prefer `mise` for language/runtime installation.
3. Prefer project-native dependency commands:
   - Node: npm / pnpm / yarn according to lockfile
   - Python: venv + pip / uv / poetry according to project files
   - Go: go mod download
   - Rust: cargo fetch / cargo build
4. Use `sudo apt-get` only when system packages are truly needed.
5. Explain the plan before major dependency installation.
6. Keep caches in mounted volumes.
7. Do not modify host-level configuration outside mounted directories.
