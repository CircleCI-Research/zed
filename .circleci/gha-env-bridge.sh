#!/usr/bin/env bash
# Runs a repo script that expects the GitHub Actions step contract and forwards
# whatever it exports into CircleCI's per-step environment file.
#
# script/setup-sccache publishes RUSTC_WRAPPER, SCCACHE_* and AWS_* to later
# steps by appending to $GITHUB_ENV, and prepends the sccache directory to
# $GITHUB_PATH. Neither variable exists on CircleCI, so a direct port would set
# those variables in a subshell that exits immediately: the build would still be
# correct but every cache hit would be lost and `sccache --show-stats` would
# fail. This wrapper points GITHUB_ENV/GITHUB_PATH at scratch files and
# translates them into $BASH_ENV, which CircleCI sources before each step.
#
# Only the single-line `KEY=value` form of $GITHUB_ENV is translated; the
# heredoc form (`KEY<<DELIM`) is not used by any script this wraps.
#
# Usage: .circleci/gha-env-bridge.sh <command> [args...]

set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 1
fi

: "${BASH_ENV:?BASH_ENV is not set; this script only runs inside a CircleCI run step}"

scratch="$(mktemp -d)"
GITHUB_ENV="${scratch}/env"
GITHUB_PATH="${scratch}/path"
GITHUB_OUTPUT="${scratch}/output"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
export GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT GITHUB_WORKSPACE
: >"$GITHUB_ENV"
: >"$GITHUB_PATH"
: >"$GITHUB_OUTPUT"

"$@"

while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
    *=*) ;;
    *)
        echo "gha-env-bridge: ignoring unrecognised GITHUB_ENV line: ${line}" >&2
        continue
        ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    printf 'export %s=%q\n' "$key" "$value" >>"$BASH_ENV"
done <"$GITHUB_ENV"

while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    # shellcheck disable=SC2016  # $PATH must stay literal in the emitted line.
    printf 'export PATH=%q:"$PATH"\n' "$entry" >>"$BASH_ENV"
done <"$GITHUB_PATH"

echo "gha-env-bridge: forwarded $(grep -c '^export ' "$BASH_ENV" || true) exports into \$BASH_ENV"
