# syntax=docker/dockerfile:1.7
FROM scratch
LABEL org.opencontainers.image.title="codex-dev personal package visibility probe" \
      org.opencontainers.image.description="不含 Codex 或 Claude Code，仅用于首次确认 GHCR package visibility。" \
      io.codex-dev.image.flavor="visibility-probe"
CMD ["/bin/false"]
