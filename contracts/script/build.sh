#!/usr/bin/env bash
# Builds the whole workspace in parts, as CI's `contracts` job does (#251).
#
# One compiler process building everything at once holds everything it has built until it ends: 11 GB of
# memory on 2026-11-27, most of it for the tests, each compiled through the IR pipeline over the same large
# base. That took CI's 16 GB runner down, twice, with no compiler error: only "the runner has received a
# shutdown signal". Built in parts, each process holds one part and ends; a file already built is not built
# again, so the artifacts are the same and the last line, the one build CI used to make, compiles nothing.
#
#   script/build.sh            the sources and the scripts, then the tests a dozen files at a time, then
#                              `forge build --sizes`
#   PART=8 script/build.sh     smaller parts, if a runner still runs short
#
# `forge build` alone still works on a machine with the memory for it.
set -euo pipefail
cd "$(dirname "$0")/.."

part=${PART:-12}

echo "== src and script"
forge build src script

tests=()
while IFS= read -r file; do tests+=("$file"); done < <(find test -name '*.sol' | LC_ALL=C sort)
for ((i = 0; i < ${#tests[@]}; i += part)); do
  echo "== test files $((i + 1)) to $((i + part < ${#tests[@]} ? i + part : ${#tests[@]})) of ${#tests[@]}"
  forge build "${tests[@]:i:part}"
done

echo "== the whole workspace, its sizes"
forge build --sizes
