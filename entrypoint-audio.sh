#!/usr/bin/env bash
# scrcpy-tablet-relay audio sidecar entrypoint.
#
# ws-scrcpy (the main `scrcpy-relay` service) cannot carry audio: its
# vendored scrcpy-server predates scrcpy's audio protocol (added in
# scrcpy 2.0). This sidecar runs tango-mirror instead, which pushes the
# current stock scrcpy v3.1 server and streams video+Opus audio+touch over
# WebRTC (falling back to a WebSocket+WebCodecs path on localhost/tunnel
# use, not relevant to our Tailscale deployment).
#
# It deliberately does NOT duplicate scrcpy-relay's nmap port-discovery
# logic. Both services mount the same ./adb-data volume (over ~/.android),
# so this container inherits: (a) the already-trusted adb keypair, and
# (b) PORT_CACHE_FILE, the live Wireless Debugging connect port that
# scrcpy-relay's entrypoint.sh discovers/caches/self-heals on its own. This
# script just reads that same cache file and connects its own independent
# adb session to it — Android allows multiple concurrent wireless-debugging
# clients against one trusted key, so this doesn't interfere with
# scrcpy-relay's own connection.
#
# Runs with `network_mode: host` (see docker-compose.yml) because WebRTC's
# media (UDP, ICE) needs direct host-port reachability that Docker's bridge
# NAT does not provide for ephemeral/unpublished ports, and tango-mirror
# exposes no CLI flag to pin its ICE port range. TANGO_TOKEN is therefore
# REQUIRED (not optional) — unlike ws-scrcpy, host networking here would
# otherwise mean an unauthenticated screen+audio+touch session reachable
# from every interface the host has, not just the tailnet.

set -u

TABLET_HOST="${TABLET_HOST:?TABLET_HOST is required (tablet IP or Tailscale hostname)}"
TANGO_TOKEN="${TANGO_TOKEN:?TANGO_TOKEN is required — host networking means this port is reachable beyond the tailnet without it}"
TANGO_PORT="${TANGO_PORT:-8010}"
KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-30}"
PORT_CACHE_FILE="${PORT_CACHE_FILE:-$HOME/.android/relay_last_port}"

echo "[audio] target: ${TABLET_HOST} (reading discovered port from ${PORT_CACHE_FILE})"

connect_tablet() {
  local port=""
  [ -f "${PORT_CACHE_FILE}" ] && port="$(cat "${PORT_CACHE_FILE}" 2>/dev/null || true)"
  [ -z "${port}" ] && port="${TABLET_PORT:-}"
  if [ -z "${port}" ]; then
    echo "[audio] no known port yet (scrcpy-relay hasn't discovered one) — will retry"
    return 1
  fi
  adb connect "${TABLET_HOST}:${port}" >/dev/null 2>&1 || true
  sleep 1
  adb devices | grep -q "^${TABLET_HOST}:${port}[[:space:]]\+device"
}

cleanup() {
  echo "[audio] shutting down"
  kill "${KEEPALIVE_PID:-}" 2>/dev/null || true
  kill "${TANGO_PID:-}" 2>/dev/null || true
  adb disconnect "${TABLET_HOST}" 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT

connect_tablet || echo "[audio] initial connect failed — keepalive will keep retrying"

(
  while true; do
    sleep "${KEEPALIVE_INTERVAL}"
    adb devices | grep -q "^${TABLET_HOST}:[0-9]\+[[:space:]]\+device" || connect_tablet \
      || echo "[audio] keepalive reconnect failed, will retry next tick"
  done
) &
KEEPALIVE_PID=$!

echo "[audio] starting tango-mirror on :${TANGO_PORT}"
node /opt/tango-mirror/node_modules/tango-mirror/server.mjs \
  --port "${TANGO_PORT}" \
  --no-signal \
  --no-page \
  --adb-host 127.0.0.1 \
  --adb-port 5037 \
  --token "${TANGO_TOKEN}" &
TANGO_PID=$!
wait "${TANGO_PID}"
cleanup
