# Orbbec ROS 2 Jazzy Docker

Containerized OrbbecSDK ROS 2 wrapper for research setups using ROS 2 Jazzy, especially as a clean publisher node for an **Orbbec Femto Bolt**.

The image builds `orbbec/OrbbecSDK_ROS2` from source on top of the official ROS 2 Jazzy base image, then copies only the merged install tree into a smaller runtime stage.

## What this repo gives you

- Minimal runtime image based on `ros:jazzy-ros-base`
- Multi-stage build: full build toolchain only exists in the builder stage
- `docker compose` services for:
  - Femto Bolt publisher
  - compressed-color Femto Bolt publisher
  - device listing
  - SDK version service check
  - topic inspection
  - RGB-D bag recording
  - interactive shell
  - optional RViz GUI
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

### Record RGB-D topics

```bash
docker compose --profile record run --rm bag-record-rgbd
```

Bags are written to `./bags` on the host.

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
