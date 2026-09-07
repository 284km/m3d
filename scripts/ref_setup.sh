#!/bin/sh
# scripts/ref_setup.sh — fetch the reference renderer that scripts/reference_check.sh
# compares against. three.js is not vendored into this repository: it is ~900 KB of
# third-party JavaScript that only one gate uses, and pinning the version here keeps the
# comparison reproducible without carrying the code.
set -eu
V="${THREE_VERSION:-0.185.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v npm >/dev/null 2>&1 || { echo "ref_setup: npm is needed to fetch three.js"; exit 1; }
npm install --no-save --silent "three@$V"
# three.module.js imports from ./three.core.js -- copying only the first gives
# "Failed to fetch dynamically imported module", which reads like a server problem.
cp node_modules/three/build/three.module.js node_modules/three/build/three.core.js scripts/ref/
mkdir -p scripts/ref/jsm/loaders
cp node_modules/three/examples/jsm/loaders/GLTFLoader.js scripts/ref/jsm/loaders/
cp -R node_modules/three/examples/jsm/utils scripts/ref/jsm/
echo "ref_setup: three@$V staged under scripts/ref/"
