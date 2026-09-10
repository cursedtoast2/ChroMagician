FROM docker.io/library/ubuntu@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 desktop-file-utils xvfb xauth dbus-x11 fonts-dejavu-core \
    libgtk-3-0 libgl1-mesa-dri libegl1 libgl1 libgles2 udev policykit-1
