# Orbbec ROS 2 Jazzy Docker

Containerized OrbbecSDK ROS 2 wrapper for research setups using ROS 2 Jazzy, especially as a clean publisher node for an **Orbbec Femto Bolt**.

The image builds pinned `OrbbecSDK_ROS2` and `OrbbecSDK_v2` source revisions on top of the official ROS 2 Jazzy base image, then copies only the merged install tree into a smaller runtime stage. The SDK is built into the image; runtime services do not bind-mount an SDK shared library.

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
  - rosbag playback in RViz (no camera required)
  - interactive shell
  - optional RViz GUI
  - optional OrbbecViewer GUI (X11 passthrough)
- GitHub Actions build pipeline publishing to GHCR
- Host udev helper for USB permissions

## Upstream used

This project builds from:

```text
wrapper repository: https://github.com/bjoernellens1/OrbbecSDK_ROS2.git
wrapper revision: d269d2b48efafc7b667b5e965e351f74a4ef0cf0
SDK repository: https://github.com/bjoernellens1/OrbbecSDK_v2.git
SDK revision: 6e13176bb6e5e54a0405ab249ccf942ced0a3536
upstream parent: 8e7cad2bfa2c4a6ac4e779be99c64e72166043af
```

The build rejects moving branches/tags and verifies both exact checked-out commits and the
declared upstream parent. The lightweight provenance check is also runnable directly (it
requires full SHAs and Docker then verifies each fetched `HEAD` exactly):

```bash
scripts/check-orbbec-provenance.sh \
  d269d2b48efafc7b667b5e965e351f74a4ef0cf0 \
  6e13176bb6e5e54a0405ab249ccf942ced0a3536
```

The checked-in defaults are tested with `scripts/test-provenance.sh`; moving branches/tags is
rejected, while another explicitly supplied full SHA is accepted only after fetch/readback
verification. The runtime image records both source revisions in OCI labels and
`/opt/orbbec_ws/ORBBEC_PROVENANCE`.

The wrapper's declared upstream parent can still be changed with a full 40-character SHA:

```bash
ORBBEC_UPSTREAM_REF=<exact-upstream-ancestor-sha> docker compose build
```

Runtime OCI labels record the embedded source identity. Verify a built image with:

```bash
docker image inspect ghcr.io/bjoernellens1/orbbec-ros2-jazzy:latest \
  --format '{{ index .Config.Labels "io.splatograph.orbbec.source" }} {{ index .Config.Labels "io.splatograph.orbbec.revision" }} {{ index .Config.Labels "io.splatograph.orbbec.upstream-revision" }}'
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
ros2 launch orbbec_camera femto_bolt.launch.py depth_registration:=true align_target_stream:=COLOR enable_frame_sync:=true
```

**Hardware frame sync is on by default for every live-streaming service** (`femto-bolt`, `femto-bolt-compressed`, `femto-mega`) — depth and color are aligned/synchronized by the camera hardware itself at capture time, so consumers (SLAM frontends, etc.) get a single already-paired timestamp per frame and never need a downstream software re-sync step (`message_filters::ApproximateTime` or similar) to line up color/depth. This was previously only enabled on the `bag-record-*` profiles; it is now the default everywhere live frames are published, since any downstream consumer relying on independently-queued color/depth topics is exactly the failure mode a real consumer (splatograph's ORB-SLAM3 frontend) hit and root-caused via a *recorded bag* lacking this hardware pairing.

### Femto Mega publisher

The image also ships the upstream `femto_mega.launch.py` for the Femto Mega (PID `0x0669`). The Mega needs a powered USB-3 port (≥5 V / 3 A) — see `docs/troubleshooting.md` if you see `Invalid power state` or `rtt is too large` warnings. Also hardware-frame-synced by default (see above).

```bash
make mega
```

### Compressed-color / point-cloud profile

```bash
docker compose up femto-bolt-compressed
```

This uses launch arguments that are often useful for bandwidth-conscious research logs (also hardware-frame-synced by default, see above):

```bash
color_format:=MJPG enable_color:=true enable_depth:=true enable_ir:=false enable_point_cloud:=true depth_registration:=true align_target_stream:=COLOR enable_frame_sync:=true
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

Auto exposure and auto white balance are left on only during the startup/warmup window. Immediately before `ros2 bag record` starts, `record-bag.sh` auto-detects the Orbbec parameter node and tries to lock both controls:

```bash
ros2 param set <camera-node> enable_color_auto_exposure false
ros2 param set <camera-node> enable_color_auto_white_balance false
```

This lets the camera settle to the room lighting, then prevents brightness and color temperature drift during the actual splatting recording. If the parameter node or parameter calls are unavailable, the script prints a warning and continues recording. Set `BAG_LOCK_COLOR=false` to keep continuous auto exposure/WB. Depth noise-removal filtering is enabled, but decimation, spatial, temporal, and hole-filling filters stay off by default to avoid changing geometry more aggressively than necessary.

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
| `BAG_CAMERA_NODE` | `auto` | node used for runtime color-control parameter updates; set explicitly if auto-detection cannot find it |
| `BAG_PARAM_TIMEOUT_SEC` | `5` | max seconds to wait for a camera parameter node before skipping the color lock |
| `BAG_PARAM_SET_TIMEOUT_SEC` | `3` | max seconds for each ROS parameter command used during the color lock |
| `BAG_OUT_DIR` | `/bags` | output directory inside the container (bound to `./bags` on the host) |
| `BAG_WARMUP_SEC` | `2` | settle time after topics appear |
| `BAG_TIMEOUT_SEC` | `20` | max wait for required topics |
| `BAG_STOP_TIMEOUT_SEC` | `30` | max wait after Ctrl+C/SIGINT before escalating recorder shutdown |

Available env vars for `play-bag-in-rviz.sh` (all optional):

| var | default | meaning |
|---|---|---|
| `BAG_PATH` | *(newest `*.mcap` under `BAG_OUT_DIR`)* | bag file or directory to play |
| `BAG_RATE` | `1.0` | playback rate multiplier |
| `BAG_LOOP` | `true` | loop the bag; set to `false` / `0` / `no` / `off` for a single playthrough |
| `BAG_START_OFFSET` | `0` | seconds to skip at the start |
| `BAG_TOPICS` | color, registered depth, camera infos, `/tf_static`, depth-to-color extrinsics | topic filter for `ros2 bag play` (space-separated) |
| `BAG_OUT_DIR` | `/bags` | directory to scan when `BAG_PATH` is unset |
| `BAG_RVIZ_CONFIG` | `/workspaces/orbbec/rviz/orbbec_playback.rviz` | path to a saved RViz config; printed to stdout if it exists, so the user can load it manually |

Inspect a recorded bag:

```bash
ros2 bag info ./bags/orbbec_femto_mega_*.mcap
ros2 bag play ./bags/orbbec_femto_mega_*.mcap
```

### Rosbag playback in RViz

The `playback` profile is the inverse of the `record` profile: it replays a bag from `./bags` and re-publishes the topics on the same ROS graph, so an in-container RViz (or any other consumer on the same `ROS_DOMAIN_ID`) can visualize them. No camera is required.

> **Note:** the `rviz-playback` service runs `rviz2` inside the container, which requires `ros-jazzy-rviz2`. The image used to ship only `ros-jazzy-ros-base` (no RViz); the runtime stage now installs `rviz2` as well. If you pull an image built before the playback profile was added, run `make build` once to pick up the new dependency.

```bash
make play-rviz
```

`make play-rviz` starts two services together:

- `bag-play-rviz` — runs `scripts/play-bag-in-rviz.sh`, which picks the newest `*.mcap` under `./bags` and runs `ros2 bag play` in the foreground (PID 1, so `Ctrl+C` cleanly tears it down).
- `rviz-playback` — opens `rviz2` with a preconfigured display layout (`rviz/orbbec_playback.rviz`) that already has a `Color` and `Depth` Image display plus a TF display. The `Fixed Frame` is `camera_color_optical_frame` (the standard Orbbec wrapper color frame), and `/tf_static` recorded by `make record` provides the rest of the tree.

Like the other GUI services, `rviz-playback` needs X11 access on the host:

```bash
xhost +local:docker
make play-rviz
```

Common variations (all env vars on `play-bag-in-rviz.sh`):

```bash
# Pick a specific bag explicitly.
BAG_PATH=/bags/orbbec_femto_mega_20260610_125601/orbbec_femto_mega_20260610_125601_0.mcap \
  make play-rviz

# Slow it down (0.5x) — useful for hand-tuning RViz displays or
# recording screencasts of the playback. Looping is already the default.
BAG_RATE=0.5 make play-rviz

# Single playthrough instead of looping. Use this for headless smoke tests
# of a bag from CI, or to leave the play-rviz session tied to a recording
# run.
BAG_LOOP=false make play-rviz

# Skip the first 5 seconds of the bag.
BAG_START_OFFSET=5 make play-rviz

# Headless: play the bag without RViz (useful for smoke-testing a bag
# outside of an X11 session, e.g. inside CI).
make play
```

The script filters playback to the training-oriented topic set (`/camera/color/image_raw`, `/camera/color/camera_info`, `/camera/depth/image_raw`, `/camera/depth/camera_info`, `/tf_static`, `/camera/depth_to_color`) by default. If you recorded a narrower or wider set, override it with `BAG_TOPICS` (space-separated). The script also prints the path to the recommended RViz config on startup so you can load it manually inside any other RViz.

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
