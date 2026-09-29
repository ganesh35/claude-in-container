# Version check

Goal: keep the Claude Code version baked into the image current. You may merge the pull request this playbook creates, and no other.

1. `cd /data/claude-in-container && git checkout main && git pull --ff-only`. If the working tree is dirty, stop and report.
2. `pinned` = the value of `ARG CLAUDE_CODE_VERSION=` in `Dockerfile`; `latest` = `npm view @anthropic-ai/claude-code version`.
3. If `latest` equals `pinned`, report "up to date" and stop.
4. If an open pull request titled `chore(deps): bump Claude Code to <latest>` already exists, continue at step 7 with it.
5. Check `npm view @anthropic-ai/claude-code@<latest> engines.node` still accepts the Node major in `NODE_IMAGE` in the Dockerfile. If it doesn't, open an issue titled `Claude Code <latest> needs a newer Node` and stop.
6. On a branch `chore/claude-code-<latest>`, change only that one `ARG` line, commit `chore(deps): bump Claude Code to <latest>`, push, and open a pull request with that title and a one-line body.
7. Wait for the pull request's checks (`gh pr checks <n> --watch`, up to 30 minutes).
   - All passed: `gh pr merge <n> --squash --delete-branch`. CI publishes and releases from `main`.
   - Any failed: do not merge. Comment on the pull request with the failing check's name and the relevant lines of its log, and leave it open.
8. Report what you did in one short paragraph.

Never edit any other file, never push to `main`, and never merge a pull request you didn't open in step 6.
