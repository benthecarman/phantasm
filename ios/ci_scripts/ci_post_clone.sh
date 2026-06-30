#!/bin/sh
set -euo pipefail

IOS_DIR="${CI_PRIMARY_REPOSITORY_PATH:-$(git rev-parse --show-toplevel)}/ios"

if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: xcodegen is required, but neither xcodegen nor Homebrew is available."
    exit 1
  fi

  brew install xcodegen
fi

cd "$IOS_DIR"
xcodegen generate
