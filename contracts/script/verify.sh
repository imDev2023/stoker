#!/usr/bin/env bash
# Verifies the source of every contract of a published deployment on the chain's explorer (#251, ADR 0030:
# the site links the verified source wherever it says the contracts are unaudited), then asks the explorer
# whether each one is verified, since its answer to a submission is not the result.
#
#   script/verify.sh <chain>                       the nine contracts of packages/evm/deployments/<chain id>.json
#   script/verify.sh <chain> <address> <path:Name> one more contract (a coin, a Creator Lock)
#
# Blockscout finds the constructor's arguments itself. Robinhood Chain's own explorer (4663) has refused
# forge's route before (a Cloudflare page, 2026-09-10): the `blockscout-verify` skill has the browser route,
# and docs/runbooks/evm-mainnet.md says when to use it. It costs nothing on either chain.
set -euo pipefail
cd "$(dirname "$0")/.."

chain=${1:?"usage: script/verify.sh <chain> [<address> <path:Name>]"}
config="script/config/$chain.json"
chain_id=$(jq -r .chainId "$config")
explorer=$(jq -r .explorer "$config")
record="../packages/evm/deployments/$chain_id.json"

verified() { # verified <address>: whether the explorer holds its verified source
  curl -fsS -m 20 "$explorer/api/v2/smart-contracts/$1" 2>/dev/null | jq -e '.is_verified == true' >/dev/null 2>&1
}

submit() { # submit <address> <path:Name>
  if verified "$1"; then echo "verified already: $2 $1"; return 0; fi
  forge verify-contract "$1" "$2" --verifier blockscout --verifier-url "$explorer/api/" --chain-id "$chain_id" \
    >/dev/null 2>&1 || true
}

if [ $# -ge 3 ]; then
  targets=("$2 $3")
else
  [ -f "$record" ] || { echo "no published deployment: $record" >&2; exit 1; }
  a() { jq -r ".contracts.$1" "$record"; }
  targets=(
    "$(a keys) src/StokerKeys.sol:StokerKeys"
    "$(a registry) src/QuoteRegistry.sol:QuoteRegistry"
    "$(a distributor) src/Distributor.sol:Distributor"
    "$(a taxVault) src/TaxVault.sol:TaxVault"
    "$(a factory) src/StokerFactory.sol:StokerFactory"
    "$(a hook) src/StokerHook.sol:StokerHook"
    "$(a burnDestination) src/destinations/BurnDestination.sol:BurnDestination"
    "$(a liquidityDestination) src/destinations/LiquidityDestination.sol:LiquidityDestination"
    "$(a holdersDestination) src/destinations/HoldersDestination.sol:HoldersDestination"
  )
fi

for t in "${targets[@]}"; do
  # shellcheck disable=SC2086
  submit $t
done

# The explorer queues each job: ask again for up to five minutes.
failed=0
for t in "${targets[@]}"; do
  address=${t%% *}
  name=${t##*:}
  ok=0
  for _ in $(seq 1 30); do
    if verified "$address"; then ok=1; break; fi
    sleep 10
  done
  if [ "$ok" = 1 ]; then
    echo "verified: $name $explorer/address/$address?tab=contract"
  else
    echo "NOT verified: $name $address" >&2
    failed=1
  fi
done
exit "$failed"
