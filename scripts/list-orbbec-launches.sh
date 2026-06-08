#!/usr/bin/env bash
set -euo pipefail
pkg_dir="$(ros2 pkg prefix orbbec_camera)/share/orbbec_camera/launch"
find "$pkg_dir" -maxdepth 1 -type f -name '*.launch.py' -printf '%f\n' | sort
