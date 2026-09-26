# syntax=docker/dockerfile:1
# Base: Node 24 LTS, pinned by digest for reproducible builds
ARG NODE_IMAGE=node:24.21.0-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6
ARG UV_VERSION=0.12.19

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM ${NODE_IMAGE}
ARG CLAUDE_CODE_VERSION=2.1.283
ARG PLAYWRIGHT_VERSION=1.63.0
ARG PG_MAJOR=18
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# PGDG repo: Debian's psql 15 can't pg_dump newer servers
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      tini tmux git openssh-client less procps ripgrep unzip shellcheck build-essential \
      python3 python3-pip python3-venv "postgresql-client-${PG_MAJOR}" \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/

# gh, terraform, AWS CLI, yq, jq, pnpm and Bruno install at runtime via install-tools.sh (versions from .env)
# Playwright browsers are installed per project; the image only carries their system libraries
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npx -y "playwright@${PLAYWRIGHT_VERSION}" install-deps \
    && npm cache clean --force && rm -rf /var/lib/apt/lists/* /root/.npm

# Updates come from rebuilding the image, not in-place self-updates
ENV DISABLE_AUTOUPDATER=1 TERM=xterm-256color LANG=C.UTF-8
# Single mount: /data is the workspace, HOME lives inside it so every instance on the folder shares it
ENV HOME=/data/.home
# Runtime-installed tools and npm -g land in the shared folder and win over image binaries
ENV PATH=/data/.home/.local/bin:$PATH NPM_CONFIG_PREFIX=/data/.home/.local
# node user; numeric so runtimes can verify it is non-root
USER 1000:1000
WORKDIR /data
COPY --chmod=755 start.sh install-tools.sh /usr/local/bin/
COPY keys/aws-cli.asc /usr/local/share/claude-in-container/aws-cli.asc
# Unhealthy when Claude exited and only the fallback shell remains; the long start period covers first-start tool installs
HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=3 \
  CMD ["sh", "-c", "tmux has-session -t main 2>/dev/null && pgrep -x claude >/dev/null"]
# tini reaps zombies and forwards signals so the container stops cleanly
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start.sh"]
