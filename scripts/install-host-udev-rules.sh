#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo: sudo ./scripts/install-host-udev-rules.sh" >&2
  exit 1
fi

container_image="${ORBBEC_IMAGE:-ghcr.io/bjoernellens1/orbbec-ros2-jazzy:latest}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cid="$(docker create "$container_image")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; rm -rf "$tmp_dir"' EXIT

docker cp "$cid:/opt/orbbec_ws/install/share/orbbec_camera/udev/99-obsensor-libusb.rules" "$tmp_dir/99-obsensor-libusb.rules"
install -m 0644 "$tmp_dir/99-obsensor-libusb.rules" /etc/udev/rules.d/99-obsensor-libusb.rules
udevadm control --reload-rules
udevadm trigger

echo "Installed Orbbec udev rules. Replug the camera if it was already connected."
