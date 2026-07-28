#!/bin/bash
# Branch resolution shared by the numbered build scripts.
#
# Every component repo used to be checked out at "whatever branch THIS meta repo is
# on". That breaks the moment the meta repo carries a variant branch a component does
# not have: `git clone -b wip/3d-accel-kgsl` just fails with "couldn't find remote ref".
#
# The development line lives on ONE trunk in every repo (wip/3d-accel). Variants exist
# only where the content genuinely differs -- this meta repo (launchers, plans, which
# mesa to build) and mesa (two unrelated upstreams). So resolution is a fallback chain:
#
#     wip/3d-accel-<variant>   ->   wip/3d-accel   ->   (soong forks) the manifest revision
#
# Source this after `cd "$(dirname "$0")"`.

BRANCH=$(git rev-parse --abbrev-ref HEAD)
TRUNK=${TRUNK:-wip/3d-accel}

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

# The branch the trunk replaced. Kept in the chain so a fresh clone still works against
# remotes that have not been published yet, but selecting it is REPORTED (see warn_legacy):
# a component silently left on the old branch while the rest moved to the trunk is the
# crosvm/gfxstream ABI skew whose failures are all silent. Unset it once every repo has
# published wip/3d-accel.
LEGACY=${LEGACY:-wip/3d-accel-gfxstream}

# branch_chain -- the fallback chain for a component repo, most specific first.
branch_chain() {
    local c=$TRUNK
    [ "$BRANCH" = "$TRUNK" ] || c="$BRANCH $TRUNK"
    [ -z "$LEGACY" ] || c="$c $LEGACY"
    printf '%s' "$c"
}

warn_legacy() {
    [ -n "$LEGACY" ] && [ "$1" = "$LEGACY" ] || return 0
    echo "warning: $2 has no $TRUNK yet -- falling back to $LEGACY" >&2
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
    warn_legacy "$b" "$dir"
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
    b=$(pick droidvm $(branch_chain))
    if [ -z "$b" ]; then
        echo ">>> $d: no $(branch_chain) on droidvm, keeping the manifest revision $(git -C "$d" rev-parse --short HEAD)"
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
    warn_legacy "$b" "$d"
    echo ">>> $d @ $b $(git -C "$d" rev-parse --short HEAD)"
}
