#!/usr/bin/env bash
# Launch an Orbbec publisher in the background, wait for its /camera/* topics
# to appear, then exec ros2 bag record in the foreground so the bag process
# is the container PID 1 (so docker stop / Ctrl+C cleanly tears it down).
#
# The bag is written in MCAP storage with MCAP chunk compression by default.
#
# Env vars (all optional):
#   BAG_PREFIX         - filename prefix for the bag (default: femto_mega)
#   BAG_LAUNCH         - ros2 launch invocation (default: femto_mega.launch.py)
#   BAG_LAUNCH_ARGS    - extra launch arguments (default: RGB-D with depth-to-color registration)
#   BAG_TOPICS         - space-separated required topic list
#   BAG_OPTIONAL_TOPICS - space-separated topics recorded if available
#   BAG_IMU_TOPICS     - space-separated optional IMU topics; recorded if available, skipped if not
#   BAG_LOCK_COLOR     - lock color auto exposure/WB after warmup (default: true)
#   BAG_CAMERA_NODE    - Orbbec node for runtime params (default: /camera/camera)
#   BAG_OUT_DIR        - output directory inside the container (default: /bags)
#   BAG_WARMUP_SEC     - extra seconds to wait after required topics appear (default: 2)
#   BAG_TIMEOUT_SEC    - max seconds to wait for required topics (default: 20)
#   BAG_COMPRESSION    - compression profile: zstd_fast | zstd_small | fastwrite | none | file_zstd | message_zstd
set -euo pipefail

BAG_PREFIX="${BAG_PREFIX:-femto_mega}"
BAG_LAUNCH="${BAG_LAUNCH:-femto_mega.launch.py}"
BAG_LAUNCH_ARGS="${BAG_LAUNCH_ARGS:-enable_color:=true enable_depth:=true depth_registration:=true align_target_stream:=COLOR enable_frame_sync:=true publish_tf:=true enable_publish_extrinsic:=true enable_color_auto_exposure:=true enable_color_auto_white_balance:=true enable_noise_removal_filter:=true noise_removal_filter_min_diff:=256 noise_removal_filter_max_size:=80}"
BAG_OUT_DIR="${BAG_OUT_DIR:-/bags}"
BAG_WARMUP_SEC="${BAG_WARMUP_SEC:-2}"
BAG_TIMEOUT_SEC="${BAG_TIMEOUT_SEC:-20}"
BAG_COMPRESSION="${BAG_COMPRESSION:-zstd_fast}"
BAG_LOCK_COLOR="${BAG_LOCK_COLOR:-true}"
BAG_CAMERA_NODE="${BAG_CAMERA_NODE:-/camera/camera}"

# Default required topic set is intentionally training-oriented:
# - color image + color camera_info provide RGB intrinsics
# - depth/image_raw is D2C-registered in-place when depth_registration:=true
# - depth camera_info preserves the depth intrinsics
# - /tf_static and depth_to_color preserve depth/color extrinsics
# Override BAG_TOPICS only if the downstream consumer is known to need less.
BAG_TOPICS="${BAG_TOPICS:-/camera/color/image_raw /camera/color/camera_info /camera/depth/image_raw /camera/depth/camera_info /tf_static /camera/depth_to_color}"

# Extra topics that are useful when present but should not block recording on
# driver/version differences.
BAG_OPTIONAL_TOPICS="${BAG_OPTIONAL_TOPICS:-/tf /camera/depth_to_color/image_raw /camera/depth_to_color/camera_info /camera/depth_registered/points /camera/depth/points /camera/depth_to_color_extrinsics /camera/depth_to_ir /camera/depth_to_left_ir /camera/depth_to_right_ir /camera/depth_to_accel /camera/depth_to_gyro /camera/depth_to_ir_extrinsics /camera/depth_to_left_ir_extrinsics /camera/depth_to_right_ir_extrinsics /camera/depth_to_accel_extrinsics /camera/depth_to_gyro_extrinsics}"

# Optional topics (recorded if they exist, otherwise a warning is printed).
# IMU is disabled by default. To record IMU, set BAG_IMU_TOPICS explicitly
# (e.g. /camera/imu) and add enable_imu:=true / enable_gyro:=true / enable_accel:=true
# to BAG_LAUNCH_ARGS.
BAG_IMU_TOPICS="${BAG_IMU_TOPICS:-}"

publisher_log="$(mktemp -t orbbec-publisher.XXXXXX.log)"
publisher_pid=""
cleanup() {
  if [ -n "$publisher_pid" ] && kill -0 "$publisher_pid" 2>/dev/null; then
    kill "$publisher_pid" 2>/dev/null || true
    wait "$publisher_pid" 2>/dev/null || true
  fi
  rm -f "$publisher_log"
}
trap cleanup EXIT INT TERM

diagnose_publisher_failure() {
  if [ ! -s "$publisher_log" ]; then return; fi
  echo
  echo "[record] ===== publisher log (tail) ====="
  tail -n 30 "$publisher_log" | sed 's/^/  /'
  echo "[record] =================================="
  echo
  if grep -q 'usbEnumerator openUsbDevice failed! status:113' "$publisher_log"; then
    echo "[record] detected 'status:113' from the wrapper. This means the device" >&2
    echo "[record] USB interface is busy or unreachable. Common causes:" >&2
    echo "[record]   - Another process (e.g. OrbbecViewer) is holding the device." >&2
    echo "[record]     Stop it, wait a few seconds, then retry." >&2
    echo "[record]   - A previous run crashed and left a stale libusb claim." >&2
    echo "[record]     Unplug the camera, wait 5s, replug." >&2
    echo "[record]   - 'make doctor' prints host-side USB state for diagnosis." >&2
  fi
  if grep -q "Device Component 'accel sensor' not found" "$publisher_log" \
     || grep -q "Device Component 'gyro sensor' not found" "$publisher_log"; then
    echo "[record] detected 'sensor not found' from the wrapper. The upstream" >&2
    echo "[record] launch is asking for a sensor the camera firmware is not exposing." >&2
    echo "[record] Likely causes:" >&2
    echo "[record]   - Wrong launch file for this camera (Femto Bolt vs Mega)." >&2
    echo "[record]   - IMU/accel/gyro is enabled in BAG_LAUNCH_ARGS but the device" >&2
    echo "[record]     does not expose those sensors. Set:" >&2
    echo "[record]       enable_imu:=false enable_gyro:=false enable_accel:=false" >&2
  fi
}

lock_color_controls() {
  case "$BAG_LOCK_COLOR" in
    true|1|yes|on) ;;
    *)
      echo "[record] color auto exposure/white balance lock disabled (BAG_LOCK_COLOR=$BAG_LOCK_COLOR)"
      return
      ;;
  esac

  echo "[record] locking color auto exposure and auto white balance on $BAG_CAMERA_NODE"
  if ! ros2 param set "$BAG_CAMERA_NODE" enable_color_auto_exposure false; then
    echo "[record] warning: failed to lock color auto exposure on $BAG_CAMERA_NODE" >&2
  fi
  if ! ros2 param set "$BAG_CAMERA_NODE" enable_color_auto_white_balance false; then
    echo "[record] warning: failed to lock color auto white balance on $BAG_CAMERA_NODE" >&2
  fi
}

mkdir -p "$BAG_OUT_DIR"
stamp="$(date +%Y%m%d_%H%M%S)"
bag="${BAG_OUT_DIR}/orbbec_${BAG_PREFIX}_${stamp}"

# ros2 launch needs the .launch.py filename and the rest as positional args.
launch_args=()
for a in $BAG_LAUNCH_ARGS; do launch_args+=("$a"); done
echo "[record] launching publisher: ros2 launch orbbec_camera $BAG_LAUNCH ${launch_args[*]:-}"
ros2 launch orbbec_camera "$BAG_LAUNCH" "${launch_args[@]+"${launch_args[@]}"}" >"$publisher_log" 2>&1 &
publisher_pid=$!

# Wait up to BAG_TIMEOUT_SEC for all required topics to appear.
echo "[record] waiting for required topics: $BAG_TOPICS"
found_at=0
for i in $(seq 1 "$BAG_TIMEOUT_SEC"); do
  if ! kill -0 "$publisher_pid" 2>/dev/null; then
    echo "[record] ERROR: publisher process exited before topics appeared." >&2
    diagnose_publisher_failure
    exit 1
  fi
  topics="$(ros2 topic list 2>/dev/null || true)"
  missing=()
  for t in $BAG_TOPICS; do
    if ! printf '%s\n' "$topics" | grep -qx "$t"; then
      missing+=("$t")
    fi
  done
  if [ "${#missing[@]}" = "0" ]; then
    found_at=$i
    break
  fi
  sleep 1
done

if [ "$found_at" = "0" ]; then
  echo "[record] ERROR: required topics did not all appear within ${BAG_TIMEOUT_SEC}s." >&2
  if [ "${#missing[@]}" != "0" ]; then
    echo "[record] missing topics: ${missing[*]}" >&2
  fi
  echo "[record] visible topics:" >&2
  printf '%s\n' "${topics:-}" | sed 's/^/[record]   /' >&2
  echo "[record] Is the camera connected and powered? Try 'make doctor'." >&2
  echo "[record] For training bags, D2C registration must start successfully." >&2
  echo "[record] If /camera/depth/image_raw is not color-sized after startup, check power and depth_registration:=true." >&2
  diagnose_publisher_failure
  exit 1
fi
echo "[record] all required topics visible after ${found_at}s; warming up ${BAG_WARMUP_SEC}s"
sleep "$BAG_WARMUP_SEC"
lock_color_controls

# Pick up optional topics that actually exist.
record_topics=()
for t in $BAG_TOPICS; do record_topics+=("$t"); done
for t in $BAG_OPTIONAL_TOPICS; do
  if ros2 topic list 2>/dev/null | grep -qx "$t"; then
    record_topics+=("$t")
  else
    echo "[record] optional topic not present, skipping: $t"
  fi
done
imu_recorded=0
for t in $BAG_IMU_TOPICS; do
  if ros2 topic list 2>/dev/null | grep -qx "$t"; then
    record_topics+=("$t")
    imu_recorded=$((imu_recorded + 1))
  else
    echo "[record] optional topic not present, skipping: $t"
  fi
done
if [ "$imu_recorded" = "0" ] && [ -n "$BAG_IMU_TOPICS" ]; then
  echo "[record] note: BAG_IMU_TOPICS was set but none of those topics are visible."
  echo "[record]   Enable IMU in BAG_LAUNCH_ARGS (enable_imu:=true enable_gyro:=true enable_accel:=true)"
  echo "[record]   or clear BAG_IMU_TOPICS to suppress this message."
fi

# Build ros2 bag record args.
storage_args=()
case "$BAG_COMPRESSION" in
  zstd|zstd_fast) storage_args=(--storage mcap --storage-preset-profile zstd_fast) ;;
  zstd_small)     storage_args=(--storage mcap --storage-preset-profile zstd_small) ;;
  fastwrite)      storage_args=(--storage mcap --storage-preset-profile fastwrite) ;;
  none)           storage_args=(--storage mcap --storage-preset-profile none) ;;
  file_zstd)      storage_args=(--storage mcap --compression-mode file --compression-format zstd) ;;
  message_zstd)   storage_args=(--storage mcap --compression-mode message --compression-format zstd) ;;
  *)
    echo "[record] unknown BAG_COMPRESSION='$BAG_COMPRESSION' (zstd_fast|zstd_small|fastwrite|none|file_zstd|message_zstd), falling back to zstd_fast" >&2
    storage_args=(--storage mcap --storage-preset-profile zstd_fast)
    ;;
esac

echo "[record] topics: ${record_topics[*]}"
echo "[record] starting ros2 bag record -> $bag (storage=mcap, compression/profile=$BAG_COMPRESSION)"
exec ros2 bag record "${storage_args[@]}" --topics "${record_topics[@]}" -o "$bag"
