#!/usr/bin/env bash
# One command for Stoker's whole contract set on one EVM chain (#251): deploy it in order, check on the chain
# what nothing in the contracts checks, and keep or publish the record.
#
#   script/deploy.sh <chain> fork          a fresh anvil fork of the chain, anvil's own accounts as the
#                                           deployer and the Admin; the record stays under cache/
#   script/deploy.sh <chain> live          the chain itself; the record is published to
#                                           packages/evm/deployments/<chain id>.json, then the sources are
#                                           verified on the explorer (script/verify.sh)
#   script/deploy.sh <chain> check [keys]  the checks alone, against the published record; `keys` also
#                                           requires the three server keys held
#
# <chain> names a settings file, script/config/<chain>.json: every figure of a deployment is read from it.
#
# live needs the deployer's key in DEPLOYER_KEY, or its file's path in DEPLOYER_KEY_FILE (one line, 0x and 64
# hex digits), or forge's own signer flags after the target (--ledger --sender 0x..., --account name). The key
# is never an argument here: a process's arguments are public on its machine. The deployer is a throwaway that
# holds no power once the set is deployed; the Admin is the settings file's address and signs nothing here.
#
# The chain's RPC is read from the variable the settings file names (rpcEnv), or is the public one it gives.
# An RPC URL can carry a key, so this script never prints one.
set -euo pipefail
cd "$(dirname "$0")/.."

chain=${1:?"usage: script/deploy.sh <chain> fork|live|check [...]"}
target=${2:?"usage: script/deploy.sh <chain> fork|live|check [...]"}
shift 2
config="script/config/$chain.json"
[ -f "$config" ] || { echo "no settings file: $config" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is needed" >&2; exit 2; }

chain_id=$(jq -r .chainId "$config")
rpc_env=$(jq -r .rpcEnv "$config")
remote=${!rpc_env:-$(jq -r .rpc "$config")}
published="../packages/evm/deployments/$chain_id.json"
pending="cache/deployments/$chain_id.pending.json"
mkdir -p cache/deployments

# Where forge leaves what it really sent: the transactions and their receipts.
sent="broadcast/Deploy.s.sol/$chain_id/run-latest.json"

# The record, from the script's pending one and what forge sent: each contract's address, the transaction
# that made it and its block as the RPC numbers it (the chain's own, never `block.number`, which on Robinhood
# Chain is an estimate of the parent chain's block).
assemble() {
  local out=$1
  local commit
  commit=$(git rev-parse HEAD)
  if [ -n "$(git status --porcelain -- src script/deployment script/Deploy.s.sol foundry.toml)" ]; then commit="$commit-dirty"; fi
  jq -n --slurpfile p "$pending" --slurpfile s "$sent" --arg commit "$commit" --arg chain "$chain" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    ($p[0]) as $p | ($s[0]) as $s
    | ($p.settings | if type == "string" then fromjson else . end) as $settings
    | ($s.receipts | map({key: (.transactionHash | ascii_downcase), value: (.blockNumber | ltrimstr("0x") | explode
        | reduce .[] as $c (0; . * 16 + (if $c > 96 then $c - 87 elif $c > 64 then $c - 55 else $c - 48 end)))})
        | from_entries) as $blocks
    | ($s.transactions | map(select(.transactionType == "CREATE"))) as $creates
    | ($creates | map({key: (.contractAddress | ascii_downcase), value: .hash}) | from_entries) as $made
    | ($creates | map(select(.contractName == "StokerFactory"))[0].hash) as $factoryTx
    | ($p.contracts | to_entries | map({key: .key, value: (
          ($made[.value | ascii_downcase] // $factoryTx) as $tx
          | {transaction: $tx, block: $blocks[$tx | ascii_downcase]})}) | from_entries) as $transactions
    | {
        chain: $chain, chainId: $p.chainId, name: $p.name, explorer: $settings.explorer,
        deployedAt: $at, commit: $commit,
        poolManager: $p.poolManager, admin: $p.admin, deployer: $p.deployer,
        fromBlock: ([$transactions[] | .block] | min),
        contracts: $p.contracts,
        transactions: $transactions,
        hookSalt: $p.hookSalt,
        settings: ($settings | del(.chain, .chainId, .name, .live, .rpcEnv, .rpc, .explorer, .poolManager, .admin, .rehearsal)),
        evmDeployment: {
          chain: $chain, factory: $p.contracts.factory, hook: $p.contracts.hook, registry: $p.contracts.registry,
          keys: $p.contracts.keys, taxVault: $p.contracts.taxVault,
          fromBlock: ([$transactions[] | .block] | min)
        }
      }' > "$out"
}

check() { # check <rpc> <record> [keys] [admin]
  CONFIG=$config DEPLOYMENT=$2 KEYS=${3:-} ADMIN=${4:-} \
    forge script script/CheckDeployment.s.sol --rpc-url "$1" 2>&1 | /usr/bin/grep -v -E '^(Warning|Compiling|No files changed)' || return 1
}

case "$target" in
  fork)
    # A fresh fork under anvil on a free port, stopped when this script ends, with a deployer and an Admin
    # made for the run. Not anvil's own accounts: their keys are public, and on Robinhood Chain the second
    # one carries code (an EIP-7702 delegation somebody made), which the check refuses as an Admin.
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    fork_args=(--fork-url "$remote" --port "$port" --host 127.0.0.1 --quiet)
    [ -n "${FORK_BLOCK:-}" ] && fork_args+=(--fork-block-number "$FORK_BLOCK")
    anvil "${fork_args[@]}" >/dev/null 2>&1 &
    anvil_pid=$!
    trap 'kill "$anvil_pid" 2>/dev/null || true' EXIT
    local_rpc="http://127.0.0.1:$port"
    for _ in $(seq 1 100); do cast chain-id --rpc-url "$local_rpc" >/dev/null 2>&1 && break; sleep 0.2; done
    [ "$(cast chain-id --rpc-url "$local_rpc")" = "$chain_id" ] || { echo "the fork is not chain $chain_id" >&2; exit 1; }
    new_key() { cast wallet new --json | jq -r '(.data // .)[0].private_key'; }
    deployer_key=$(new_key)
    admin=$(cast wallet address "$(new_key)")
    cast rpc anvil_setBalance "$(cast wallet address "$deployer_key")" 0xDE0B6B3A7640000 --rpc-url "$local_rpc" >/dev/null
    CONFIG=$config ADMIN=$admin DEPLOYER_KEY=$deployer_key \
      forge script script/Deploy.s.sol --rpc-url "$local_rpc" --broadcast --slow --non-interactive "$@"
    check "$local_rpc" "$pending" "" "$admin"
    assemble "cache/deployments/$chain_id.fork.json"
    echo "the whole set deployed to a fork of $chain ($chain_id) and every check passed"
    echo "record: contracts/cache/deployments/$chain_id.fork.json (a fork's: never published)"
    ;;
  live)
    export "$rpc_env"="$remote"
    # A record of a fork must never be published as the chain's: anvil answers this method and no chain does.
    if cast rpc anvil_nodeInfo --rpc-url "$chain" >/dev/null 2>&1; then
      echo "the RPC for $chain is an anvil fork: use the fork target" >&2; exit 1
    fi
    [ "$(cast chain-id --rpc-url "$chain")" = "$chain_id" ] || { echo "the RPC is not chain $chain_id" >&2; exit 1; }
    admin=$(jq -r .admin "$config")
    if [ "$admin" = "0x0000000000000000000000000000000000000000" ]; then
      echo "$config has no Admin: write the Admin's address there first (ADR 0030: the owner's hardware wallet)" >&2
      exit 1
    fi
    if [ -e "$published" ] && [ -z "${REDEPLOY:-}" ]; then
      echo "$published exists: this chain has a published deployment. Set REDEPLOY=1 to deploy another." >&2; exit 1
    fi
    if [ -z "${DEPLOYER_KEY:-}" ] && [ -n "${DEPLOYER_KEY_FILE:-}" ]; then
      DEPLOYER_KEY=$(tr -d '[:space:]' < "$DEPLOYER_KEY_FILE"); export DEPLOYER_KEY
    fi
    unset ADMIN
    CONFIG=$config forge script script/Deploy.s.sol --rpc-url "$chain" --broadcast --slow --non-interactive "$@"
    check "$chain" "$pending"
    mkdir -p "$(dirname "$published")"
    assemble "$published"
    echo "the whole set deployed to $chain ($chain_id) and every check passed on the chain"
    echo "published: packages/evm/deployments/$chain_id.json"
    script/verify.sh "$chain" || echo "verification did not finish: run script/verify.sh $chain again" >&2
    ;;
  check)
    export "$rpc_env"="$remote"
    [ -f "$published" ] || { echo "no published deployment: $published" >&2; exit 1; }
    check "$chain" "$published" "$([ "${1:-}" = keys ] && echo appointed || true)"
    ;;
  *)
    echo "the target is fork, live or check" >&2; exit 2
    ;;
esac
