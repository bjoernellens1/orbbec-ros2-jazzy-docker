# Orbbec ROS 2 Jazzy Docker

Containerized OrbbecSDK ROS 2 wrapper for research setups using ROS 2 Jazzy, especially as a clean publisher node for an **Orbbec Femto Bolt**.

The image builds `orbbec/OrbbecSDK_ROS2` from source on top of the official ROS 2 Jazzy base image, then copies only the merged install tree into a smaller runtime stage.

## What this repo gives you

- Minimal runtime image based on `ros:jazzy-ros-base`
- Multi-stage build: full build toolchain only exists in the builder stage
- `docker compose` services for:
  - Femto Bolt publisher
  - Femto Mega publisher
  - compressed-color Femto Bolt publisher
  - device listing
  - SDK version service check
  - topic inspection
  - one-shot host/USB diagnostic (`make doctor`)
  - RGB-D bag recording (MCAP with ZSTD chunk compression, IMU disabled by default)
  - interactive shell
  - optional RViz GUI
  - optional OrbbecViewer GUI (X11 passthrough)
- GitHub Actions build pipeline publishing to GHCR
- Host udev helper for USB permissions

## Upstream used

This project builds from:

```text
https://github.com/orbbec/OrbbecSDK_ROS2.git
branch/ref: v2-main
```

You can pin a release/tag or branch with:

```bash
ORBBEC_REF=v2.8.6 docker compose build
```

## Quick start

```bash
git clone https://github.com/bjoernellens1/orbbec-ros2-jazzy-docker.git
cd orbbec-ros2-jazzy-docker
cp .env.example .env
make build
```

Install host udev rules once:

```bash
make udev
```

Unplug and reconnect the camera after installing udev rules.

List connected Orbbec devices:

```bash
make list
```

Run the Femto Bolt publisher:

```bash
make run
```

In another terminal on the same ROS domain:

```bash
ros2 topic list
ros2 topic echo /camera/depth/camera_info
```

## Compose tasks

### Default Femto Bolt publisher

```bash
docker compose up femto-bolt
```

Equivalent command inside the container:

```bash
ros2 launch orbbec_camera femto_bolt.launch.py
```

### Femto Mega publisher

The image also ships the upstream `femto_mega.launch.py` for the Femto Mega (PID `0x0669`). The Mega needs a powered USB-3 port (≥5 V / 3 A) — see `docs/troubleshooting.md` if you see `Invalid power state` or `rtt is too large` warnings.

```bash
make mega
```

### Compressed-color / point-cloud profile

```bash
docker compose up femto-bolt-compressed
```

This uses launch arguments that are often useful for bandwidth-conscious research logs:

```bash
color_format:=MJPG enable_color:=true enable_depth:=true enable_ir:=false enable_point_cloud:=true
```

### Device discovery

```bash
docker compose --profile tools run --rm list-devices
```

### SDK version check

```bash
docker compose --profile tools run --rm sdk-version
```

### Topic inspection

```bash
docker compose --profile tools run --rm topics
```

### Record training-ready RGB-D topics

`make record` (Femto Bolt) and `make record-mega` (Femto Mega) start the corresponding publisher **inside the same container**, wait for all required training topics to appear, and then run `ros2 bag record` in the foreground. The bag is written to `./bags/orbbec_<camera>_<timestamp>` on the host in **MCAP format with ZSTD chunk compression**. `Ctrl+C` cleanly stops both the recorder and the publisher.

The default compression is `BAG_COMPRESSION=zstd_fast`, which uses the MCAP storage preset:

```bash
ros2 bag record --storage mcap --storage-preset-profile zstd_fast ...
```

This is different from rosbag2 file compression (`--compression-mode file`), which writes an MCAP first and then compresses it to `.mcap.zstd` during shutdown. File compression is still available as `BAG_COMPRESSION=file_zstd`, but it is not the default because it causes a visible post-recording compression step.

The recorder enables depth-to-color registration with:

```bash
depth_registration:=true align_target_stream:=COLOR enable_frame_sync:=true publish_tf:=true enable_publish_extrinsic:=true
```

It also uses a Gaussian-splatting friendly capture profile:

```bash
enable_color_auto_exposure:=true enable_color_auto_white_balance:=true
enable_noise_removal_filter:=true noise_removal_filter_min_diff:=256 noise_removal_filter_max_size:=80
```

Auto exposure and auto white balance are left on only during the startup/warmup window. Immediately before `ros2 bag record` starts, `record-bag.sh` locks both controls on `/camera/camera`:

```bash
ros2 param set /camera/camera enable_color_auto_exposure false
ros2 param set /camera/camera enable_color_auto_white_balance false
```

This lets the camera settle to the room lighting, then prevents brightness and color temperature drift during the actual splatting recording. Set `BAG_LOCK_COLOR=false` to keep continuous auto exposure/WB. Depth noise-removal filtering is enabled, but decimation, spatial, temporal, and hole-filling filters stay off by default to avoid changing geometry more aggressively than necessary.

The required bag contents are:

```text
/camera/color/image_raw
/camera/color/camera_info
/camera/depth/image_raw
/camera/depth/camera_info
/tf_static
/camera/depth_to_color
```

For Splatograph/ROS2 RGB-D training, use the depth topic below. With
`depth_registration:=true`, Orbbec ROS wrapper 2.8.x publishes the
depth-to-color registered 1280x720 depth stream in-place on
`/camera/depth/image_raw`.

```bash
--orbbec_color_topic /camera/color/image_raw \
--orbbec_depth_topic /camera/depth/image_raw \
--orbbec_camera_info_topic /camera/color/camera_info
```

Femto Bolt (RGB-D, no IMU):

```bash
make record
# -> ./bags/orbbec_femto_bolt_YYYYMMDD_HHMMSS.mcap
```

Femto Mega (RGB-D, IMU disabled at the camera node):

```bash
make record-mega
# -> ./bags/orbbec_femto_mega_YYYYMMDD_HHMMSS.mcap
```

The Femto Mega publisher is launched with `enable_imu:=false enable_gyro:=false enable_accel:=false`, so the wrapper does not even attempt to bring up the IMU sensor. If you want IMU back in the recording, set the launch args and the topic list explicitly:

```bash
BAG_LAUNCH_ARGS='enable_imu:=true enable_gyro:=true enable_accel:=true enable_color:=true enable_depth:=true' \
BAG_IMU_TOPICS='/camera/imu /camera/accel/imu /camera/gyro/imu' \
  docker compose --profile record run --rm bag-record-rgbd-mega
```

Customising the run (all of these are env vars on `record-bag.sh`):

```bash
# Different topic set, different prefix, no compression.
# Only drop depth, /tf_static, or extrinsics if your consumer does not
# need aligned RGB-D data.
BAG_PREFIX=lab_run_3 \
BAG_TOPICS='/camera/color/image_raw /camera/color/camera_info /camera/depth/image_raw /camera/depth/camera_info /tf_static /camera/depth_to_color' \
BAG_COMPRESSION=none \
  docker compose --profile record run --rm bag-record-rgbd-mega

# Smaller files, more CPU: MCAP ZSTD chunk compression at the slowest preset.
BAG_COMPRESSION=zstd_small \
  docker compose --profile record run --rm bag-record-rgbd-mega

# Re-enable IMU (currently disabled by default; see below)
BAG_LAUNCH_ARGS='enable_imu:=true enable_gyro:=true enable_accel:=true enable_color:=true enable_depth:=true' \
BAG_IMU_TOPICS='/camera/imu /camera/accel/imu /camera/gyro/imu' \
  docker compose --profile record run --rm bag-record-rgbd-mega
```

Available env vars (all optional):

| var | default | meaning |
|---|---|---|
| `BAG_PREFIX` | `femto_bolt` / `femto_mega` | filename prefix |
| `BAG_LAUNCH` | matching `.launch.py` | which publisher to run |
| `BAG_LAUNCH_ARGS` | training-safe RGB-D with `depth_registration:=true`, frame sync, TF, and Orbbec extrinsics enabled | launch arguments |
| `BAG_TOPICS` | color, registered depth, camera infos, `/tf_static`, depth-to-color extrinsics | required topic list (recording fails if any are missing) |
| `BAG_OPTIONAL_TOPICS` | `/tf`, version-specific aligned-depth aliases, point clouds, other Orbbec extrinsics | optional non-IMU topics, recorded if present |
| `BAG_IMU_TOPICS` | *(empty)* | optional topics, recorded if present, skipped if not. IMU is disabled by default; set explicitly to record it. |
| `BAG_COMPRESSION` | `zstd_fast` | `zstd_fast` / `zstd_small` / `fastwrite` / `none` for MCAP storage presets; `file_zstd` and `message_zstd` for rosbag2 compression modes |
| `BAG_LOCK_COLOR` | `true` | lock color auto exposure and auto white balance after warmup, before recording |
| `BAG_CAMERA_NODE` | `/camera/camera` | node used for runtime color-control parameter updates |
| `BAG_OUT_DIR` | `/bags` | output directory inside the container (bound to `./bags` on the host) |
| `BAG_WARMUP_SEC` | `2` | settle time after topics appear |
| `BAG_TIMEOUT_SEC` | `20` | max wait for required topics |

Inspect a recorded bag:

```bash
ros2 bag info ./bags/orbbec_femto_mega_*.mcap
ros2 bag play ./bags/orbbec_femto_mega_*.mcap
```

If recording starts but the camera cannot stream, `make doctor` will print host-side USB diagnostics. If the publisher dies before topics appear (typical symptom: `usbEnumerator openUsbDevice failed! status:113`), another process is likely holding the device or the link is unstable — see `docs/troubleshooting.md`.

### OrbbecViewer (standalone GUI)

The image can optionally include the upstream OrbbecViewer binary (default: v1.10.27) so you can drive the camera with the vendor GUI instead of (or alongside) the ROS 2 wrapper. It needs X11 access on the host.

```bash
xhost +local:docker
docker compose --profile gui run --rm orbbecviewer
```

OrbbecViewer opens its own device list and talks to the camera via libusb directly, so it does not need the ROS 2 driver running. It can also be launched in parallel with `femto-bolt` on the same `ROS_DOMAIN_ID` if you want to view the same stream via both tools.

To skip the viewer at build time (smaller image, fewer download deps):

```bash
ORBBEC_VIEWER_URL= docker compose build
```

To pin a different OrbbecViewer release, both the URL and the version (which controls the unzip directory name) must match:

```bash
ORBBEC_VIEWER_URL=https://.../OrbbecViewer_v1.11.0_..._linux_x64_release.zip \
ORBBEC_VIEWER_VERSION=1.11.0 \
docker compose build
```

### Development shell

```bash
docker compose --profile dev run --rm shell
```

Inside:

```bash
list-orbbec-launches.sh
ros2 pkg list | grep orbbec
```

## Hardware access notes

The compose file intentionally uses:

```yaml
network_mode: host
ipc: host
privileged: true
devices:
  - /dev/bus/usb:/dev/bus/usb
volumes:
  - /dev:/dev
```

For a lab/research machine this is the least painful and most reliable USB camera setup. If you later deploy on a robot with stricter security requirements, reduce this to the exact `/dev/bus/usb/...` device nodes and the necessary groups after confirming stable enumeration.

## ROS networking

Set the domain in `.env`:

```bash
ROS_DOMAIN_ID=42
```

For large image streams over Fast DDS, the compose default also sets:

```bash
FASTDDS_BUILTIN_TRANSPORTS=LARGE_DATA
```

## CI/CD

The workflow in `.github/workflows/docker-build.yml` builds the image on every push and PR. On pushes to `main` and tags, it pushes:

```text
ghcr.io/bjoernellens1/orbbec-ros2-jazzy:latest
ghcr.io/bjoernellens1/orbbec-ros2-jazzy:<branch/tag/sha>
```

Make the GitHub package public from the repository/package settings if you want other machines to pull without authentication.

## Recommended first validation

```bash
make build
make udev
make list
make run
```

Then verify topics:

```bash
ros2 topic hz /camera/depth/image_raw
ros2 topic hz /camera/color/image_raw
ros2 service call /camera/get_sdk_version orbbec_camera_msgs/srv/GetString '{}'
```

## Known practical issues

- If the camera is visible only with `sudo`, the host udev rules are missing or the camera needs to be replugged.
- If RGB-D bandwidth is unstable, confirm that the camera enumerates as USB 3.x and try the compressed compose service.
- If another ROS graph cannot see topics, check `ROS_DOMAIN_ID`, firewall rules, and DDS configuration.
- For production robots, consider replacing `privileged: true` with narrower device permissions once the setup is stable.

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for the most common runtime issues (`Invalid power state`, `rtt is too large`, missing sensors, etc.) and the recommended host-side fixes. The fastest triage command is:

```bash
make doctor
```
