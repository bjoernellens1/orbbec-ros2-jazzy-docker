#!/usr/bin/env bash
# Play back a recorded rosbag in the foreground so it is the container's PID 1
# (so docker stop / Ctrl+C cleanly tears it down) and publish the topics to the
# same ROS graph that an external RViz (or any other consumer) can subscribe to.
#
# Designed as the inverse of record-bag.sh: the bag was produced by
# record-bag.sh and lives under /bags (bound to ./bags on the host).
#
# Env vars (all optional):
#   BAG_PATH         - explicit bag path inside the container (file or dir).
#                      If unset, the newest *.mcap under /bags is picked.
#   BAG_RATE         - playback rate multiplier (default: 1.0)
#   BAG_LOOP         - loop the bag (default: true). Playback is intended for
#                      interactive inspection in RViz, so it loops by default
#                      and the user opts out with BAG_LOOP=false.
#   BAG_START_OFFSET - seconds to skip at the start (default: 0)
#   BAG_TOPICS       - space-separated topic filter (default: required training set)
#   BAG_OUT_DIR      - directory to scan when BAG_PATH is unset (default: /bags)
#   BAG_RVIZ_CONFIG  - path to a saved RViz config to advertise to the user
#                      (default: /workspaces/orbbec/rviz/orbbec_playback.rviz)
set -euo pipefail

BAG_OUT_DIR="${BAG_OUT_DIR:-/bags}"
BAG_RATE="${BAG_RATE:-1.0}"
BAG_LOOP="${BAG_LOOP:-true}"
BAG_START_OFFSET="${BAG_START_OFFSET:-0}"
BAG_RVIZ_CONFIG="${BAG_RVIZ_CONFIG:-/workspaces/orbbec/rviz/orbbec_playback.rviz}"

# Default topic set is the same training-oriented set record-bag.sh records:
# - color image + color camera_info provide RGB intrinsics
# - depth/image_raw is D2C-registered in-place when recorded with depth_registration:=true
# - depth camera_info preserves the depth intrinsics
# - /tf_static and depth_to_color preserve depth/color extrinsics
# Override BAG_TOPICS only if you recorded a narrower or wider topic set.
BAG_TOPICS="${BAG_TOPICS:-/camera/color/image_raw /camera/color/camera_info /camera/depth/image_raw /camera/depth/camera_info /tf_static /camera/depth_to_color}"

resolve_bag_path() {
  if [ -n "${BAG_PATH:-}" ]; then
    if [ ! -e "$BAG_PATH" ]; then
      echo "[play] ERROR: BAG_PATH does not exist: $BAG_PATH" >&2
      echo "[play] Tip: the host's ./bags directory is mounted at /bags in the container." >&2
      return 1
    fi
    printf '%s\n' "$BAG_PATH"
    return 0
  fi

  if [ ! -d "$BAG_OUT_DIR" ]; then
    echo "[play] ERROR: BAG_OUT_DIR does not exist: $BAG_OUT_DIR" >&2
    return 1
  fi

  # record-bag.sh writes each bag as a directory:
  #   /bags/orbbec_<prefix>_<timestamp>/orbbec_<prefix>_<timestamp>_0.mcap
  # plus a sibling metadata.yaml. `ros2 bag play` accepts the directory path
  # directly, so we resolve the bag to its parent directory.
  #
  # Sort strategy: pick the bag directory whose mcap filename sorts
  # greatest. The filename starts with the same YYYYmmdd_HHMMSS timestamp
  # as the directory, so a glob sort is equivalent to newest-first and
  # also handles restart-on-same-second multi-shard bags deterministically.
  local newest_mcap
  newest_mcap="$(find "$BAG_OUT_DIR" -mindepth 2 -maxdepth 3 -type f -name '*.mcap' -printf '%P\n' 2>/dev/null | sort | tail -n 1 || true)"
  if [ -z "$newest_mcap" ]; then
    # Fallback: maybe the user dropped a flat .mcap straight into /bags.
    newest_mcap="$(find "$BAG_OUT_DIR" -maxdepth 1 -type f -name '*.mcap' -printf '%f\n' 2>/dev/null | sort | tail -n 1 || true)"
    if [ -n "$newest_mcap" ]; then
      printf '%s\n' "$BAG_OUT_DIR/$newest_mcap"
      return 0
    fi
    echo "[play] ERROR: no .mcap files found under $BAG_OUT_DIR" >&2
    echo "[play] Record one first with 'make record' or 'make record-mega'." >&2
    return 1
  fi
  # Strip the trailing /<file>.mcap to get the bag directory.
  local bag_dir
  bag_dir="$(dirname "$newest_mcap")"
  printf '%s\n' "$BAG_OUT_DIR/$bag_dir"
}

bag="$(resolve_bag_path)"
echo "[play] using bag: $bag"
if [ -n "${BAG_RVIZ_CONFIG:-}" ] && [ -f "$BAG_RVIZ_CONFIG" ]; then
  echo "[play] recommended RViz config: $BAG_RVIZ_CONFIG"
  echo "[play]   load it with: rviz2 -d $BAG_RVIZ_CONFIG"
fi

play_args=("$bag" --rate "$BAG_RATE" --start-offset "$BAG_START_OFFSET")
case "$BAG_LOOP" in
  true|1|yes|on) play_args+=(--loop) ;;
  *) ;;
esac

if [ -n "$BAG_TOPICS" ]; then
  for t in $BAG_TOPICS; do play_args+=(--topics "$t"); done
fi

echo "[play] starting: ros2 bag play ${play_args[*]}"
exec ros2 bag play "${play_args[@]}"
