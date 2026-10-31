#!/usr/bin/env bash
# Install the pinned Foundry libraries, then build.
#
# dependencies.lock.json pins each third-party Solidity library by full
# commit. This repository has no Allowit git dependencies: the Rust crates
# for this rail live in allowit-sdk under rails/tempo/.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# = 0 ] || { echo "usage: scripts/build.sh" >&2; exit 2; }

while IFS=$'\t' read -r name repo rev; do
  [ "$(cat "lib/$name/.revision" 2>/dev/null)" = "$rev" ] && continue
  rm -rf "lib/$name"
  forge install --no-git "$name=${repo#https://github.com/}@rev=$rev"
  echo "$rev" > "lib/$name/.revision"
done < <(jq -r '.dependencies | to_entries[] | [.key, .value.repository, .value.revision] | @tsv' dependencies.lock.json)

forge build
