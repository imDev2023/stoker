#!/usr/bin/env bash
# Fetches the spike's dependencies into lib/ at pinned revisions.
# No git submodule and nothing under lib/ is committed (the ticket's rule); this file is the pin.
# The revisions match the v4 hooks knowledge base's hooks/foundry.lock, so the two workspaces
# compile against the same v4-core, v4-periphery and OpenZeppelin uniswap-hooks.
set -euo pipefail
cd "$(dirname "$0")/.."

fetch() {
  local dir=$1 url=$2 rev=$3
  if [ ! -d "lib/$dir/.git" ]; then
    git clone --quiet "$url" "lib/$dir"
  fi
  git -C "lib/$dir" fetch --quiet origin "$rev" 2>/dev/null || true
  git -C "lib/$dir" checkout --quiet "$rev"
  # Nested dependencies (v4-core, v4-periphery, solmate, permit2 ...) are pinned by the
  # gitlinks inside each repository at this revision, so they follow from the one rev above.
  git -C "lib/$dir" submodule update --init --recursive --quiet
  echo "lib/$dir $(git -C "lib/$dir" rev-parse HEAD)"
}

mkdir -p lib
fetch forge-std https://github.com/foundry-rs/forge-std 8bbcf6e3f8f62f419e5429a0bd89331c85c37824
# OpenZeppelin uniswap-hooks v1.2.1; v4-core and v4-periphery are reached through it.
fetch uniswap-hooks https://github.com/OpenZeppelin/uniswap-hooks acbd604c409a827f7f98c9517236da860c4fca1a
