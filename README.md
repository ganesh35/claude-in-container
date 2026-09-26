# claude-in-container

Always-on [Claude Code](https://docs.claude.com/en/docs/claude-code) in a container, reachable from phone or browser via Remote Control. Runs on any Docker or Podman host — a server, a NAS (Unraid template included) or a laptop.

## Why run Claude Code in a container?

**Safer**
- **Scoped file access:** Claude sees only the mounted workspace. Your home folder, SSH keys, cloud credentials and other projects stay invisible unless you mount them.
- **Limited blast radius:** a bad command or runaway process hits the container, not your host. Recreate it in seconds; only the mounted folders are at risk.
- **Non-root, no sudo:** Claude can't install system packages or change the host system.
- **Explicit secrets:** Claude gets only the keys and tokens you pass in `.env` or a mount — nothing leaks in from your shell environment.
- **No open ports:** Remote Control connects outbound to claude.ai; nothing listens on your network.
- **Verified tools:** base image pinned by digest, release binaries checked against published checksums.

**Always on, from anywhere**
- **Runs 24/7** on a server, NAS or spare machine — your laptop can sleep or stay closed.
- **Phone and browser access** through Remote Control in the Claude app or claude.ai/code.
- **Survives disconnects:** Claude runs in tmux, so closing a terminal or losing SSH doesn't stop it.
- **Picks up where it left off:** the last conversation resumes after a restart; the restart policy brings the container back after crashes or reboots.
- **Visible health:** the healthcheck flags when Claude has stopped while the container is still up.

**Consistent and reproducible**
- **Batteries included:** Node 24/pnpm, Python/uv, git/gh, AWS CLI, Terraform, Bruno CLI, psql 18, jq/yq, shellcheck, build-essential and Playwright system deps (browsers install per project).
- **Same toolchain everywhere:** every tool version is pinned, so Claude works the same on every host.
- **Controlled updates:** the auto-updater is off; you choose when to move to a new Claude Code version, and roll back by rebuilding the previous one.
- **Clean host:** no global npm, pip or Terraform installs on your machine.

**Portable and easy to operate**
- **Runs anywhere:** Docker, Podman (rootless too), Compose or Unraid, on amd64 and arm64; scripts work in any POSIX shell.
- **Movable setup:** login, settings and history live in one home folder — copy it to move to another host.
- **Several instances side by side:** one container per project or client, each with its own workspace, login and session name.
- **Resource caps:** limit CPU and memory with your engine's standard flags.
- **Clean removal:** delete the container and its two folders; nothing else is left behind.

## Quick start

Requires Docker or Podman and any POSIX shell (sh, dash, ash, bash, zsh).

```bash
git clone https://github.com/ganesh35/claude-in-container.git && cd claude-in-container
cp .env.example .env    # set WORKSPACE_DIR, CLAUDE_HOME_DIR, PUID/PGID
scripts/build.sh
scripts/run.sh
scripts/attach.sh       # first run: pick a theme, log in with your Claude subscription
```

Detach with `Ctrl-b d` — Claude keeps running. Open the Claude app → Code, or [claude.ai/code](https://claude.ai/code), and pick the session named after `REMOTE_CONTROL_NAME`.

## Other ways to run

| Method | Command | Notes |
|---|---|---|
| Docker Compose | `mkdir -p workspace home && docker compose up -d --build` | Reads `.env`; on Docker, fails fast if mount folders are missing (it would create them root-owned); Podman creates them owned by you |
| Plain docker | see below | |
| Podman (rootless) | `scripts/run.sh` | Adds `--userns keep-id` so files keep your host owner; Compose can't express this portably |
| Unraid | [`unraid/claude-in-container.xml`](unraid/claude-in-container.xml) | See [Unraid](#unraid) |

```bash
docker run -d --name claude-in-container --hostname claude-in-container --restart unless-stopped \
  --user 1000:1000 -v "$PWD/workspace:/workspace" -v "$PWD/home:/home/node" \
  -e REMOTE_CONTROL_NAME=my-box claude-in-container:local
```

### Unraid

1. Clone the repo on the server and build: `CONTAINER_ENGINE="sudo docker" scripts/build.sh` (Unraid only pulls images that are missing, so the local image is used).
2. Create the workspace and home folders owned by the container user: `mkdir -p DIR && chown 99:100 DIR`.
3. Copy the template to `/boot/config/plugins/dockerMan/templates-user/my-claude-in-container.xml`, then Docker → Add Container → pick it. Adjust `--user` in Extra Parameters to match your files' owner.
4. Open the container console and log in.

## Authentication

| Method | Remote Control | How |
|---|---|---|
| Claude subscription (default) | ✅ | Log in once via `scripts/attach.sh`; stored in `CLAUDE_HOME_DIR/.claude/` |
| API key | ❌ subscription-only | Set `ANTHROPIC_API_KEY` in `.env`; use `scripts/attach.sh` |

### GitHub, git and AWS

Configure other tools yourself inside the container. Everything lands in the mounted home folder (`CLAUDE_HOME_DIR`), so it survives restarts and rebuilds:

```sh
scripts/attach.sh    # then, in the fallback shell or a new tmux window (Ctrl-b c):
gh auth login && gh auth setup-git    # GitHub CLI, and git push over HTTPS
git config --global user.name "Your Name" && git config --global user.email "you@example.com"
aws configure        # or: aws configure sso
```

Claude can use whatever you configure here, so prefer narrowly scoped credentials — a fine-grained GitHub token limited to the repos it should touch, a least-privilege IAM user or role — and protect the home folder like any credential store.

## Configuration (`.env`)

| Variable | Default | Purpose |
|---|---|---|
| `WORKSPACE_DIR` | `./workspace` | Host folder mounted at `/workspace` — the only files Claude sees |
| `CLAUDE_HOME_DIR` | `./home` | Host folder mounted at `/home/node` — login, settings, history |
| `PUID` / `PGID` | `1000` | User the container runs as; match the workspace owner |
| `REMOTE_CONTROL_NAME` | hostname | Session name in the Claude app |
| `CLAUDE_CODE_VERSION` | pinned in `Dockerfile` | Claude Code version baked in at build |
| `ANTHROPIC_API_KEY` | — | Optional, replaces the subscription login |
| `CONTAINER_ENGINE` | auto (docker, then podman) | e.g. `sudo docker` where docker needs root |
| `IMAGE` / `CONTAINER_NAME` | `claude-in-container:local` / `claude-in-container` | |

Other tool versions are build args in the [`Dockerfile`](Dockerfile) (`GH_VERSION`, `TERRAFORM_VERSION`, `PG_MAJOR`, …); override with `scripts/build.sh --build-arg NAME=VALUE`.

## Scripts

| Script | Does |
|---|---|
| `scripts/build.sh [args]` | Build the image; extra args go to the engine (e.g. `--platform linux/amd64`) |
| `scripts/run.sh [--replace]` | Start the container; `--replace` recreates an existing one |
| `scripts/attach.sh` | Attach to Claude's tmux session |
| `scripts/update.sh [version]` | Pin a Claude Code version (default: latest) in `.env`, rebuild, recreate |
| `scripts/lint.sh` | shellcheck + hadolint via pinned containers |
| `scripts/test.sh` | End-to-end tests on a throwaway copy; see [Testing](#testing) |

Compose users update with `CLAUDE_CODE_VERSION=<version>` in `.env`, then `docker compose up -d --build`.

## Testing

`scripts/test.sh` lints, builds a throwaway image and runs the scripts end to end under every installed shell in `TEST_SHELLS` (default `dash ash bash zsh`; missing ones are skipped). It works on a temporary copy without your `.env`, and removes only the containers, image and folders it created.

For all four shells on a Docker host, run it inside an Alpine helper that uses the host's Docker. The shared folder must have the same path on host and helper, because the Docker daemon resolves bind mounts on the host:

```sh
mkdir -p /tmp/cic-test && docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:/repo:ro" -v /tmp/cic-test:/tmp/cic-test -e TMPDIR=/tmp/cic-test -w /repo alpine:3 \
  sh -c 'apk add -q docker-cli docker-cli-buildx dash bash zsh tar && sh scripts/test.sh'
```

## Behaviour

- `start.sh` runs `claude --remote-control <name> --continue` in tmux session `main`, falling back to a fresh session.
- If Claude exits you land in a shell inside tmux; run `claude --continue --remote-control <name>` or restart the container.
- The container lives as long as the tmux session; `restart: unless-stopped` brings it back.
- Healthcheck: *unhealthy* when the tmux session is up but Claude is not running.
- The Remote Control session URL changes on every restart; the app lists it under the same name.

## Security

- Mount only what Claude should see. Never mount personal shares, `~/.ssh` or cloud credentials you don't want it to use.
- No ports are exposed; Remote Control connects outbound to claude.ai.
- The auto-updater is disabled; updates happen only by rebuilding.
- Keep `.env` out of git (already ignored).

## Troubleshooting

| Symptom | Check |
|---|---|
| No session in the Claude app | `docker exec <name> tmux capture-pane -p -t main` — a prompt may be waiting |
| Asked to log in again | `CLAUDE_HOME_DIR` must be writable by `PUID:PGID` |
| `Permission denied` on workspace files | `PUID`/`PGID` don't match the folder owner |
| Healthcheck missing under Podman | Build with `scripts/build.sh` (adds `--format docker`) |

## License

[MIT](LICENSE)
