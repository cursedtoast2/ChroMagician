FROM docker.io/library/ubuntu@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgtk-3-0 libgl1-mesa-dri libegl1 libgl1 libgles2 xvfb xauth dbus-x11 fonts-dejavu-core udev && \
    rm -rf /var/lib/apt/lists/*
