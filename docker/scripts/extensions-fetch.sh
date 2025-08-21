#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./extensions-fetch.sh docker/extensions/extensions.yaml /var/www/html
#
# Notes:
# - Requires: curl, git, yq (mikefarah yq v4+)
#
# Installation paths:
#   - Extensions → /var/www/html/extensions
#   - Skins      → /var/www/html/skins
#
# - YAML supports:
#     inherits: <url-or-path>
#     extensions:
#       - Name
#       - Name:
#           repository: <git url>
#           branch: <git branch>
#           tag: <git tag>
#           commit: <git sha>
#           version: <semantic version, optional — for doc only>
#     skins: (same as extensions)

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <yaml> <mw_root>"
  exit 1
fi

YAML="$1"
MW_ROOT="$2"
EXT_DIR="$MW_ROOT/extensions"
SKIN_DIR="$MW_ROOT/skins"

mkdir -p "$EXT_DIR" "$SKIN_DIR"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: '$1' is required but not installed." >&2; exit 1;
  }
}
require_cmd curl
require_cmd git
require_cmd yq

# ------------- helpers -------------
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

download_if_url() {
  local ref="$1" out="$2"
  if [[ "$ref" =~ ^https?:// ]]; then
    curl -fsSL "$ref" -o "$out"
  else
    cp "$ref" "$out"
  fi
}

git_checkout_ref() {
  local repo="$1" dir="$2" branch="${3:-}" tag="${4:-}" commit="${5:-}"

  # 1) Exact commit
  if [[ -n "$commit" ]]; then
    git -C "$dir" fetch --depth 1 origin "$commit"
    git -C "$dir" checkout --detach "$(git -C "$dir" rev-parse FETCH_HEAD)"
    git -C "$dir" submodule update --init --depth 1 || true
    return
  fi

  # 2) Tag
  if [[ -n "$tag" ]]; then
    git -C "$dir" fetch --depth 1 --tags origin "refs/tags/$tag:refs/tags/$tag" || true
    git -C "$dir" checkout -f "tags/$tag"
    git -C "$dir" submodule update --init --depth 1 || true
    return
  fi

  # 3) Branch (default REL1_43 if none provided)
  local want="${branch:-REL1_43}"

  # Write the remote branch directly into a *local branch* ref, then check it out.
  # This avoids the “starting point 'origin/REL1_43' is not a branch” error on shallow clones.
  git -C "$dir" fetch --depth 1 origin "refs/heads/$want:refs/heads/$want" \
    || git -C "$dir" fetch --depth 1 origin "$want"

  # Now checkout the local branch ref
  if git -C "$dir" rev-parse --verify "$want" >/dev/null 2>&1; then
    git -C "$dir" checkout -f "$want"
  else
    # fallback to FETCH_HEAD if ref name didn’t land for some reason
    git -C "$dir" checkout -B "$want" "$(git -C "$dir" rev-parse FETCH_HEAD)"
  fi

  # Set upstream (nice to have; not required)
  git -C "$dir" branch --set-upstream-to="origin/$want" "$want" 2>/dev/null || true

  git -C "$dir" submodule update --init --depth 1 || true
}


ensure_repo() {
  local name="$1" repo="$2" target_base="$3"
  local clone_branch="${4:-}"          # optional: branch to clone/fetch
  local target="$target_base/$name"

  # If directory exists but isn't a git repo, reset it
  if [[ -d "$target" && ! -d "$target/.git" ]]; then
    echo "[reset]  $name (non-git directory present)"
    rm -rf "$target"
  fi

  if [[ -d "$target/.git" ]]; then
    echo "[update] $name"
    git -C "$target" remote set-url origin "$repo" || true
    if [[ -n "$clone_branch" ]]; then
      # Shallow fetch only the requested branch (and create/update local branch ref)
      git -C "$target" fetch --prune --depth 1 origin "refs/heads/$clone_branch:refs/heads/$clone_branch" \
        || git -C "$target" fetch --prune --depth 1 origin "$clone_branch"
    else
      # Generic shallow fetch of all remotes/tags
      git -C "$target" fetch --all --prune --tags --depth 1
    fi
  else
    echo "[clone]  $name"
    if [[ -n "$clone_branch" ]]; then
      git clone --depth 1 --single-branch --branch "$clone_branch" "$repo" "$target"
    else
      git clone --depth 1 "$repo" "$target"
    fi
  fi
}

install_items() {
  local section="$1" target_dir="$2" defaults_repo_base="$3"

  local count
  count="$(yq eval ".${section} | length" "$tmpdir/merged.yaml" 2>/dev/null || echo 0)"
  [[ "$count" == "null" ]] && count=0

  for i in $(seq 0 $((count-1))); do
    # detect node type
    local node_type name repo branch tag commit
    node_type="$(yq eval ".[${i}] | type" "$tmpdir/${section}.yaml")"

    if [[ "$node_type" == "!!str" ]]; then
      name="$(yq eval ".[${i}]" "$tmpdir/${section}.yaml")"
      if [[ "$section" == "extensions" ]]; then
        repo="${defaults_repo_base}/extensions/${name}"
      else
        repo="${defaults_repo_base}/skins/${name}"
      fi
      branch=""  # none specified in YAML
      tag=""
      commit=""
    else
      name="$(yq eval ".[${i}] | keys | .[0]" "$tmpdir/${section}.yaml")"
      repo="$(yq eval -r ".[${i}].${name}.repository // \"\"" "$tmpdir/${section}.yaml")"
      branch="$(yq eval -r ".[${i}].${name}.branch // \"\"" "$tmpdir/${section}.yaml")"
      tag="$(yq eval -r ".[${i}].${name}.tag // \"\"" "$tmpdir/${section}.yaml")"
      commit="$(yq eval -r ".[${i}].${name}.commit // \"\"" "$tmpdir/${section}.yaml")"
      if [[ -z "$repo" ]]; then
        if [[ "$section" == "extensions" ]]; then
          repo="${defaults_repo_base}/extensions/${name}"
        else
          repo="${defaults_repo_base}/skins/${name}"
        fi
      fi
    fi

    # normalize shorthands (optional)
    case "$repo" in
      gerrit:*) repo="https://gerrit.wikimedia.org/r/mediawiki/${repo#gerrit:}";;
      github:*) repo="https://github.com/${repo#github:}";;
    esac

    # >>> This is the line you asked about (pass $branch as arg 4)
    ensure_repo "$name" "$repo" "$target_dir" "$branch"

    # then checkout the exact ref (commit/tag/branch)
    git_checkout_ref "$repo" "$target_dir/$name" "$branch" "$tag" "$commit"
  done
}


# ------------- merge YAMLs -------------
# 1) Read local YAML
cp "$YAML" "$tmpdir/base.yaml"

# 2) If 'inherits:' present, download and merge (inherited first, then override)
INH="$(yq eval -r '.inherits // ""' "$tmpdir/base.yaml")"
if [[ -n "$INH" && "$INH" != "null" ]]; then
  download_if_url "$INH" "$tmpdir/inherited.yaml"
  # Merge strategy: inherited + override (override fields win)
  yq eval-all 'select(fileIndex == 0) *+ select(fileIndex == 1)' "$tmpdir/inherited.yaml" "$tmpdir/base.yaml" > "$tmpdir/merged.yaml"
else
  cp "$tmpdir/base.yaml" "$tmpdir/merged.yaml"
fi

# Split sections for easier looping
yq eval '.extensions // []' "$tmpdir/merged.yaml" > "$tmpdir/extensions.yaml"
yq eval '.skins // []' "$tmpdir/merged.yaml" > "$tmpdir/skins.yaml"

# ------------- install -------------
# Default Gerrit base (used if repository not specified in YAML)
GERRIT_BASE="https://gerrit.wikimedia.org/r/mediawiki"

install_items "extensions" "$EXT_DIR" "$GERRIT_BASE"
install_items "skins" "$SKIN_DIR" "$GERRIT_BASE"

echo "Done. Extensions installed to $EXT_DIR, skins to $SKIN_DIR."
