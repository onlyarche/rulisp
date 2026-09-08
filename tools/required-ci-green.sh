#!/bin/sh
# required-ci-green.sh SHA
#
# docs/stability.md §5 says a host is supported exactly when it is a
# REQUIRED CI job, and docs/releasing.md step 4 says never to tag on a red
# run. This makes both checkable: exit 0 iff the latest ci.yml run for SHA
# has every job whose name ends in "(required)", plus the MSRV job,
# concluded "success". No run, a run still in progress, or a missing job
# is a refusal — the tag comes after the wait, not before it. blobs.yml's
# release job runs this before it attaches a single asset.
#
# Needs `gh` (any version: only `gh api` is used) with a token that can
# read Actions. REPO defaults to $GITHUB_REPOSITORY, then the checkout's
# origin. Self-test hook: JOBS_TSV=<file> skips the lookup and judges the
# given "name<TAB>status<TAB>conclusion" lines instead.
set -e
SHA=$1
[ -n "$SHA" ] || { echo "usage: required-ci-green.sh SHA"; exit 2; }
REPO=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}
MIN_REQUIRED=${MIN_REQUIRED:-6}   # five "(required)" hosts + MSRV today

TSV=${JOBS_TSV:-}
if [ -z "$TSV" ]; then
    RUN=$(gh api "repos/$REPO/actions/workflows/ci.yml/runs?head_sha=$SHA&per_page=20" \
              --jq '.workflow_runs | sort_by(.created_at) | last | .id // empty')
    [ -n "$RUN" ] || { echo "release refused: no CI run for $SHA — push the commit, let CI finish, then tag"; exit 1; }
    TSV=$(mktemp)
    gh api "repos/$REPO/actions/runs/$RUN/jobs?per_page=100" \
        --jq '.jobs[] | "\(.name)\t\(.status)\t\(.conclusion // "none")"' > "$TSV"
    echo "CI run $RUN for $SHA:"
fi
cat "$TSV"

n=$(awk -F'\t' '$1 ~ /\(required\)$/ || $1 ~ /^MSRV / {n++} END {print n+0}' "$TSV")
if [ "$n" -lt "$MIN_REQUIRED" ]; then
    echo "release refused: only $n required jobs found (expected at least $MIN_REQUIRED) — were the job names changed?"
    exit 1
fi
bad=$(awk -F'\t' '($1 ~ /\(required\)$/ || $1 ~ /^MSRV /) && $3 != "success" {print "  " $1 " -> " $2 "/" $3}' "$TSV")
if [ -n "$bad" ]; then
    printf 'release refused: required CI job not green on %s:\n%s\n' "$SHA" "$bad"
    exit 1
fi
echo "required CI jobs green on $SHA ($n jobs)"
