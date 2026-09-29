#!/bin/sh
# Lint shell scripts and the Dockerfile using pinned linter images (nothing to install)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

cd "$ROOT"
# Container variables are repeated in .env.example, compose.yaml and the Unraid template; fail on any drift
tpl=unraid/claude-in-container.xml drift=0
for v in $CONTAINER_ENV; do
  env=$(sed -n "s/^$v=//p" .env.example | tr -d '"')
  def=$(sed -n "s/.*Target=\"$v\" Default=\"\([^\"]*\)\".*/\1/p" "$tpl")
  val=$(sed -n "s/.*Target=\"$v\" .*>\([^<]*\)<\/Config>.*/\1/p" "$tpl")
  if [ "$env" != "$def" ] || [ "$env" != "$val" ]; then
    echo "Drift: $v is '$env' in .env.example, template Default '$def', value '$val'" >&2
    drift=1
  fi
  grep -qw "$v" compose.yaml || {
    echo "Drift: $v missing from compose.yaml" >&2
    drift=1
  }
  grep -q "Target=\"$v\"" "$tpl" || {
    echo "Drift: $v missing from $tpl" >&2
    drift=1
  }
done
[ "$drift" -eq 0 ] || exit 1
echo "No drift between .env.example, compose.yaml and $tpl"

# Files are streamed in, not mounted, so this also works where the engine can't see the repo path. No AppleDouble files from macOS tar.
stream() { COPYFILE_DISABLE=1 tar -c "$@"; }
shell="start.sh install-tools.sh routine.sh scripts"
# Code quality: shellcheck with the optional checks in .shellcheckrc, hadolint
# shellcheck disable=SC2086 # word-split file list
stream .shellcheckrc $shell | engine run --rm -i -e LANG=C.UTF-8 --entrypoint sh docker.io/koalaman/shellcheck-alpine:v0.11.0@sha256:9955be09ea7f0dbf7ae942ac1f2094355bb30d96fffba0ec09f5432207544002 \
  -c 'mkdir /src && cd /src && tar -x && shellcheck start.sh install-tools.sh routine.sh scripts/*.sh'
# DL3008: apt versions are not pinned; Debian drops old ones, and the digest-pinned base keeps builds reproducible
engine run --rm -i docker.io/hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d hadolint --ignore DL3008 - <Dockerfile
# Formatting: shfmt and editorconfig-checker both follow .editorconfig; fix with shfmt -w
# shellcheck disable=SC2086 # word-split file list
stream .editorconfig $shell | engine run --rm -i --entrypoint sh docker.io/mvdan/shfmt:v3.14.1-alpine@sha256:c7a0dfa73dfea80e9d9e185c655b44759eea2df85dec142295bcc0bb600c6266 \
  -c 'mkdir /src && cd /src && tar -x && shfmt -d .'
# Git's file list where there is one: never .env, .git or data folders
{ git ls-files -co --exclude-standard 2>/dev/null || find . -type f | sed 's|^\./||'; } | stream -T - | engine run --rm -i --entrypoint sh docker.io/mstruebing/editorconfig-checker:4.0.2@sha256:2ba6232bfa0058f72f5f7d7816711590aa764afab1542af30b3ecb4553587918 \
  -c 'mkdir /src && cd /src && tar -x && editorconfig-checker -no-color'
# YAML against .yamllint; the XML files must parse (Unraid silently drops a broken template)
stream .yamllint compose.yaml unraid ca_profile.xml | engine run --rm -i --entrypoint sh docker.io/pipelinecomponents/yamllint:0.35.13@sha256:5ab5eb7da0ed5e606b07c1723fc8b275e925189f70ac259b26b7329cb5f8f44d \
  -c 'mkdir /src && cd /src && tar -x && yamllint --strict compose.yaml && python3 -c "import sys, xml.dom.minidom as m; [m.parse(f) for f in sys.argv[1:]]" unraid/*.xml ca_profile.xml'
echo "Lint passed"
