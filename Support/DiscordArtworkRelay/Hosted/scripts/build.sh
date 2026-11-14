#!/usr/bin/env bash
set -euo pipefail
mkdir -p dist/server
node --check worker/index.js
cp worker/index.js dist/server/index.js
