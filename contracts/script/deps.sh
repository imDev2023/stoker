#!/usr/bin/env bash
# Fetches the workspace's dependencies into lib/ at pinned revisions.
# Nothing under lib/ is committed and there is no git submodule: this file is the pin.
# The revisions are those of the v4 hooks knowledge base's hooks/foundry.lock and of the
# spike (spike/evm-robinhood-fork), so all three compile against the same v4-core,
# v4-periphery and OpenZeppelin code.
set -euo pipefail
cd "$(dirname "$0")/.."

fetch() {
  local dir=$1 url=$2 rev=$3
  if [ ! -d "lib/$dir/.git" ]; then
    git clone --quiet "$url" "lib/$dir"
  fi
  if [ "$(git -C "lib/$dir" rev-parse HEAD)" != "$rev" ]; then
    git -C "lib/$dir" fetch --quiet origin "$rev" 2>/dev/null || true
    git -C "lib/$dir" checkout --quiet "$rev"
  fi
  # Nested dependencies (v4-core, v4-periphery, permit2, OpenZeppelin contracts) are pinned by
  # the gitlinks inside each repository at this revision, so they follow from the one rev above.
  git -C "lib/$dir" submodule update --init --recursive --quiet
  echo "lib/$dir $(git -C "lib/$dir" rev-parse HEAD)"
}

mkdir -p lib
fetch forge-std https://github.com/foundry-rs/forge-std 8bbcf6e3f8f62f419e5429a0bd89331c85c37824
# OpenZeppelin uniswap-hooks v1.2.1; v4-core, v4-periphery and OpenZeppelin contracts are reached through it.
fetch uniswap-hooks https://github.com/OpenZeppelin/uniswap-hooks acbd604c409a827f7f98c9517236da860c4fca1a
