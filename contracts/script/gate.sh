#!/usr/bin/env bash
# The security gate before any contract reaches a live chain (#251, ADR 0030), as CI's `contracts` job runs
# it after the build and the tests:
#
#   1. solhint with the security standards' rules: an error fails; its warnings are classes triaged in README.md.
#   2. Slither with the standards' config, against the triaged set in slither.db.json: any finding that is
#      not in it fails. An id there carries the finding's place in the source, so a change to `src` brings its
#      findings back until they are read again (`script/gate.sh triage` after reading them).
#   3. The standards' pre-deployment gate (gate/check.py) with Robinhood Chain's profile, strict: every item
#      passes, or is waived with its reason in .evm-standards.json; none is left unanswered.
#
#   script/gate.sh            run it (after `forge build`)
#   script/gate.sh triage     write slither.db.json from this tree's findings, once each has been read
#
# It needs Slither 0.11.3, PyYAML and node. Slither is handed a build of `src` alone, made here under the
# `gate` profile into folders of its own (foundry.toml says why), so it never touches the workspace's build.
# The invariant campaigns are run here unless INVARIANTS_PASSED=1 says the caller has just run them, as CI has.
set -euo pipefail
cd "$(dirname "$0")/.."

standards=lib/evm-security-standards
[ -f "$standards/gate/check.py" ] || { echo "the security standards are not fetched: run ./script/deps.sh" >&2; exit 2; }

echo "== the sources alone, built for Slither"
FOUNDRY_PROFILE=gate forge build 2>&1 | tail -2

slither_args=(. --config-file "$standards/tooling/slither.config.json" --ignore-compile
  --foundry-out-directory out-gate --triage-database slither.db.json)

if [ "${1:-}" = triage ]; then
  # Every finding of this tree, as the set that has been read. Their classes and reasons are README.md's.
  FOUNDRY_PROFILE=gate slither "${slither_args[@]}" --triage-database /dev/null --json - --fail-none 2>/dev/null \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"].get("detectors",[]); json.dump([{"id":x["id"],"check":x["check"],"impact":x["impact"],"first_markdown_element":x.get("first_markdown_element","")} for x in sorted(r,key=lambda x:(x["check"],x["id"]))],open("slither.db.json","w"),indent=1); print(len(r),"findings written to slither.db.json")'
  exit 0
fi

echo "== solhint"
npx --yes solhint@6.2.4 --config .solhint.json --quiet 'src/**/*.sol'

echo "== Slither against the triaged set"
triaged=$(python3 -c 'import json; print(len(json.load(open("slither.db.json"))))')
FOUNDRY_PROFILE=gate slither "${slither_args[@]}" --fail-pedantic 2>&1 | tail -25
echo "no finding beyond the $triaged triaged"

if [ -z "${INVARIANTS_PASSED:-}" ]; then
  echo "== the invariant campaigns"
  forge test --match-path 'test/invariant/**' | tail -3
fi

# What the tools found, recorded where the gate reads it. The wording is fixed, so a run leaves the file as
# it is committed.
python3 - "$triaged" <<'PY'
import json, sys
path = ".evm-standards.json"
cfg = json.load(open(path))
cfg["evidence"] = {
    "slither": {
        "clean": True,
        "summary": f"Slither 0.11.3 with the standards' config: no finding beyond the {sys.argv[1]} triaged in slither.db.json, each a class explained in README.md",
    },
    "forge-invariant": {
        "clean": True,
        "summary": "every invariant campaign under test/invariant passed, the whole-set campaign among them",
    },
}
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
PY

echo "== the pre-deployment gate, Robinhood Chain's profile, strict"
python3 "$standards/gate/check.py" --project . --strict
