#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wrapper_ref=d269d2b48efafc7b667b5e965e351f74a4ef0cf0
sdk_ref=6e13176bb6e5e54a0405ab249ccf942ced0a3536

"$root/scripts/check-orbbec-provenance.sh" "$wrapper_ref" "$sdk_ref"
if "$root/scripts/check-orbbec-provenance.sh" main "$sdk_ref"; then
  echo "moving wrapper ref was accepted" >&2
  exit 1
fi
if "$root/scripts/check-orbbec-provenance.sh" "$wrapper_ref" main; then
  echo "moving SDK ref was accepted" >&2
  exit 1
fi

grep -Fq "ARG ORBBEC_REF=$wrapper_ref" "$root/Dockerfile"
grep -Fq "ARG ORBBEC_SDK_REF=$sdk_ref" "$root/Dockerfile"
grep -Fq "ORBBEC_REF: \${ORBBEC_REF:-$wrapper_ref}" "$root/compose.yaml"
grep -Fq "ORBBEC_SDK_REF: \${ORBBEC_SDK_REF:-$sdk_ref}" "$root/compose.yaml"
! grep -Eq '(^|[[:space:]-])[^#]*SDK[^#]*\.so[^#]*:' "$root/compose.yaml"
