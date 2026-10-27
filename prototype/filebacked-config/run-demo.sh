#!/bin/sh
# Runs the PoC in the openwrt/rootfs container (ucode present), like confsh tests.
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
ENGINE=${ENGINE:-podman}
IMAGE=${IMAGE:-docker.io/openwrt/rootfs:x86-64-25.12.3}
exec "$ENGINE" run --rm -i -v "$ROOT:/src:ro,Z" "$IMAGE" /bin/sh -s <<'IN'
export PATH=/src/bin:$PATH
export FB_LIVE=/tmp/fb/live FB_SESSION=/tmp/fb/session FB_ARCHIVE=/tmp/fb/archive FB_ZONE=lab.example
mkdir -p /tmp/fb/live && cp /src/sample/db.lab.example /tmp/fb/live/
U="ucode /src/fb.uc"
echo "===== initial live zone ====="; cat /tmp/fb/live/db.lab.example
echo; echo "===== configure + add www/mail ====="; $U configure; $U set www A 10.0.0.20; $U set mail A 10.0.0.25
echo; echo "===== show (staged vs live) ====="; $U show
echo; echo "===== commit #1 (validate, archive, freeze/thaw, apply) ====="; $U commit
echo; echo "===== live zone after commit #1 ====="; cat /tmp/fb/live/db.lab.example
echo; echo "===== add vpn + commit #2 ====="; $U configure; $U set vpn A 10.0.0.30; $U commit
echo; echo "===== revisions ====="; $U commits
echo; echo "===== rollback to revision 2 (state after commit #1) ====="; $U rollback 2
echo; echo "===== live zone after rollback (vpn gone, www/mail kept) ====="; cat /tmp/fb/live/db.lab.example
IN
