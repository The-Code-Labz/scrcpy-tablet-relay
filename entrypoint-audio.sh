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
# Runs on the SAME bridge network + Traefik wiring as scrcpy-relay (not
# network_mode: host — tried that first; on a hardened host it means
# Traefik's own container can't reach this one's host-bound port at all,
# since this kind of host blocks container-to-unpublished-host-port
# traffic by design, and the fix would otherwise poke a hole through that
# intentional hardening). WebRTC's ICE candidates still negotiate fine
# through ordinary Docker bridge NAT for most networks — it behaves like
# any address/port-restricted-cone NAT, which is exactly what STUN is
# for. Only a genuinely symmetric NAT on the viewer's side would defeat
# it, in which case tango-mirror's `--turn` flag is the next step (not
# wired through this repo yet).

set -u

TABLET_HOST="${TABLET_HOST:?TABLET_HOST is required (tablet IP or Tailscale hostname)}"
TANGO_TOKEN="${TANGO_TOKEN:-}"
if [ -z "${TANGO_TOKEN}" ]; then
  echo "[audio] WARNING: TANGO_TOKEN is not set — the device list/stream are unauthenticated for anyone who can reach this service (mesh-only via Traefik's ipallowlist, same as scrcpy-relay, but still worth setting)"
fi
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

# iOS 16.4+ "Home Screen web apps" launch from the manifest's start_url,
# not the page you were on when you tapped Add to Home Screen — so a
# plain ?token= in the browser bar at install time is silently dropped on
# every subsequent cold launch of the installed icon, and the app just
# shows the "unauthorized" screen. Bake the real token into start_url at
# boot (only known value is the runtime TANGO_TOKEN, not available at
# image build time), so the installed PWA always launches authenticated.
# tango-mirror's own client.js reads ?token= on load, saves it to
# localStorage, then scrubs it from the visible URL — this just gives it
# something to read on every cold start instead of only the first one.
MANIFEST_PATH="/opt/tango-mirror/node_modules/tango-mirror/public/manifest.webmanifest"
if [ -f "${MANIFEST_PATH}" ]; then
  if [ -n "${TANGO_TOKEN}" ]; then
    ESCAPED_TOKEN=$(printf '%s' "${TANGO_TOKEN}" | sed 's/[&|\\]/\\&/g')
    sed -i "s|__TANGO_START_QUERY__|?token=${ESCAPED_TOKEN}|" "${MANIFEST_PATH}"
  else
    sed -i "s|__TANGO_START_QUERY__||" "${MANIFEST_PATH}"
  fi
fi

echo "[audio] starting tango-mirror on :${TANGO_PORT}"
TANGO_ARGS=(--port "${TANGO_PORT}" --no-signal --no-page --adb-host 127.0.0.1 --adb-port 5037)
[ -n "${TANGO_TOKEN}" ] && TANGO_ARGS+=(--token "${TANGO_TOKEN}")
node /opt/tango-mirror/node_modules/tango-mirror/server.mjs "${TANGO_ARGS[@]}" &
TANGO_PID=$!
wait "${TANGO_PID}"
cleanup
