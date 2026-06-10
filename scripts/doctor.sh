#!/usr/bin/env bash
# Diagnostic helper for Orbbec USB cameras inside the container.
# Prints host-visible USB state and the camera's negotiated power/speed, then
# asks the upstream list_devices_node to enumerate via the SDK. Exits 0 if a
# device is visible (either to the SDK or to lsusb), 1 otherwise.
set -uo pipefail

bar() { printf '\n=== %s ===\n' "$*"; }

have_lsusb=0
if command -v lsusb >/dev/null 2>&1; then have_lsusb=1; fi

bar "Host USB tree (lsusb -t)"
if [ "$have_lsusb" = "1" ]; then
  lsusb -t 2>&1 || true
else
  echo "lsusb not available in this image."
  echo "  -> the pulled 'latest' image was built before usbutils was added."
  echo "  -> run 'make build' (uses the local Dockerfile) and re-run, or"
  echo "  -> 'docker pull' once a new GHCR image is published with usbutils."
fi

bar "Orbbec devices (VID 2bc5)"
sdk_seen_count=0
if [ "$have_lsusb" = "1" ]; then
  lsusb -d 2bc5: 2>&1 || echo "  (none)"
  echo
  for d in $(lsusb -d 2bc5: 2>/dev/null | awk '{print "/dev/bus/usb/" $2 "/" $4}' | sed 's|:$||'); do
    [ -e "$d" ] || continue
    echo "Detail for $d:"
    lsusb -v -d "$(lsusb -d 2bc5: | head -1 | awk '{print $6}')" 2>/dev/null \
      | grep -E 'idVendor|idProduct|bcdUSB|iProduct|MaxPower|Conn|Power' \
      | sed 's/^/  /' || true
  done
else
  echo "lsusb not available in this image; skipping detailed USB info."
fi

bar "udev rule"
rule="/etc/udev/rules.d/99-obsensor-libusb.rules"
if [ -f "$rule" ]; then
  echo "OK: $rule present on host"
else
  share_rule="$(ros2 pkg prefix orbbec_camera 2>/dev/null)/share/orbbec_camera/udev/99-obsensor-libusb.rules"
  if [ -f "$share_rule" ]; then
    echo "MISSING on host, but found in image at: $share_rule"
    echo "Run 'make udev' on the host to install it."
  else
    echo "udev rule not found in image"
  fi
fi

bar "Configured ORBBEC_USB_DEVICE"
echo "${ORBBEC_USB_DEVICE:-<unset — whole USB tree is forwarded>}"

bar "Upstream list_devices_node (SDK enumeration, source of truth)"
sdk_log="$(mktemp -t orbbec-list-devices.XXXXXX.log)"
sdk_seen_count=0
sdk_seen_lines=""
if command -v ros2 >/dev/null 2>&1; then
  if ros2 run orbbec_camera list_devices_node >"$sdk_log" 2>&1; then
    :
  fi
  if [ -s "$sdk_log" ]; then
    sed 's/^/  /' "$sdk_log"
    # Count how many "name: Orbbec …" lines the SDK printed.
    sdk_seen_count=$(grep -c '^\s*\[INFO\][^]]*\] \[list_device_node\]: name: Orbbec' "$sdk_log" || true)
    sdk_seen_lines=$(grep '^\s*\[INFO\][^]]*\] \[list_device_node\]:' "$sdk_log" | sed 's/^[[:space:]]*//')
  else
    echo "  (list_devices_node produced no output)"
  fi
else
  echo "  ros2 not on PATH"
fi

bar "Verdict"
if [ "$sdk_seen_count" -ge 1 ] 2>/dev/null; then
  echo "OK: $sdk_seen_count Orbbec device(s) visible to the SDK inside the container."
  echo
  echo "Device details from the SDK:"
  echo "$sdk_seen_lines" | sed 's/^/  /'
  rm -f "$sdk_log"
  exit 0
fi

# SDK didn't see anything. Fall back to lsusb if it's available.
if [ "$have_lsusb" = "1" ] && lsusb -d 2bc5: >/dev/null 2>&1; then
  count=$(lsusb -d 2bc5: | wc -l | tr -d ' ')
  echo "OK (via lsusb only): $count Orbbec device(s) visible, but the SDK did not enumerate them."
  echo "  -> the wrapper likely failed to open the device. Check the SDK logs above."
  rm -f "$sdk_log"
  exit 0
fi

echo "FAIL: no Orbbec device visible to the container."
cat <<'EOF'
Quick host-side checks:
  1. lsusb -t   (look for a "5000M" entry under the Orbbec device — USB-3 is required)
  2. lsusb -v -d 2bc5:0669  | grep -E 'MaxPower|bcdUSB'  (Femto Mega wants ~900 mA / USB-3)
  3. Try a different physical port (rear panel, no hub, shorter/better cable)
  4. If the device shows up only as USB-2, the link is starved — see docs/troubleshooting.md
  5. Run 'make udev' to install the Orbbec udev rule (use absolute path under sudo).
  6. If another ROS graph already has the device, the wrapper will report
     'status:113'. Stop the other process and retry. See docs/troubleshooting.md.
EOF
rm -f "$sdk_log"
exit 1
