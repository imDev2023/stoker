#!/usr/bin/env bash
# The rehearsal of the whole contract set (#251): script/Rehearsal.s.sol's steps, sent from the rehearsal's own
# throwaway keys.
#
#   script/rehearse.sh <chain> fork            everything on a fresh anvil fork, the set deployed first by
#                                               script/Deploy.s.sol, the clock moved between the steps
#   script/rehearse.sh <chain> live <step>     one step on the chain itself, against its published deployment
#   script/rehearse.sh <chain> live report     reads the chain and checks the books; sends nothing
#
# The steps, in order: fund setup launch trade tend freeze lift graduate rounds pay. Three waits are the
# chain's own and cannot be skipped on a live chain: the Reference Price must follow a First Buy before tend
# (minutes), the Graduation Hold runs an hour between lift and graduate, and the Round Delay runs 24 hours
# between rounds and pay. A step run early stops by name and sends nothing.
#
# The keys are files, <role>.key, one line each (0x and 64 hex digits), in REHEARSAL_KEYS (by default
# ~/.config/stoker/<chain>): deployer admin round ladder keeper creator trader holder issuer. They are read
# into the environment of the one forge process and are never arguments, never printed. On a fork with no
# such directory, throwaway keys are made for the run.
#
# Every transaction a step sent is appended to cache/deployments/<chain id>.rehearsal.jsonl (a fork's to
# <chain id>.fork-rehearsal.jsonl) with its step, its function, its block and its gas.
set -euo pipefail
cd "$(dirname "$0")/.."

chain=${1:?"usage: script/rehearse.sh <chain> fork | live <step>"}
target=${2:?"usage: script/rehearse.sh <chain> fork | live <step>"}
config="script/config/$chain.json"
[ -f "$config" ] || { echo "no settings file: $config" >&2; exit 2; }
chain_id=$(jq -r .chainId "$config")
rpc_env=$(jq -r .rpcEnv "$config")
remote=${!rpc_env:-$(jq -r .rpc "$config")}
if [ "$(jq -r .live "$config")" = true ] && [ "$target" = live ]; then
  echo "$chain is a live chain: the rehearsal runs on a testnet or a fork alone" >&2; exit 1
fi
jq -e .rehearsal "$config" >/dev/null || { echo "$config has no rehearsal figures" >&2; exit 2; }
keys=${REHEARSAL_KEYS:-$HOME/.config/stoker/$chain}
roles="deployer admin round ladder keeper creator trader holder issuer"
mkdir -p cache/deployments

address_of() { cast wallet address "$(tr -d '[:space:]' < "$keys/$1.key")" 2>/dev/null; }

load_keys() {
  for role in $roles; do
    [ -f "$keys/$role.key" ] || { echo "no key file for the $role in the keys' directory" >&2; exit 2; }
    upper=$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')
    export "REHEARSAL_${upper}_KEY=$(tr -d '[:space:]' < "$keys/$role.key")"
  done
}

# step <rpc> <record> <log> <name>: one step, then every transaction it sent, appended to the log.
step() {
  local rpc=$1 record=$2 log=$3 name=$4
  local flags=(--broadcast --slow --non-interactive)
  [ "$name" = report ] && flags=()
  echo "== $name"
  CONFIG=$config DEPLOYMENT=$record forge script script/Rehearsal.s.sol --sig "$name()" --rpc-url "$rpc" --isolate \
    "${flags[@]}" 2>&1 | /usr/bin/grep -E '^(  |== |Error|.*revert|.*StepNotReady|.*Unexpected)' | /usr/bin/grep -v -E '^\s*$' || true
  [ "$name" = report ] && return 0
  local sent="broadcast/Rehearsal.s.sol/$chain_id/$name-latest.json"
  [ -f "$sent" ] || { echo "the step $name sent nothing" >&2; return 1; }
  jq -c --arg step "$name" '
    (.receipts | map({key: .transactionHash, value: .}) | from_entries) as $r
    | .transactions[] | ($r[.hash]) as $x
    | {step: $step, hash: .hash, to: (.contractAddress // .transaction.to), contract: .contractName, call: .function,
       from: .transaction.from, status: $x.status, block: $x.blockNumber, gasUsed: $x.gasUsed}' "$sent" >> "$log"
  if jq -e '[.receipts[] | select(.status != "0x1")] | length > 0' "$sent" >/dev/null; then
    echo "a transaction of the step $name failed on the chain" >&2; return 1
  fi
  echo "   $(jq '.transactions | length' "$sent") transactions"
}

case "$target" in
  fork)
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    anvil --fork-url "$remote" --port "$port" --host 127.0.0.1 --quiet >/dev/null 2>&1 &
    anvil_pid=$!
    made_keys=""
    trap 'kill "$anvil_pid" 2>/dev/null || true; [ -n "$made_keys" ] && rm -rf "$made_keys"' EXIT
    rpc="http://127.0.0.1:$port"
    for _ in $(seq 1 100); do cast chain-id --rpc-url "$rpc" >/dev/null 2>&1 && break; sleep 0.2; done
    [ "$(cast chain-id --rpc-url "$rpc")" = "$chain_id" ] || { echo "the fork is not chain $chain_id" >&2; exit 1; }
    if [ ! -f "$keys/admin.key" ]; then
      made_keys=$(mktemp -d); keys=$made_keys
      for role in $roles; do (umask 077; cast wallet new --json | jq -r '.data[0].private_key // .[0].private_key' > "$keys/$role.key"); done
    fi
    load_keys
    wait_for() { cast rpc evm_increaseTime "$1" --rpc-url "$rpc" >/dev/null; cast rpc evm_mine --rpc-url "$rpc" >/dev/null; echo "-- the fork's clock moved $1 seconds"; }

    # The fork's stand-in for the faucet's form: the faucet's own claim for the trader, sent as its relayer
    # (0.01 ETH and 5 of each stand-in Stock Token); the trader then funds every other key, as on the chain.
    faucet=$(jq -r '.rehearsal.faucet // empty' "$config"); relayer=$(jq -r '.rehearsal.faucetRelayer // empty' "$config")
    if [ -n "$faucet" ]; then
      cast rpc anvil_impersonateAccount "$relayer" --rpc-url "$rpc" >/dev/null
      cast send "$faucet" "$(cast calldata 'claim(address,uint256)' "$(address_of trader)" 5000000000000000000 | sed 's/^0x[0-9a-f]\{8\}/0x433ede47/')" \
        --value 0.01ether --from "$relayer" --unlocked --rpc-url "$rpc" >/dev/null
    else
      cast rpc anvil_setBalance "$(address_of trader)" 0x2386F26FC10000 --rpc-url "$rpc" >/dev/null
    fi

    log="cache/deployments/$chain_id.fork-rehearsal.jsonl"; : > "$log"
    record="cache/deployments/$chain_id.pending.json"
    step "$rpc" "$record" "$log" fund
    CONFIG=$config ADMIN=$(address_of admin) DEPLOYER_KEY=$REHEARSAL_DEPLOYER_KEY \
      forge script script/Deploy.s.sol --rpc-url "$rpc" --broadcast --slow --non-interactive >/dev/null
    jq -c '(.receipts | map({key: .transactionHash, value: .}) | from_entries) as $r | .transactions[] | ($r[.hash]) as $x
      | {step: "deploy", hash: .hash, to: .contractAddress, contract: .contractName, call: "constructor", from: .transaction.from,
         status: $x.status, block: $x.blockNumber, gasUsed: $x.gasUsed}' "broadcast/Deploy.s.sol/$chain_id/run-latest.json" >> "$log"
    echo "== deploy: $(jq '.transactions | length' "broadcast/Deploy.s.sol/$chain_id/run-latest.json") transactions"
    check() { CONFIG=$config DEPLOYMENT=$record KEYS=${1:-} ADMIN=$(address_of admin) \
      forge script script/CheckDeployment.s.sol --rpc-url "$rpc" 2>&1 | /usr/bin/grep -E 'FAILED|checks made|every check passed'; }
    check
    step "$rpc" "$record" "$log" setup
    check appointed
    step "$rpc" "$record" "$log" launch
    wait_for 30
    step "$rpc" "$record" "$log" trade
    wait_for 1200
    step "$rpc" "$record" "$log" tend
    step "$rpc" "$record" "$log" freeze
    wait_for 120
    step "$rpc" "$record" "$log" lift
    wait_for 3700
    step "$rpc" "$record" "$log" graduate
    step "$rpc" "$record" "$log" rounds
    wait_for 86500
    step "$rpc" "$record" "$log" pay
    # A fork alone can wait out a Creator Lock's seven days.
    wait_for 604800
    step "$rpc" "$record" "$log" lock
    step "$rpc" "$record" "$log" report
    echo "== gas, by step"
    jq -s -r 'group_by(.step) | map({step: .[0].step, n: length, gas: (map(.gasUsed | ltrimstr("0x") | explode
        | reduce .[] as $c (0; . * 16 + (if $c > 96 then $c - 87 elif $c > 64 then $c - 55 else $c - 48 end))) | add)})
      | (.[] | "\(.step)\t\(.n) transactions\t\(.gas) gas"), "all\t\(map(.n) | add) transactions\t\(map(.gas) | add) gas"' "$log"
    echo "== what each key holds at the end, in wei (the trader began with the faucet's 0.01 ETH)"
    for role in $roles; do
      printf '%s\t%s\n' "$role" "$(cast balance "$(address_of "$role")" --rpc-url "$rpc")"
    done
    echo "the rehearsal ran whole on a fork of $chain ($chain_id); its transactions: contracts/$log"
    ;;
  live)
    name=${3:?"a step: fund setup launch trade tend freeze lift graduate rounds pay report"}
    export "$rpc_env"="$remote"
    if cast rpc anvil_nodeInfo --rpc-url "$chain" >/dev/null 2>&1; then
      echo "the RPC for $chain is an anvil fork: use the fork target" >&2; exit 1
    fi
    record="../packages/evm/deployments/$chain_id.json"
    if [ "$name" != fund ] && [ ! -f "$record" ]; then
      echo "no published deployment: $record (run script/deploy.sh $chain live first)" >&2; exit 1
    fi
    [ "$name" = lock ] && { echo "a Creator Lock's seven days cannot be waited out here: the lock step is a fork's" >&2; exit 1; }
    load_keys
    step "$chain" "$record" "cache/deployments/$chain_id.rehearsal.jsonl" "$name"
    ;;
  *)
    echo "the target is fork or live" >&2; exit 2
    ;;
esac
