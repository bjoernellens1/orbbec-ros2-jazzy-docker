#!/usr/bin/env bash
set -eo pipefail

source "/opt/ros/${ROS_DISTRO:-jazzy}/setup.bash"
source "/opt/orbbec_ws/install/setup.bash"

exec "$@"
