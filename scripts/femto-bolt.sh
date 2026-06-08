#!/usr/bin/env bash
set -euo pipefail
exec ros2 launch orbbec_camera femto_bolt.launch.py "$@"
