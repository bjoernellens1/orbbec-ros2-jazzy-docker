# syntax=docker/dockerfile:1.7

ARG ROS_DISTRO=jazzy
ARG BASE_IMAGE=ros:jazzy-ros-base
ARG ORBBEC_REPO=https://github.com/bjoernellens1/OrbbecSDK_ROS2.git
ARG ORBBEC_REF=d269d2b48efafc7b667b5e965e351f74a4ef0cf0
ARG ORBBEC_UPSTREAM_REF=8e7cad2bfa2c4a6ac4e779be99c64e72166043af
ARG ORBBEC_SDK_REPO=https://github.com/bjoernellens1/OrbbecSDK_v2.git
ARG ORBBEC_SDK_REF=6e13176bb6e5e54a0405ab249ccf942ced0a3536
# OrbbecViewer (standalone GUI). Set to empty string to skip.
ARG ORBBEC_VIEWER_URL=https://github.com/orbbec/OrbbecSDK/releases/download/v1.10.27/OrbbecViewer_v1.10.27_202509260133_linux_x64_release.zip
ARG ORBBEC_VIEWER_VERSION=1.10.27

FROM ${BASE_IMAGE} AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG ROS_DISTRO
ARG ORBBEC_REPO
ARG ORBBEC_REF
ARG ORBBEC_UPSTREAM_REF
ARG ORBBEC_SDK_REPO
ARG ORBBEC_SDK_REF
ENV DEBIAN_FRONTEND=noninteractive \
    ROS_DISTRO=${ROS_DISTRO} \
    ROS_WS=/opt/orbbec_ws

# Build-only dependencies. Runtime image below installs only what is needed to run.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      git \
      libgl-dev \
      libdw-dev \
      libgflags-dev \
      libgoogle-glog-dev \
      libssl-dev \
      nlohmann-json3-dev \
      python3-colcon-common-extensions \
      python3-rosdep \
      python3-vcstool \
      ros-${ROS_DISTRO}-ament-cmake \
      ros-${ROS_DISTRO}-backward-ros \
      ros-${ROS_DISTRO}-camera-info-manager \
      ros-${ROS_DISTRO}-compressed-image-transport \
      ros-${ROS_DISTRO}-diagnostic-msgs \
      ros-${ROS_DISTRO}-diagnostic-updater \
      ros-${ROS_DISTRO}-image-publisher \
      ros-${ROS_DISTRO}-image-transport \
      ros-${ROS_DISTRO}-image-transport-plugins \
      ros-${ROS_DISTRO}-statistics-msgs \
      ros-${ROS_DISTRO}-xacro \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/check-orbbec-provenance.sh /usr/local/bin/check-orbbec-provenance
RUN chmod +x /usr/local/bin/check-orbbec-provenance \
    && check-orbbec-provenance "${ORBBEC_REF}" "${ORBBEC_SDK_REF}"

RUN echo "${ORBBEC_SDK_REF}" | grep -Eq '^[0-9a-f]{40}$' \
    && mkdir -p /opt/orbbec_sdk/src \
    && git -C /opt/orbbec_sdk/src init -q \
    && git -C /opt/orbbec_sdk/src remote add origin ${ORBBEC_SDK_REPO} \
    && git -C /opt/orbbec_sdk/src fetch --depth 1 origin ${ORBBEC_SDK_REF} \
    && git -C /opt/orbbec_sdk/src checkout --detach FETCH_HEAD \
    && test "$(git -C /opt/orbbec_sdk/src rev-parse HEAD)" = "${ORBBEC_SDK_REF}" \
    && cmake -S /opt/orbbec_sdk/src -B /opt/orbbec_sdk/build \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_INSTALL_PREFIX=/opt/orbbec_sdk/install \
         -DOB_BUILD_EXAMPLES=OFF \
         -DOB_BUILD_TESTS=OFF \
         -DOB_BUILD_TOOLS=OFF \
         -DOB_BUILD_DOCS=OFF \
         -DOB_INSTALL_EXAMPLES_SOURCE=OFF \
    && cmake --build /opt/orbbec_sdk/build --target install --parallel

RUN echo "${ORBBEC_REF}" | grep -Eq '^[0-9a-f]{40}$' \
    && echo "${ORBBEC_UPSTREAM_REF}" | grep -Eq '^[0-9a-f]{40}$' \
    && mkdir -p ${ROS_WS}/src/OrbbecSDK_ROS2 \
    && git -C ${ROS_WS}/src/OrbbecSDK_ROS2 init -q \
    && git -C ${ROS_WS}/src/OrbbecSDK_ROS2 remote add origin ${ORBBEC_REPO} \
    && git -C ${ROS_WS}/src/OrbbecSDK_ROS2 fetch --depth 64 origin ${ORBBEC_REF} \
    && git -C ${ROS_WS}/src/OrbbecSDK_ROS2 checkout --detach FETCH_HEAD \
    && test "$(git -C ${ROS_WS}/src/OrbbecSDK_ROS2 rev-parse HEAD)" = "${ORBBEC_REF}" \
    && git -C ${ROS_WS}/src/OrbbecSDK_ROS2 merge-base --is-ancestor \
         ${ORBBEC_UPSTREAM_REF} ${ORBBEC_REF}

RUN rm -rf ${ROS_WS}/src/OrbbecSDK_ROS2/orbbec_camera/SDK/include \
           ${ROS_WS}/src/OrbbecSDK_ROS2/orbbec_camera/SDK/lib/x64 \
    && cp -a /opt/orbbec_sdk/install/include \
          ${ROS_WS}/src/OrbbecSDK_ROS2/orbbec_camera/SDK/include \
    && mkdir -p ${ROS_WS}/src/OrbbecSDK_ROS2/orbbec_camera/SDK/lib/x64 \
    && cp -a /opt/orbbec_sdk/install/lib/. \
          ${ROS_WS}/src/OrbbecSDK_ROS2/orbbec_camera/SDK/lib/x64/

WORKDIR ${ROS_WS}
# The colcon build needs the ROS environment sourced, which only works under bash
# (setup.bash uses bash-only syntax). Wrap the whole command in `bash -c` so it
# runs under bash even when the OCI builder ignores the SHELL directive above
# (buildah / podman buildx fall back to /bin/sh for RUN).
RUN bash -c '. /opt/ros/${ROS_DISTRO}/setup.bash \
  && colcon build \
       --merge-install \
       --event-handlers console_direct+ \
       --cmake-args -DCMAKE_BUILD_TYPE=Release'

# Strip symbols where possible to keep runtime copy smaller.
RUN find ${ROS_WS}/install -type f -executable -exec strip --strip-unneeded {} + 2>/dev/null || true
RUN printf 'wrapper_repo=%s\nwrapper_revision=%s\nsdk_repo=%s\nsdk_revision=%s\n' \
      "${ORBBEC_REPO}" "${ORBBEC_REF}" "${ORBBEC_SDK_REPO}" "${ORBBEC_SDK_REF}" \
      > ${ROS_WS}/ORBBEC_PROVENANCE \
    && test -f ${ROS_WS}/install/lib/libOrbbecSDK.so.2.9.3

FROM ${BASE_IMAGE} AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG ROS_DISTRO
ARG ORBBEC_REPO
ARG ORBBEC_REF
ARG ORBBEC_UPSTREAM_REF
ARG ORBBEC_SDK_REPO
ARG ORBBEC_SDK_REF
LABEL org.opencontainers.image.title="orbbec-ros2-jazzy-docker" \
      org.opencontainers.image.description="Minimal ROS 2 Jazzy container for OrbbecSDK_ROS2 v2 / Femto Bolt publishing" \
      org.opencontainers.image.source="https://github.com/bjoernellens1/orbbec-ros2-jazzy-docker" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.splatograph.orbbec.source="${ORBBEC_REPO}" \
      io.splatograph.orbbec.revision="${ORBBEC_REF}" \
      io.splatograph.orbbec.upstream-revision="${ORBBEC_UPSTREAM_REF}" \
      io.splatograph.orbbec.sdk.source="${ORBBEC_SDK_REPO}" \
      io.splatograph.orbbec.sdk.revision="${ORBBEC_SDK_REF}"

ENV DEBIAN_FRONTEND=noninteractive \
    ROS_DISTRO=${ROS_DISTRO} \
    ROS_WS=/opt/orbbec_ws \
    RMW_IMPLEMENTATION=rmw_zenoh_cpp \
    RCUTILS_COLORIZED_OUTPUT=1 \
    PYTHONUNBUFFERED=1

# Runtime-only dependencies for ROS transport, camera info, diagnostics and USB/OpenGL libs
# required by the upstream wrapper/SDK. usbutils (lsusb) and zenity are used by OrbbecViewer
# for device-info lookups and native dialogs; without them the GUI spams "not found" warnings.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash-completion \
      ca-certificates \
      libdw1 \
      libgflags2.2 \
      libgl1 \
      libgl1-mesa-dri \
      libglx-mesa0 \
      libegl-mesa0 \
      libegl1 \
      libgles2 \
      libglvnd0 \
      libgbm1 \
      libgoogle-glog0v6 \
      libssl3 \
      libusb-1.0-0 \
      mesa-utils \
      mesa-utils-bin \
      nlohmann-json3-dev \
      ros-${ROS_DISTRO}-backward-ros \
      ros-${ROS_DISTRO}-camera-info-manager \
      ros-${ROS_DISTRO}-compressed-image-transport \
      ros-${ROS_DISTRO}-diagnostic-msgs \
      ros-${ROS_DISTRO}-diagnostic-updater \
      ros-${ROS_DISTRO}-image-publisher \
      ros-${ROS_DISTRO}-image-transport \
      ros-${ROS_DISTRO}-image-transport-plugins \
      ros-${ROS_DISTRO}-rosbag2-storage-mcap \
      ros-${ROS_DISTRO}-rmw-zenoh-cpp \
      ros-${ROS_DISTRO}-rviz2 \
      ros-${ROS_DISTRO}-statistics-msgs \
      ros-${ROS_DISTRO}-xacro \
      udev \
      usbutils \
      zenity \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/orbbec_ws/install /opt/orbbec_ws/install
COPY --from=builder /opt/orbbec_ws/ORBBEC_PROVENANCE /opt/orbbec_ws/ORBBEC_PROVENANCE
COPY docker/entrypoint.sh /ros_entrypoint.sh
COPY scripts/*.sh /usr/local/bin/
RUN chmod +x /ros_entrypoint.sh /usr/local/bin/*.sh

# Optional: install OrbbecViewer (standalone GUI). Skip if ORBBEC_VIEWER_URL is empty.
ARG ORBBEC_VIEWER_URL
ARG ORBBEC_VIEWER_VERSION
RUN if [ -n "${ORBBEC_VIEWER_URL}" ]; then \
      apt-get update && apt-get install -y --no-install-recommends unzip \
      && rm -rf /var/lib/apt/lists/* \
      && curl -fsSL "${ORBBEC_VIEWER_URL}" -o /tmp/orbbecviewer.zip \
      && mkdir -p /opt/OrbbecViewer \
      && unzip -q /tmp/orbbecviewer.zip -d /opt/OrbbecViewer \
      && rm /tmp/orbbecviewer.zip \
      && ln -sf /opt/OrbbecViewer/OrbbecViewer_v${ORBBEC_VIEWER_VERSION}_*/OrbbecViewer /usr/local/bin/OrbbecViewer \
      && ln -sfn /opt/OrbbecViewer/OrbbecViewer_v${ORBBEC_VIEWER_VERSION}_* /opt/OrbbecViewer/current \
      && OrbbecViewer --help 2>&1 | head -1 || true; \
    fi

WORKDIR /workspaces/orbbec
ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["ros2", "launch", "orbbec_camera", "femto_bolt.launch.py"]
