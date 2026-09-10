FROM registry.fedoraproject.org/fedora@sha256:3a0aef5c71304d0a6e5519ca899efcdc41323ba2049511d9d6df27a8cf6c69d3
RUN dnf install -y python3 desktop-file-utils xorg-x11-server-Xvfb xorg-x11-xauth \
    dbus-x11 dejavu-sans-fonts gtk3 mesa-dri-drivers libglvnd-glx libglvnd-egl \
    libglvnd-gles polkit systemd-udev
