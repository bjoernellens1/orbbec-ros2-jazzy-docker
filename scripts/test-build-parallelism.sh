#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dockerfile="$root/Dockerfile"
workflow="$root/.github/workflows/docker-build.yml"
compose="$root/compose.yaml"
readme="$root/README.md"

# Hosted runners have only four CPUs and about 16 GiB RAM. Keep both CMake
# phases explicitly bounded, and keep the cap in the checked-in contracts so
# a workflow/Compose invocation cannot silently restore unbounded fan-out.
grep -Fq 'ARG ORBBEC_SDK_BUILD_JOBS=2' "$dockerfile"
grep -Fq 'ARG ORBBEC_COLCON_BUILD_JOBS=2' "$dockerfile"
grep -Fq 'ORBBEC_SDK_BUILD_JOBS must be 1 or 2' "$dockerfile"
grep -Fq 'ORBBEC_COLCON_BUILD_JOBS must be 1 or 2' "$dockerfile"
grep -Fq 'cmake --build /opt/orbbec_sdk/build --target install' "$dockerfile"
grep -Fq -- '--parallel "${ORBBEC_SDK_BUILD_JOBS}"' "$dockerfile"
grep -Fq -- '--parallel-workers "${ORBBEC_COLCON_BUILD_JOBS}"' "$dockerfile"
grep -Fq 'ORBBEC_SDK_BUILD_JOBS=${{ env.ORBBEC_SDK_BUILD_JOBS }}' "$workflow"
grep -Fq 'ORBBEC_COLCON_BUILD_JOBS=${{ env.ORBBEC_COLCON_BUILD_JOBS }}' "$workflow"
grep -Fq 'ORBBEC_SDK_BUILD_JOBS: ${ORBBEC_SDK_BUILD_JOBS:-2}' "$compose"
grep -Fq 'ORBBEC_COLCON_BUILD_JOBS: ${ORBBEC_COLCON_BUILD_JOBS:-2}' "$compose"
grep -Fq 'ORBBEC_SDK_BUILD_JOBS' "$readme"
grep -Fq 'ORBBEC_COLCON_BUILD_JOBS' "$readme"

echo 'bounded build parallelism contract OK'
