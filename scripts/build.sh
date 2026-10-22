#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-plugin.sh"
"$ROOT/scripts/build-helper.sh"
