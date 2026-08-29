#!/usr/bin/env bash
# Port of the `orchestrate` job from .github/workflows/run_tests.yml.
#
# GitHub Actions lets a job publish `outputs` that downstream jobs consult in
# their `if:` expressions. CircleCI has no cross-job outputs, so the equivalent
# is a setup pipeline that writes pipeline *parameters* which the continuation
# config declares. This script produces that parameter file.
#
# Requires GNU grep (`-P`) and jq. Both are present on the CircleCI Linux
# convenience images; neither is present on stock macOS.

set -euo pipefail

OUTPUT_PATH="${1:-/tmp/pipeline-parameters.json}"

command -v jq >/dev/null || {
    echo "jq is required to emit pipeline parameters" >&2
    exit 1
}

# The repository-owner allowlist gate lives in the setup job in
# .circleci/config.yml, which halts before this script ever runs.
#
# Forwarded from the setup config's pipeline parameters. In GitHub Actions these
# are PR labels (`run-nix`, `run-bundling`); CircleCI cannot read PR labels, so
# they arrive as pipeline parameters on an API trigger.
RUN_NIX="${ZED_CI_RUN_NIX:-false}"
RUN_BUNDLING="${ZED_CI_RUN_BUNDLING:-false}"

run_tests=false
run_docs=false
run_licenses=false
run_action_checks=false
changed_packages=""
changed_extensions=""

emit() {
    jq -n \
        --argjson run_tests "$run_tests" \
        --argjson run_docs "$run_docs" \
        --argjson run_licenses "$run_licenses" \
        --argjson run_action_checks "$run_action_checks" \
        --arg changed_packages "$changed_packages" \
        --arg changed_extensions "$changed_extensions" \
        --argjson run_nix "$RUN_NIX" \
        --argjson run_bundling "$RUN_BUNDLING" \
        '{
            run_tests: $run_tests,
            run_docs: $run_docs,
            run_licenses: $run_licenses,
            run_action_checks: $run_action_checks,
            changed_packages: $changed_packages,
            changed_extensions: $changed_extensions,
            run_nix: $run_nix,
            run_bundling: $run_bundling
        }' >"$OUTPUT_PATH"
    echo "Wrote pipeline parameters to $OUTPUT_PATH:"
    cat "$OUTPUT_PATH"
}

# GitHub Actions distinguishes PR context from push context via
# GITHUB_BASE_REF. CircleCI has no equivalent: CIRCLE_PULL_REQUEST is only
# populated for some project/VCS combinations. run_tests.yml pushes only ever
# fire on `main` and `v<major>.<minor>.x`, so any other branch is PR context.
branch="${CIRCLE_BRANCH:-}"
if [ "$branch" = "main" ] || printf '%s' "$branch" | grep -qE '^v[0-9]+\.[0-9]+\.x$'; then
    pr_context=false
else
    pr_context=true
fi

if [ "$pr_context" = "false" ]; then
    echo "Not in a PR context (i.e., push to main/stable/preview)"
    COMPARE_REV="$(git rev-parse HEAD~1)"
else
    base_branch="${ZED_CI_PR_BASE_BRANCH:-main}"
    echo "In a PR context comparing to ${base_branch}"
    # No --depth here: unlike actions/checkout, CircleCI's `checkout` step
    # produces a full clone, and a depth-limited fetch would *introduce* a
    # shallow boundary that breaks `git merge-base`.
    git fetch origin "$base_branch"
    COMPARE_REV="$(git merge-base "origin/${base_branch}" HEAD)"
fi
CHANGED_FILES="$(git diff --name-only "$COMPARE_REV" "${CIRCLE_SHA1:-HEAD}")"

# Mirrors the shape of run_tests.yml's check_pattern(): $2 is the grep flag set
# so that the `run_tests` filter can keep using its inverted match.
check_pattern() {
    local pattern="$1"
    local grep_arg="$2"
    if echo "$CHANGED_FILES" | grep "$grep_arg" "$pattern"; then
        echo true
    else
        echo false
    fi
}

if [ "$pr_context" = "false" ]; then
    echo "Not a PR, running full test suite"
    changed_packages=""
elif echo "$CHANGED_FILES" | grep -qP '^(rust-toolchain\.toml|\.cargo/|\.github/|\.circleci/|Cargo\.(toml|lock)$)'; then
    echo "Toolchain, cargo config, or root Cargo files changed, will run all tests"
    changed_packages=""
else
    CHANGED_DIRS=$(echo "$CHANGED_FILES" |
        grep -oP '^(crates|tooling)/\K[^/]+' |
        sort -u || true)

    DIR_TO_PKG=$(cargo metadata --format-version=1 --no-deps 2>/dev/null |
        jq -r '.packages[] | select(.manifest_path | test("crates/|tooling/")) | "\(.manifest_path | capture("(crates|tooling)/(?<dir>[^/]+)") | .dir)=\(.name)"')

    FILE_CHANGED_PKGS=""
    for dir in $CHANGED_DIRS; do
        pkg=$(echo "$DIR_TO_PKG" | grep "^${dir}=" | cut -d= -f2 | head -1 || true)
        # Directories that are not root-workspace members (e.g. tooling/lints)
        # have no mapping. Skipping them leaves the package set empty, which
        # falls through to the "run all tests" path, rather than fabricating a
        # bogus package name that makes nextest hard-error.
        if [ -n "$pkg" ]; then
            FILE_CHANGED_PKGS=$(printf '%s\n%s' "$FILE_CHANGED_PKGS" "$pkg")
        fi
    done
    FILE_CHANGED_PKGS=$(echo "$FILE_CHANGED_PKGS" | grep -v '^$' | sort -u || true)

    if echo "$CHANGED_FILES" | grep -qP '^assets/'; then
        FILE_CHANGED_PKGS=$(printf '%s\n%s\n%s' "$FILE_CHANGED_PKGS" "settings" "assets" | sort -u)
    fi

    ALL_CHANGED_PKGS=$(echo "$FILE_CHANGED_PKGS" | grep -v '^$' || true)

    if [ -z "$ALL_CHANGED_PKGS" ]; then
        echo "No package changes detected, will run all tests"
        changed_packages=""
    else
        changed_packages=$(echo "$ALL_CHANGED_PKGS" |
            sed 's/.*/rdeps(&)/' |
            tr '\n' '|' |
            sed 's/|$//')
        echo "Changed packages filterset: $changed_packages"
    fi
fi

run_action_checks=$(check_pattern '^\.github/(workflows/|actions/|actionlint.yml)|^\.circleci/|tooling/xtask|script/' -qP)
run_docs=$(check_pattern '^(docs/|crates/.*\.rs)' -qP)
run_licenses=$(check_pattern '^(Cargo.lock|script/.*licenses)' -qP)
run_tests=$(check_pattern '^(docs/|script/update_top_ranking_issues/|\.github/(ISSUE_TEMPLATE|workflows/(?!run_tests))|extensions/)' -qvP)

# Detect changed extension directories (excluding extensions/workflows).
CHANGED_EXTENSIONS=$(echo "$CHANGED_FILES" | grep -oP '^extensions/[^/]+(?=/)' | sort -u | grep -v '^extensions/workflows$' || true)
EXISTING_EXTENSIONS=""
for ext in $CHANGED_EXTENSIONS; do
    if [ -f "$ext/extension.toml" ]; then
        EXISTING_EXTENSIONS=$(printf '%s\n%s' "$EXISTING_EXTENSIONS" "$ext")
    fi
done
# GitHub Actions fans these out with a `strategy.matrix` built from JSON at run
# time. CircleCI matrices must be fully known at config-compile time, so the
# list is emitted as a space-separated string and the extension_tests job loops
# over it. The source workflow pinned max-parallel: 1, so nothing is lost.
changed_extensions=$(echo "$EXISTING_EXTENSIONS" | sed '/^$/d' | tr '\n' ' ' | sed 's/ *$//')

emit
