# syntax=docker/dockerfile:1
# Base: Node 24 LTS, pinned by digest for reproducible builds
ARG NODE_IMAGE=node:24.21.0-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6
ARG UV_VERSION=0.12.19

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# Downloads and checksum-verifies standalone binaries so archives never reach the final image
FROM ${NODE_IMAGE} AS tools
ARG TARGETARCH
ARG GH_VERSION=2.101.0
ARG YQ_VERSION=4.53.6
ARG JQ_VERSION=1.8.2
ARG TERRAFORM_VERSION=1.16.4
ARG AWSCLI_VERSION=2.37.4
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN gh="gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
    && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${gh}" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" | grep " ${gh}$" | sha256sum -c - \
    && tar -xzf "${gh}" && install -D "gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /out/bin/gh
RUN yq="yq_linux_${TARGETARCH}" \
    && curl -fsSLO "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/${yq}" \
    && echo "$(curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/checksums-bsd" | sed -n "s/^SHA256 (${yq}) = //p")  ${yq}" | sha256sum -c - \
    && install -D "${yq}" /out/bin/yq
# Debian bookworm only ships jq 1.6
RUN jq="jq-linux-${TARGETARCH}" \
    && curl -fsSLO "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${jq}" \
    && curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/sha256sum.txt" | grep " ${jq}$" | sha256sum -c - \
    && install -D "${jq}" /out/bin/jq
RUN tf="terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
    && curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${tf}" \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" | grep " ${tf}$" | sha256sum -c - \
    && unzip -q "${tf}" terraform && install -D terraform /out/bin/terraform
# Installed at its final path because the aws symlinks are absolute
# AWS publishes a GPG signature, not a checksum; download is over HTTPS from awscli.amazonaws.com
RUN arch="$([ "${TARGETARCH}" = arm64 ] && echo aarch64 || echo x86_64)" \
    && curl -fsSL -o awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWSCLI_VERSION}.zip" \
    && unzip -q awscli.zip && ./aws/install --install-dir /usr/local/aws-cli --bin-dir /out/bin

FROM ${NODE_IMAGE}
ARG CLAUDE_CODE_VERSION=2.1.283
ARG PNPM_VERSION=12.6.0
ARG BRUNO_CLI_VERSION=4.2.0
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

COPY --from=tools /usr/local/aws-cli /usr/local/aws-cli
COPY --from=tools /out/bin/ /usr/local/bin/
COPY --from=uv /uv /uvx /usr/local/bin/

# Playwright browsers are installed per project; the image only carries their system libraries
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "pnpm@${PNPM_VERSION}" "@usebruno/cli@${BRUNO_CLI_VERSION}" \
    && npx -y "playwright@${PLAYWRIGHT_VERSION}" install-deps \
    && npm cache clean --force && rm -rf /var/lib/apt/lists/* /root/.npm

# Updates come from rebuilding the image, not in-place self-updates
ENV DISABLE_AUTOUPDATER=1 TERM=xterm-256color LANG=C.UTF-8
# node user; numeric so runtimes can verify it is non-root
USER 1000:1000
WORKDIR /workspace
COPY --chmod=755 start.sh /usr/local/bin/start.sh
# Unhealthy when Claude exited and only the fallback shell remains in the tmux session
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["bash", "-c", "tmux has-session -t main 2>/dev/null && pgrep -x claude >/dev/null"]
# tini reaps zombies and forwards signals so the container stops cleanly
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start.sh"]
