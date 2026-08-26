#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 WRAPPER_REF SDK_REF" >&2
  exit 2
fi

[[ $1 =~ ^[0-9a-f]{40}$ ]] || {
  echo "wrapper ref must be a full commit SHA" >&2
  exit 1
}
[[ $2 =~ ^[0-9a-f]{40}$ ]] || {
  echo "SDK ref must be a full commit SHA" >&2
  exit 1
}
