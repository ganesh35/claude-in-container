# Maintenance playbooks

Instructions for an unattended maintainer: a claude-in-container instance whose `ROUTINES` crontab runs these on a schedule, e.g.

```
0 */5 * * *   routine Follow /data/claude-in-container/maintenance/version-check.md exactly
30 */5 * * *  routine Follow /data/claude-in-container/maintenance/issue-triage.md exactly
```

The maintainer needs its own clone of this repository at `/data/claude-in-container` and a GitHub login (`gh auth login`) whose token can reach **only this repository**, with read/write on Contents, Pull requests and Issues. It makes changes through pull requests only; deploying is CI's job once something reaches `main`.
