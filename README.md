# claude-in-container

Always-on [Claude Code](https://docs.claude.com/en/docs/claude-code) in a container, reachable from phone or browser via Remote Control. Runs on any Docker or Podman host — a server, a NAS (Unraid template included) or a laptop.

## Why run Claude Code in a container?

**Safer**
- **Scoped file access:** Claude sees only the one mounted data folder. Your home folder, SSH keys, cloud credentials and other projects stay invisible unless you mount them.
- **Limited blast radius:** a bad command or runaway process hits the container, not your host. Recreate it in seconds; only the mounted folder is at risk.
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
- **Batteries included:** Node 24, Python/uv, git, psql 18, shellcheck, build-essential and Playwright system deps in the image; gh, AWS CLI, Terraform, jq/yq, pnpm, Bruno and any npm or Python CLI install on first start from versions pinned in `.env`.
- **Same toolchain everywhere:** every tool version is pinned, so Claude works the same on every host.
- **Controlled updates:** the auto-updater is off; you choose when to move to a new Claude Code version, and roll back by rebuilding the previous one.
- **Clean host:** no global npm, pip or Terraform installs on your machine.

**Portable and easy to operate**
- **Runs anywhere:** Docker, Podman (rootless too), Compose or Unraid, on amd64 and arm64 (the published image is amd64; build locally for arm64); scripts work in any POSIX shell.
- **Movable setup:** projects, login, settings, history and tools live in one folder — copy it to move to another host.
- **Several instances on one folder:** containers share projects, login and tools; each has its own name and session.
- **Resource caps:** limit CPU and memory with your engine's standard flags.
- **Clean removal:** delete the container and its folder; nothing else is left behind.

## Quick start

Requires Docker or Podman and any POSIX shell (sh, dash, ash, bash, zsh).

```bash
git clone https://github.com/ganesh35/claude-in-container.git && cd claude-in-container
cp .env.example .env    # set DATA_DIR and PUID/PGID; adjust tool versions
scripts/build.sh        # or skip: set IMAGE=ghcr.io/ganesh35/claude-in-container:latest in .env to pull the published image
scripts/run.sh
scripts/attach.sh       # first run: pick a theme, log in with your Claude subscription
```

The published image (`ghcr.io/ganesh35/claude-in-container`, amd64) is tagged with the Claude Code version it carries and `latest`; it is what the Unraid template installs.

The first start installs the tools pinned in `.env` into the data folder (about a minute; `docker logs` shows progress). Later starts only check versions.

Detach with `Ctrl-b d` — Claude keeps running. Open the Claude app → Code, or [claude.ai/code](https://claude.ai/code), and pick the session named after `REMOTE_CONTROL_NAME`.

## Other ways to run

| Method | Command | Notes |
|---|---|---|
| Docker Compose | `mkdir -p data && docker compose up -d --build` | Reads `.env`; on Docker, fails fast if the data folder is missing (it would create it root-owned); Podman creates it owned by you. With `IMAGE=ghcr.io/…` use `up -d --no-build` (pulls; `--build` would tag a local build as that name) |
| Plain docker | see below | |
| Podman (rootless) | `scripts/run.sh` | Adds `--userns keep-id` so files keep your host owner; Compose can't express this portably. All registry images are fully qualified, so Podman's short-name enforcement is never triggered |
| Unraid | [`unraid/claude-in-container.xml`](unraid/claude-in-container.xml) | See [Unraid](#unraid) |

```bash
docker run -d --name claude-in-container --hostname claude-in-container --restart unless-stopped \
  --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges -v "$PWD/data:/data" \
  -e REMOTE_CONTROL_NAME=my-box -e GH_VERSION=2.101.0 -e JQ_VERSION=1.8.2 claude-in-container:local
```

### Unraid

1. Create the data folder owned by the container user: `mkdir -p DIR && chown 99:100 DIR`.
2. Install from **Apps** (Community Applications — search for *claude-in-container*) — or copy the template to `/boot/config/plugins/dockerMan/templates-user/my-claude-in-container.xml` and use Docker → Add Container. Set **Data**, adjust `--user` in Extra Parameters to match the folder's owner, and tool versions under *Show more settings*. The template pulls the published image; to run your own build instead, build it on the server and set Repository to its tag.
3. Open the container console and log in.

## Data folder

One host folder, `DATA_DIR`, is the container's only mount. It must be writable by `PUID:PGID`; `start.sh` stops with a clear message otherwise.

```
DATA_DIR/  → /data        your projects; Claude's working directory
└── .home/ → $HOME        Claude login, ~/.claude, gh, git, aws, shell history, caches
    └── .local/           runtime-installed tools (bin/ comes first on PATH), npm -g, uv tools
```

### What persists

| Where | Restart | Recreate / update / rebuild |
|---|---|---|
| `/data`, including `.home` and installed tools | ✅ | ✅ |
| Anything else in the container | ✅ | ❌ lost |

Keep code under `/data`; project-level tools (`pnpm add -D`, `uv add`) live with the project. Your own `npm install -g` and `uv tool install` land in `.home/.local` and persist too. To move to another host, copy `DATA_DIR` and your `.env`.

### Tools

On every start, `install-tools.sh` installs each tool whose version is set and skips any already at that version, so the first start installs and later ones take a second. Changing a version in `.env` takes effect on the next restart — no rebuild.

| Variable | Installs |
|---|---|
| `GH_VERSION`, `YQ_VERSION`, `JQ_VERSION`, `TERRAFORM_VERSION` | Release binaries, verified against the published SHA256 checksums |
| `AWSCLI_VERSION` | AWS CLI v2, verified by its GPG signature against the AWS CLI key pinned by fingerprint ([`keys/aws-cli.asc`](keys/aws-cli.asc), expires 2027-07-01) |
| `NPM_TOOLS` | Space-separated `name@version` list, via npm |
| `UV_TOOLS` | Space-separated `name==version` list of Python CLIs, via uv |

An empty value installs nothing. A failed download or install is logged and Claude starts without that tool; a **failed checksum or signature check stops the container**. Removing a tool from `.env` doesn't uninstall it. System packages (Python, git, psql, build-essential) are part of the image.

### Several instances

Containers can share one `DATA_DIR`: they see the same projects, login and tools, and a lock lets only one install tools at a time. Keep the tool versions identical across them — different pins on one folder reinstall back and forth on every start. Give each its own name, and set `CONTINUE=false` on all but one — `claude --continue` resumes the latest conversation in `/data`, so instances would otherwise resume the same one.

```sh
scripts/run.sh                                      # main instance, resumes
CONTINUE=false scripts/run.sh --name reviewer       # extra instance, starts fresh
scripts/attach.sh --name reviewer
```

With Compose, use a separate project per instance (`CONTAINER_NAME=reviewer CONTINUE=false docker compose -p reviewer up -d`); on Unraid, add the template again under another name.

For several sessions from one container, set `REMOTE_CONTROL_MODE=server`: `claude remote-control` then waits for requests and starts a new session in `/data` each time you create one in the Claude app, named with the `REMOTE_CONTROL_NAME` prefix. Log in first — without a login it exits at once. Sessions end with the container, and `CONTINUE` is ignored.

## Routines

Optional scheduled headless runs inside the container, with access to everything it can see. Off by default: set `ROUTINES` to the path of a crontab inside the container (e.g. `ROUTINES=/data/routines`, i.e. `DATA_DIR/routines` on the host — or a file in a git repo under `/data`, so the schedule is versioned) and restart once; later edits to the file are picked up automatically. Clear `ROUTINES` to switch routines off without deleting the schedule:

```
# min hour dom mon dow  command
0 8 * * 1-5  routine Summarise new files in /data/family/Scan since yesterday into /data/reports/scan.md
0 * * * *    echo "any shell command works too" >> /data/hourly.log
```

- `routine <prompt>` runs `claude -p --permission-mode auto` in `/data` with the container's login and saves the reply to `/data/routines-output/<UTC time>-<first words>.md`; each run logs one line (`routine: ok|failed -> file`) to the container log.
- The schedule uses [supercronic](https://github.com/aptible/supercronic) syntax (standard cron, plus an optional leading seconds field); a missing or invalid file is logged and skipped, and Claude starts regardless. A file without `ROUTINES` pointing at it does nothing.
- Runs draw on the same Claude usage as interactive sessions, and a run that is still going when the next one is due is skipped.
- Claude Code's own [routines](https://code.claude.com/docs/en/routines) run in Anthropic's cloud against a GitHub checkout and can't see this container; routing them to your own hardware needs a Team or Enterprise plan ([self-hosted environments](https://code.claude.com/docs/en/self-hosted-environments)). These routines are the in-container equivalent.

## Authentication

| Method | Remote Control | How |
|---|---|---|
| Claude subscription (default) | ✅ | Log in once via `scripts/attach.sh`; stored in `DATA_DIR/.home/.claude/` and shared by all instances |
| API key | ❌ subscription-only | Set `ANTHROPIC_API_KEY` in `.env`; use `scripts/attach.sh` |

### GitHub, git and AWS

Configure other tools yourself inside the container. Everything lands in `DATA_DIR/.home`, so it survives restarts and rebuilds and is shared by all instances:

```sh
scripts/attach.sh    # then, in the fallback shell or a new tmux window (Ctrl-b c):
gh auth login && gh auth setup-git    # GitHub CLI, and git push over HTTPS
git config --global user.name "Your Name" && git config --global user.email "you@example.com"
aws configure        # or: aws configure sso
```

Claude can use whatever you configure here, so prefer narrowly scoped credentials — a fine-grained GitHub token limited to the repos it should touch, a least-privilege IAM user or role — and protect `DATA_DIR/.home` like any credential store.

## Configuration (`.env`)

| Variable | Default | Purpose |
|---|---|---|
| `DATA_DIR` | `./data` | The single host folder mounted at `/data` — see [Data folder](#data-folder) |
| `PUID` / `PGID` | `1000` | User the container runs as; must own `DATA_DIR` |
| `REMOTE_CONTROL_NAME` | hostname | Session name in the Claude app |
| `REMOTE_CONTROL_MODE` | `session` | `server`: start new sessions from the Claude app, named with this prefix — see [Several instances](#several-instances) |
| `CONTINUE` | `true` | Resume the last conversation on start; `false` on extra instances |
| `ROUTINES` | empty (off) | Path to a crontab inside the container for scheduled headless runs — see [Routines](#routines) |
| `CLAUDE_CODE_VERSION` | pinned in `Dockerfile` | Claude Code version baked in at build |
| `ANTHROPIC_API_KEY` | — | Optional, replaces the subscription login |
| `GH_VERSION` … `UV_TOOLS` | see `.env.example` | Tools installed on start — see [Tools](#tools) |
| `CONTAINER_ENGINE` | auto (docker, then podman) | e.g. `sudo docker` where docker needs root |
| `IMAGE` / `CONTAINER_NAME` | `claude-in-container:local` / `claude-in-container` | |
| `TEST_SHELLS`, `PLATFORMS`, `PUBLISH_IMAGE`, `GHCR_TOKEN` | see `.env.example` | Maintainer-only: test matrix and publishing; never passed to the container |

Image-level versions (`NODE_IMAGE`, `UV_IMAGE` — both digest-pinned — `PLAYWRIGHT_VERSION`, `PG_MAJOR`) are build args in the [`Dockerfile`](Dockerfile); override with `scripts/build.sh --build-arg NAME=VALUE`.

## Scripts

| Script | Does |
|---|---|
| `scripts/build.sh [args]` | Build the image; extra args go to the engine (e.g. `--platform linux/amd64`) |
| `scripts/run.sh [--replace] [--name <instance>]` | Start the container; `--replace` recreates it, `--name` runs another instance on the same `DATA_DIR` |
| `scripts/attach.sh [--name <instance>]` | Attach to Claude's tmux session |
| `scripts/update.sh [version]` | Pin a Claude Code version (default: latest) in `.env`, rebuild, recreate the main instance (recreate others with `run.sh --replace --name …`) |
| `scripts/lint.sh` | Drift check of variables across `.env.example`, `compose.yaml` and the Unraid template, then shellcheck + hadolint via pinned containers |
| `scripts/test.sh` | End-to-end tests on a throwaway copy; see [Testing](#testing) |
| `scripts/ci.sh` | `lint.sh` then `test.sh` — the CI entrypoint; run it before opening a PR |
| `scripts/outdated.sh` | Report newer versions of pinned tools, Claude Code, Playwright and the Node base image; read-only |
| `scripts/publish.sh` | Build and push to GHCR, tagged with the Claude Code version and `latest`; needs `GHCR_TOKEN` (CI only) |

Compose users update with `CLAUDE_CODE_VERSION=<version>` in `.env`, then `docker compose up -d --build`.

## Testing

`scripts/test.sh` lints, builds a throwaway image and runs the scripts end to end under every installed shell in `TEST_SHELLS` (default `dash ash bash zsh`; missing ones are skipped). It also covers instances sharing a folder and tool installs (missing, current, version change, failure, checksum mismatch, bad signature). It works on a temporary copy without your `.env`, and removes only the containers, image and folders it created.

For all four shells on a Docker host, run it inside an Alpine helper that uses the host's Docker. The shared folder must have the same path on host and helper, because the Docker daemon resolves bind mounts on the host:

```sh
mkdir -p /tmp/cic-test && docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:/repo:ro" -v /tmp/cic-test:/tmp/cic-test -e TMPDIR=/tmp/cic-test -w /repo docker.io/library/alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 \
  sh -c 'apk add -q docker-cli docker-cli-buildx dash bash zsh tar && sh scripts/test.sh'
```

### Under Podman

The suite passes on Podman 5.8 (rootful). Without a Podman host, run it inside Podman's own image on any Docker host — three harness-only adjustments are needed: that image defaults nested containers to the host UTS/network namespaces (so `--hostname` is refused), its healthchecks depend on systemd timers (absent, so status would never leave `starting`), and Fedora has no `ash`:

```sh
docker run --rm --privileged --device /dev/fuse -v "$PWD:/repo:ro" -e CONTAINER_ENGINE=podman -w /repo quay.io/podman/stable sh -c '
  dnf install -y -q dash zsh tar busybox && ln -s "$(command -v busybox)" /usr/local/bin/ash
  printf "[containers]\nutsns = \"private\"\nnetns = \"private\"\n" > /tmp/cc.conf; export CONTAINERS_CONF_OVERRIDE=/tmp/cc.conf
  ( while true; do for c in $(podman ps -q); do podman healthcheck run "$c" >/dev/null 2>&1; done; sleep 5; done ) &
  sh scripts/ci.sh'
```

## Behaviour

- `start.sh` checks `/data` is writable, creates `.home`, runs `install-tools.sh`, then starts `claude --remote-control <name>` in tmux session `main` — with `--continue` (falling back to a fresh session) when `CONTINUE=true`; with `REMOTE_CONTROL_MODE=server` it starts `claude remote-control --remote-control-session-name-prefix <name>` instead.
- If Claude exits you land in a shell inside tmux; restart the container to get it back.
- The container lives as long as the tmux session; `restart: unless-stopped` brings it back.
- Healthcheck: *unhealthy* when the tmux session is up but Claude is not running; a 10-minute start period covers first-start tool installs.
- The Remote Control session URL changes on every restart; the app lists it under the same name.

## Security

- Use a dedicated `DATA_DIR`; never point it at a personal share, `~/.ssh` or cloud credentials you don't want Claude to use.
- `DATA_DIR/.home` holds your logins; anyone who can read the folder (for example over a network share) can read them.
- No ports are exposed; Remote Control connects outbound to claude.ai.
- The container runs with every Linux capability dropped and `no-new-privileges`; nothing in the image needs either.
- Release binaries are fetched HTTPS-only (redirects to plain HTTP are refused) and verified by checksum or signature; base and helper images are pinned by digest. Packages from npm, PyPI and apt rely on those registries' own integrity checks.
- The auto-updater is disabled; updates happen only by rebuilding.
- Keep `.env` out of git (already ignored).

## Troubleshooting

| Symptom | Check |
|---|---|
| No session in the Claude app | `docker exec <name> tmux capture-pane -p -t main` — a prompt may be waiting |
| Container exits: `/data is not writable` | `chown PUID:PGID DATA_DIR` |
| Asked to log in again | `DATA_DIR/.home` must be writable by `PUID:PGID` |
| A tool is missing | `docker logs <name>` shows a `tools:` line per tool, with the error for failed installs |
| `Permission denied` on project files | `PUID`/`PGID` don't match the folder owner |
| Healthcheck missing under Podman | Build with `scripts/build.sh` (adds `--format docker`) |

## Upgrading from the two-folder layout

Earlier versions mounted `WORKSPACE_DIR` at `/workspace` and `CLAUDE_HOME_DIR` at `/home/node`. To keep your projects in place, make the old workspace the data folder and move the home into it:

```sh
docker rm -f claude-in-container                              # your container name
mv "$CLAUDE_HOME_DIR" "$WORKSPACE_DIR/.home"
# Claude keys history and folder settings by path; follow the /workspace -> /data move
cd "$WORKSPACE_DIR/.home"
for d in .claude/projects/-workspace .claude/projects/-workspace-*; do [ -e "$d" ] && mv "$d" ".claude/projects/-data${d#.claude/projects/-workspace}"; done
sed -i.bak 's#"/workspace\([/"]\)#"/data\1#g' .claude.json && rm .claude.json.bak
```

Then in `.env` replace `WORKSPACE_DIR` and `CLAUDE_HOME_DIR` with `DATA_DIR=<old WORKSPACE_DIR>`, copy the Tools section from `.env.example`, and run `scripts/build.sh && scripts/run.sh`. On Unraid, replace the Workspace and Home paths with a single Data path (`/data`) and add the new variables from the template.

## License

[MIT](LICENSE)
