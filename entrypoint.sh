#!/usr/bin/env bash
# scrcpy-tablet-relay entrypoint
# 1. Connect adb to the tablet (wireless debugging, port pinned at 5555)
# 2. Keepalive loop: re-run `adb connect` every KEEPALIVE_INTERVAL seconds.
#    `adb connect` against an already-connected device is a cheap no-op, so
#    this self-heals tablet reboots, Wi-Fi flaps, and relay restarts.
# 3. Start ws-scrcpy web relay on :8000.

set -u

TABLET_HOST="${TABLET_HOST:?TABLET_HOST is required (tablet IP or Tailscale hostname)}"
TABLET_PORT="${TABLET_PORT:-5555}"
KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-30}"

echo "[relay] target: ${TABLET_HOST}:${TABLET_PORT}"
echo "[relay] keepalive every ${KEEPALIVE_INTERVAL}s"

# Kill the keepalive loop and ws-scrcpy, then disconnect adb.
cleanup() {
  echo "[relay] shutting down"
  kill "${KEEPALIVE_PID:-}" 2>/dev/null || true
  kill "${NODE_PID:-}" 2>/dev/null || true
  adb disconnect "${TABLET_HOST}:${TABLET_PORT}" 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT

# First connect is blocking-ish: give the tablet a moment to accept.
adb connect "${TABLET_HOST}:${TABLET_PORT}" || true

# ---- keepalive loop ----
(
  while true; do
    sleep "${KEEPALIVE_INTERVAL}"
    # List what adb thinks is connected; reconnect only if the tablet is gone.
    if ! adb devices | grep -q "${TABLET_HOST}:${TABLET_PORT}.*device"; then
      echo "[keepalive] ${TABLET_HOST}:${TABLET_PORT} not connected — reconnecting"
      adb connect "${TABLET_HOST}:${TABLET_PORT}" || true
      # Extra wait for authorization prompt on first pairing after reboot
      sleep 5
      adb devices
    fi
  done
) &
KEEPALIVE_PID=$!

# ---- ws-scrcpy ----
echo "[relay] starting ws-scrcpy on :8000"
# Run node in the background (not `exec`) so the trap above stays live on
# this shell — `exec`ing node would replace the shell process image and the
# trap would never fire on TERM/INT, leaving adb connected and the keepalive
# loop orphaned until Docker SIGKILLs the whole cgroup.
cd /opt/ws-scrcpy
node dist/index.js &
NODE_PID=$!
wait "${NODE_PID}"
cleanup
