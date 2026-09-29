#!/bin/sh
# Security scans with pinned scanner images (nothing to install).
# Usage: scripts/security.sh          secrets in the repo files and Dockerfile misconfigurations
#        scripts/security.sh IMAGE    vulnerabilities in a built image: fails on fixable CRITICAL, reports fixable HIGH
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"
trivy=docker.io/aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969

cd "$ROOT"
if [ $# -eq 0 ]; then
  # Tracked plus untracked-but-not-ignored files: whatever a commit could contain, never .env
  git ls-files -co --exclude-standard | COPYFILE_DISABLE=1 tar -c -T - | engine run --rm -i --entrypoint sh \
    docker.io/zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f \
    -c 'mkdir /src && cd /src && tar -x && gitleaks dir . --no-banner --redact'
  COPYFILE_DISABLE=1 tar -c Dockerfile | engine run --rm -i --entrypoint sh "$trivy" \
    -c 'mkdir /src && cd /src && tar -x && trivy config --quiet --exit-code 1 --severity MEDIUM,HIGH,CRITICAL .'
else
  # Unfixed findings can't be acted on; the second pass reuses the database the first one downloaded
  engine save "$1" | engine run --rm -i --entrypoint sh "$trivy" -c 'cat >/tmp/image.tar &&
    trivy image --quiet --input /tmp/image.tar --ignore-unfixed --severity HIGH &&
    trivy image --quiet --input /tmp/image.tar --ignore-unfixed --skip-db-update --severity CRITICAL --exit-code 1'
fi
echo "Security scan passed"
