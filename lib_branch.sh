#!/bin/bash
# Branch resolution shared by the numbered build scripts.
#
# Every component repo used to be checked out at "whatever branch THIS meta repo is
# on". That breaks the moment the meta repo carries a branch a component does not
# have: `git clone -b <branch>` just fails with "couldn't find remote ref" -- and a
# piece of work touches only a few components, so most of them do not have it.
#
# So resolution is a two-step chain. The DEVELOPMENT branch comes first and is simply
# this meta repo's branch: a component takes part in a piece of work by carrying a
# branch of the same name. A component the work does not touch has no such branch and
# falls back to its STABLE branch, which the org keeps under one name in every repo,
# `droidvm` -- except the app, whose stable branch is `master` (6_build_apk_prepare.sh):
#
#     <this meta repo's branch>   ->   droidvm   ->   (soong forks) the manifest revision
#
# Source this after `cd "$(dirname "$0")"`.

BRANCH=$(git rev-parse --abbrev-ref HEAD)
# The stable branch. Override it per call for the one repo that names it differently,
# `STABLE=master clone_at ...` -- an assignment in front of a function call is scoped to
# that call in bash.
STABLE=${STABLE:-droidvm}

if [ "$BRANCH" = HEAD ]; then
    echo "error: meta repo is in detached HEAD -- check out a branch first" >&2
    exit 1
fi

# pick <remote-or-url> <branch>...
# Prints the first branch that exists there. Prints nothing and returns 0 if none do,
# so callers can test for the empty string without tripping `set -e`.
pick() {
    local where=$1 b
    shift
    for b in "$@"; do
        if git ls-remote --exit-code --heads "$where" "refs/heads/$b" >/dev/null 2>&1; then
            printf '%s' "$b"
            return 0
        fi
    done
    return 0
}

# branch_chain -- the fallback chain for a component repo, most specific first.
branch_chain() {
    if [ "$BRANCH" = "$STABLE" ]; then
        printf '%s' "$STABLE"
    else
        printf '%s %s' "$BRANCH" "$STABLE"
    fi
}

# clone_at <dir> <url> [extra-branch...]
# Clone <dir> at the first branch of the chain that exists on <url>. An existing
# checkout is REPORTED, never silently switched -- the tree may hold uncommitted work,
# and a build that quietly changed branches under you is the worst kind of surprise.
# Set REPO_SWITCH=1 to opt into switching.
clone_at() {
    local dir=$1 url=$2 b
    shift 2
    if [ -d "$dir" ]; then
        b=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
        if [ -n "${REPO_SWITCH:-}" ]; then
            b=$(pick "$url" $(branch_chain) "$@")
            [ -n "$b" ] || { echo "error: $url has none of: $(branch_chain) $*" >&2; exit 1; }
            git -C "$dir" fetch -q origin "$b"
            git -C "$dir" checkout -q -B "$b" FETCH_HEAD
        fi
        echo ">>> $dir: on $b $(git -C "$dir" rev-parse --short HEAD)"
        return 0
    fi
    b=$(pick "$url" $(branch_chain) "$@")
    [ -n "$b" ] || { echo "error: $url has none of: $(branch_chain) $*" >&2; exit 1; }
    echo ">>> cloning $dir at $b"
    git clone -b "$b" "$url" "$dir"
}

# checkout_soong <dir> <repo-name>
# Point a repo-synced soong-tree fork at the chain. Unlike clone_at these trees are
# managed by `repo`, so the manifest revision is the last resort and a force-move of a
# local branch could discard unpushed work -- refuse rather than lose it.
checkout_soong() {
    local d=$1 name=$2 url b
    url="https://github.com/Droid-VM/$name.git"
    git -C "$d" remote get-url droidvm >/dev/null 2>&1 || git -C "$d" remote add droidvm "$url"
    # Ask the URL, not the remote name. `pick` runs git in the CURRENT directory -- the meta
    # repo -- where "droidvm" is not a remote, so the name form fails to resolve for every
    # branch in the chain and every soong fork silently kept its manifest revision instead.
    # It failed as ">>> ... keeping the manifest revision", which reads like a decision.
    b=$(pick "$url" $(branch_chain))
    if [ -z "$b" ]; then
        echo ">>> $d: $url has none of: $(branch_chain) -- keeping the manifest revision $(git -C "$d" rev-parse --short HEAD)"
        return 0
    fi
    git -C "$d" fetch -q droidvm "$b"
    if git -C "$d" rev-parse --verify -q "refs/heads/$b" >/dev/null &&
       ! git -C "$d" merge-base --is-ancestor "$b" FETCH_HEAD; then
        echo "error: $d local $b has commits the fetched $b does not" >&2
        echo "       checkout -B would discard them; push or rebase first (recover: git -C $d reflog)" >&2
        exit 1
    fi
    git -C "$d" checkout -q -B "$b" FETCH_HEAD
    echo ">>> $d @ $b $(git -C "$d" rev-parse --short HEAD)"
}
