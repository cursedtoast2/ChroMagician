#!/bin/sh
set -eu
if command -v python3 || command -v esptool || command -v openFPGALoader; then
    printf '%s\n' 'Test image unexpectedly contains a host flashing tool/runtime.' >&2
    exit 1
fi
cp -r /opt/ChroMagician '/tmp/moved app'
cd /
'/tmp/moved app/firmware/tools/esptool' version
'/tmp/moved app/firmware/tools/openFPGALoader' --version
'/tmp/moved app/firmware/tools/openFPGALoader' --scan-usb
'/tmp/moved app/libexec/chromatic-backup' --devices --json

test ! -e '/tmp/moved app/setup-usb.sh'
test ! -e '/tmp/moved app/70-chromagician.rules'

mkdir -p /tmp/.chromagician-update-smoke
export CHROMAGIC_UPDATE_ACK=/tmp/.chromagician-update-smoke/started.json
export LIBGL_ALWAYS_SOFTWARE=1 GDK_BACKEND=x11
dbus-run-session -- xvfb-run -a '/tmp/moved app/chromatic_pc_backup' >/tmp/app.log 2>&1 &
app=$!
trap 'kill "$app" 2>/dev/null || true' EXIT
count=0
until test -f "$CHROMAGIC_UPDATE_ACK"; do
    count=$((count + 1))
    if test "$count" -ge 30; then cat /tmp/app.log; exit 1; fi
    sleep 1
done
cat "$CHROMAGIC_UPDATE_ACK"
printf '\n%s\n' 'Clean Linux desktop: packaged Flutter first frame and native tools passed.'
