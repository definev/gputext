#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

flutter pub get >/dev/null

config="$(find .dart_tool/hooks_runner/gputext -name input.json 2>/dev/null | head -1)"
if [[ -z "${config}" ]]; then
  echo "gputext: no hook input.json found after pub get" >&2
  exit 1
fi

dart run hook/build.dart --config="${config}"
