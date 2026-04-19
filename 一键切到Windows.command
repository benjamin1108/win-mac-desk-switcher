#!/bin/zsh

cd "$(dirname "$0")" || exit 1

./scripts/switch-to-windows-now.sh
exit "$?"
