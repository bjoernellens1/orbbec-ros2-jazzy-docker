# syntax=docker/dockerfile:1.7

ARG ROS_DISTRO=jazzy
ARG BASE_IMAGE=ros:jazzy-ros-base
ARG ORBBEC_REPO=https://github.com/orbbec/OrbbecSDK_ROS2.git
ARG ORBBEC_REF=v2-main
# OrbbecViewer (standalone GUI). Set to empty string to skip.
ARG ORBBEC_VIEWER_URL=https://github.com/orbbec/OrbbecSDK/releases/download/v1.10.27/OrbbecViewer_v1.10.27_202509260133_linux_x64_release.zip
ARG ORBBEC_VIEWER_VERSION=1.10.27

FROM ${BASE_IMAGE} AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG ROS_DISTRO
ARG ORBBEC_REPO
ARG ORBBEC_REF
ENV DEBIAN_FRONTEND=noninteractive \
    ROS_DISTRO=${ROS_DISTRO} \
    ROS_WS=/opt/orbbec_ws

# Build-only dependencies. Runtime image below installs only what is needed to run.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      git \
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

RUN mkdir -p ${ROS_WS}/src \
    && git clone --depth 1 --branch ${ORBBEC_REF} ${ORBBEC_REPO} ${ROS_WS}/src/OrbbecSDK_ROS2

WORKDIR ${ROS_WS}
RUN source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build \
       --merge-install \
       --event-handlers console_direct+ \
       --cmake-args -DCMAKE_BUILD_TYPE=Release

# Strip symbols where possible to keep runtime copy smaller.
RUN find ${ROS_WS}/install -type f -executable -exec strip --strip-unneeded {} + 2>/dev/null || true

FROM ${BASE_IMAGE} AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG ROS_DISTRO
LABEL org.opencontainers.image.title="orbbec-ros2-jazzy-docker" \
      org.opencontainers.image.description="Minimal ROS 2 Jazzy container for OrbbecSDK_ROS2 v2 / Femto Bolt publishing" \
      org.opencontainers.image.source="https://github.com/bjoernellens1/orbbec-ros2-jazzy-docker" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV DEBIAN_FRONTEND=noninteractive \
    ROS_DISTRO=${ROS_DISTRO} \
    ROS_WS=/opt/orbbec_ws \
    RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    RCUTILS_COLORIZED_OUTPUT=1 \
    PYTHONUNBUFFERED=1

# Runtime-only dependencies for ROS transport, camera info, diagnostics and USB/OpenGL libs
# required by the upstream wrapper/SDK.
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
      ros-${ROS_DISTRO}-statistics-msgs \
      ros-${ROS_DISTRO}-xacro \
      udev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/orbbec_ws/install /opt/orbbec_ws/install
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
      && OrbbecViewer --help 2>&1 | head -1 || true; \
    fi

WORKDIR /workspaces/orbbec
ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["ros2", "launch", "orbbec_camera", "femto_bolt.launch.py"]
