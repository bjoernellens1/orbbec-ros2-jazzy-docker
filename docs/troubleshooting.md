# Troubleshooting

This page covers the runtime problems you can hit with an Orbbec camera (Femto Bolt, Femto Mega, …) talking to this container. Most of them are **host-side** USB issues; very few are bugs in the image itself.

The fastest way to triage anything in this file is:

```bash
make doctor
```

`make doctor` runs the `doctor` compose service (`scripts/doctor.sh`) inside a one-shot container. It prints the host USB tree, the negotiated speed and `MaxPower` for any Orbbec device, whether the udev rule is installed on the host, and what the SDK sees. It exits 0 if an Orbbec device is visible, 1 otherwise.

---

## 1. `Invalid power state (DC: NO_PLUGIN, USB: Less than 5V3A)! Please plug in the power supply correctly!`

This is the Femto Mega (and some other depth cameras) telling you it is **bus-powered** but the host USB port can't supply the 5 V / 3 A it wants for full operation. Without enough power:

- The depth and IR pipelines cannot open (`Invalid power state! Can not access sensors!`).
- The OrbbecSDK will report `D2CPipeline create pipeline failed!`.
- A stream may start, then drop.

The container setup is correct; the issue is on the host. Try in order:

1. **Direct rear-panel USB-3 port.** Front-panel headers and laptop ports are usually limited to 900 mA.
2. **Shorter / higher-quality USB-3 cable.** The Femto Mega ships with a 2 m USB-C cable; long or USB-2 cables will silently fall back to lower current.
3. **No hub.** A bus-powered hub cannot deliver 3 A downstream; if you must use a hub, it must be self-powered.
4. **Confirm the host actually advertises the right current:**
   ```bash
   lsusb -v -d 2bc5:0669 | grep -E 'MaxPower|bcdUSB'
   ```
   Look for `MaxPower 900mA` (or more) and `bcdUSB 3.00`. A 500 mA / 2.00 result means the port negotiated to USB-2 and the camera is starved.

The Femto Mega also has a DC barrel jack on the back. If your power budget on USB is permanently capped, plug in the official power supply — the SDK reports `DC Power State -> 1` once it is connected.

---

## 2. `update device time succeeded, but rtt is too large! round-trip-time=1a6ms`

This is the OrbbecSDK measuring the **USB round-trip time** from the host to the camera and back. Healthy values are single-digit to low-double-digit milliseconds. Hundreds of milliseconds (the `1a6ms` is 0x1a6 = 422 ms) mean the link is too slow or too noisy for synchronized streams.

Causes, in order of likelihood:

1. **Camera is on a USB-2 port or hub.** Check:
   ```bash
   lsusb -t
   ```
   Find the Orbbec device (VID `2bc5:`) and look at the `5000M` / `480M` and `Driver=` columns. Anything other than `5000M` is a problem.
2. **Cheap or long USB cable.** USB-3 is rated for 3 m; cheap cables lose signal integrity well before that. Try a different, shorter cable.
3. **CPU power management / USB autosuspend.** On laptops, `USB_AUTOSUSPEND` and aggressive `intel_pstate` modes can stall the USB controller. Try `sudo powertop --auto-tune` to disable autosuspend for the camera, or permanently:
   ```bash
   echo -1 | sudo tee /sys/module/usbcore/parameters/autosuspend
   ```
4. **Another high-bandwidth device on the same controller.** External SSDs, 4K webcams, and a depth camera can saturate a single xHCI controller. Spread them across controllers (use the rear panel of a different PCIe slot).

If you cannot get the RTT down, fall back to compressed streams:
```bash
make run  # equivalent to femto_bolt.launch.py
# or
docker compose up femto-bolt-compressed   # uses color_format:=MJPG
```

---

## 3. `sh: 1: lsusb: not found` / `sh: 1: zenity: not found`

Cosmetic. The OrbbecViewer shells out to `lsusb` (from `usbutils`) and `zenity` for some lookups and dialogs. The image installs both; this message is only seen on older images that pre-date the fix.

Rebuild:
```bash
make build
```

Then re-run the viewer. If the message persists, your local image cache is stale — `make pull && make build --pull --no-cache`.

---

## 4. `No required type sensor found! sensorType: OB_SENSOR_IR` / `OB_SENSOR_COLOR` / `OB_SENSOR_ACCEL` / `OB_SENSOR_GYRO`

Almost always a **downstream effect** of the power issue (#1) or the RTT issue (#2). The SDK cannot open the sensor, so it cannot initialize the properties (mirror/flip, etc.) that are tied to it. Fix the underlying power / USB-3 issue and these lines disappear.

If the sensors are intentionally disabled in your launch file (for example `enable_ir:=false`), the messages are expected and harmless.

---

## 5. `create pipeline failed!` / `D2CPipeline::D2CPipeline@48] create pipeline failed!`

The OrbbecSDK is unable to bring up the hardware-accelerated D2C (depth-to-color) pipeline. Two common reasons:

- **Femto Mega not getting enough power.** See #1. The Mega needs ≥5 V / 3 A for D2C; otherwise the pipeline cannot be created even though the device enumerates.
- **Wrong launch file.** Femto Bolt launch files on a Femto Mega (or vice versa) will leave the D2C pipeline unconfigured. Use the right launch:
  - Femto Bolt → `femto_bolt.launch.py` (this repo's default)
  - Femto Mega → `femto_mega.launch.py` (`make mega`)

## 6. `Failed to setup topics: Device Component 'accel sensor' not found!` (status:114)

The publisher tries to bring up a sensor the device does not expose. On a Femto Mega this is the IMU/accel pipeline; on a Femto Bolt it can be the IR sensor. Typical causes:

- **Wrong launch file for the camera.** The Femto Bolt launch file (`femto_bolt.launch.py`) assumes the Bolt's sensor set; running it on a Femto Mega (or vice versa) makes the wrapper request sensors the device does not have. Fix: use the launch file that matches the plugged-in camera.
  ```bash
  make run       # Femto Bolt
  make mega      # Femto Mega
  make record    # Femto Bolt recording
  make record-mega  # Femto Mega recording
  ```
- **The camera is underpowered (Femto Mega).** The Mega exposes accel/gyro sensors only when it has enough bus power (see #1). If the same `Device Component 'accel sensor' not found` keeps appearing on the correct launch file, the Mega is starved and the SDK silently falls back to skipping those components. Power the camera (DC barrel jack on the Mega) and try again.
- **`enable_imu:=false` (or `enable_accel:=false` / `enable_gyro:=false`).** If the launch arguments deliberately disable IMU, the messages are expected. Pass `enable_imu:=true` if you want the `/camera/imu` topic.

---

## 7. `usbEnumerator openUsbDevice failed! status:113` (and OrbbecViewer shows everything except IMU)

This is the most common failure when the camera enumerates fine in `lsusb` and even OrbbecViewer works, but the ROS 2 publisher cannot open the device. The two error lines that matter:

```
Failed to setup topics: usbEnumerator openUsbDevice failed! status:113
Failed to initialize device (Attempt 1 of 3): usbEnumerator openUsbDevice failed! status:113
```

`status:113` is the wrapper reporting that the libusb context opened the device but the `open()` (or claim of the bulk endpoint) failed. The OrbbecSDK does not log a clean reason; the cause is almost always one of these three:

### 7a. Another process is holding the device

If you have OrbbecViewer running in another terminal/container (`make viewer`), it has already claimed the device's USB interfaces. The ROS 2 publisher will then fail with `status:113` because the kernel only allows one process to claim a USB interface at a time.

Fix:
1. Stop OrbbecViewer (`Ctrl+C` its terminal).
2. Wait 5 s for the kernel to release the claim.
3. Re-run `make record-mega` (or `make run` / `make mega`).

If you want both tools to be available at the same time, use OrbbecViewer's built-in *ROS Topic* subscriber mode (it can subscribe to the camera's existing ROS topics) instead of opening the device directly. That avoids the conflict.

### 7b. Stale libusb claim from a crashed run

If a previous publisher or OrbbecViewer crashed (or was killed with `kill -9`), the kernel may not have fully released the USB interface. Symptoms look identical to 7a.

Fix (in order of how aggressive they are):
1. Unplug the camera, wait 5 s, replug.
2. `docker compose down --remove-orphans` and replug.
3. `sudo udevadm trigger --action=remove` and replug.
4. As a last resort, `sudo systemctl restart udev` (replug afterwards).

### 7c. Wrong launch file or IMU flags

If you see `Device Component 'accel sensor' not found!` (status:114) immediately after the `status:113` line, the wrapper is also trying to open an IMU sensor that the launch file asked for but the firmware isn't exposing. This is usually one of:

- **Wrong camera in the launch file.** Femto Bolt launch on a Femto Mega (or vice versa). See #6.
- **IMU/accel/gyro is enabled in the launch args but the device does not expose those sensors.** For the Femto Mega in this repo, IMU is **disabled by default** at the camera node (`enable_imu:=false enable_gyro:=false enable_accel:=false`) so the wrapper does not even attempt to bring up the IMU sensor. If you re-enable IMU, pass the three flags explicitly:
  ```bash
  ros2 launch orbbec_camera femto_mega.launch.py \
    enable_imu:=true enable_gyro:=true enable_accel:=true \
    enable_color:=true enable_depth:=true
  ```
- **Femto Mega unit without an IMU.** A small number of Femto Mega SKUs ship without the LSM6DSMUS IMU. In that case OrbbecViewer's panel will also show no IMU stream, and no combination of launch flags will bring up `/camera/imu`. Check the device label or the OrbbecSDK `OB_DEVICE_INFO` block for `imu_supported`. With the default IMU-disabled launch in this repo the symptom disappears, which is the recommended workaround.

The `record-bag.sh` script in this repo prints targeted hints if it sees `status:113` or `accel sensor not found` in the publisher's log on timeout. IMU topics are disabled by default; set `BAG_IMU_TOPICS` and enable IMU in `BAG_LAUNCH_ARGS` if you want them in the bag.

`make doctor` is the right first step for any of these — it prints the host USB tree, the negotiated `bcdUSB` and `MaxPower`, and the result of `ros2 run orbbec_camera list_devices_node` so you can confirm the device is visible from inside the container.

---

## 8. Quick host-side checklist

When in doubt, walk this list in order:

1. `make udev` — install the Orbbec udev rule on the host and replug the camera.
2. `make doctor` — confirm the camera is visible to the container and on a USB-3 root hub.
3. **Stop any other process that might be holding the device** (OrbbecViewer, another publisher container, etc.). See #7.
4. **Use the right launch file for the camera you have plugged in.** Femto Bolt → `make run`, Femto Mega → `make mega` (or `make record-mega` for recording).
5. Try a different physical USB-3 port (rear panel, no hub, good cable).
6. Check the cable: USB-3 certified, ≤ 2 m, no adapters.
7. For Femto Mega: plug in the DC power supply if the USB port is power-capped.
8. If RTT is still high, disable USB autosuspend (see #2).
9. As a last resort, drop to compressed streams with `femto-bolt-compressed` or the equivalent Mega launch arguments.

If `make doctor` reports `OK` but `make run` still fails, please open an issue with the full `make doctor` output and a `ros2 launch ... --log-level debug` log.
