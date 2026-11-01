#!/usr/bin/env bash
# scrcpy-tablet-relay entrypoint
# 1. (Optional) one-time Wireless Debugging pairing.
# 2. Connect adb to the tablet. Android 11+ Wireless Debugging's *connect*
#    port is an OS-assigned ephemeral port that changes on every Wi-Fi
#    reconnect, reboot, or debugging toggle — there is nothing to "pin".
#    The officially intended way to find the live port is mDNS, but mDNS is
#    link-local multicast and does NOT traverse Tailscale's point-to-point
#    tunnels (Tailscale does not relay multicast/broadcast), which is this
#    project's primary deployment topology. So: try the last-known-good
#    port first (fast path, works most boots), and if that fails, fall back
#    to a bounded nmap port scan + adb-connect probe to rediscover it. No
#    more reading the port off the tablet's screen by hand.
# 3. Keepalive loop: periodically verify the connection and re-discover/
#    reconnect if it's gone (tablet reboot, Wi-Fi flap, port rotation).
# 4. Start ws-scrcpy web relay on :8000.

set -u

TABLET_HOST="${TABLET_HOST:?TABLET_HOST is required (tablet IP or Tailscale hostname)}"
TABLET_PORT="${TABLET_PORT:-}"                       # optional: fast-path hint, or legacy fixed port (e.g. 5555 via `adb tcpip`)
KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-30}"
PORT_DISCOVERY="${ADB_PORT_DISCOVERY:-auto}"          # auto | off
DISCOVERY_PORT_RANGE="${DISCOVERY_PORT_RANGE:-32768-61000}"  # covers every Wireless Debugging connect port observed in practice
PORT_CACHE_FILE="${PORT_CACHE_FILE:-$HOME/.android/relay_last_port}"
mkdir -p "$(dirname "${PORT_CACHE_FILE}")" 2>/dev/null || true
# ws-scrcpy's /relay-api (the web UI's pair/reconnect/QR endpoints — see
# RelayApi.ts) runs inside the same `node dist/index.js` process started
# below and needs this same cache path and target host/port to stay in
# sync with this script's own discovery. Variables already present in the
# container's initial environment (TABLET_HOST, TABLET_PORT, via `docker
# compose environment:`) are exported automatically; PORT_CACHE_FILE's
# default is computed here in bash, so it needs an explicit export or the
# Node child process backgrounded further down would never see it.
export TABLET_HOST TABLET_PORT PORT_CACHE_FILE

echo "[relay] target: ${TABLET_HOST} (port discovery: ${PORT_DISCOVERY})"
echo "[relay] keepalive every ${KEEPALIVE_INTERVAL}s"

# One-time Wireless Debugging pairing. Android 11+ wireless debugging
# requires the device to trust this container's adb public key before any
# `adb connect` will do anything but hang at "offline" — set PAIR_HOST/
# PAIR_PORT/PAIR_CODE (from the tablet's Settings > Developer options >
# Wireless debugging > "Pair device with pairing code" screen) for one
# deploy to establish trust, then unset them again. Once paired, the key
# (persisted under ~/.android via the adb-data volume) is trusted
# permanently — this block is a no-op on every boot after that.
if [ -n "${PAIR_HOST:-}" ] && [ -n "${PAIR_PORT:-}" ] && [ -n "${PAIR_CODE:-}" ]; then
  echo "[relay] pairing with ${PAIR_HOST}:${PAIR_PORT}"
  adb pair "${PAIR_HOST}:${PAIR_PORT}" "${PAIR_CODE}" || echo "[relay] pairing failed (code likely expired) — set fresh PAIR_* vars and redeploy"
fi

# True (prints the matching `adb devices` line) if adb currently has a live,
# authorized session (state "device", not "offline"/"unauthorized") to
# TABLET_HOST on any port.
is_connected() {
  adb devices | grep -E "^${TABLET_HOST}:[0-9]+[[:space:]]+device([[:space:]]|$)"
}

# Fast path: try a single candidate port (cached-last-good, or the pinned
# TABLET_PORT) before paying for a full scan.
try_known_port() {
  local port="$1"
  [ -z "$port" ] && return 1
  echo "[relay] trying known port ${TABLET_HOST}:${port}"
  adb connect "${TABLET_HOST}:${port}" >/dev/null 2>&1 || true
  sleep 1
  is_connected | grep -q ":${port}[[:space:]]"
}

# Fallback: bounded nmap scan of the ephemeral port range for open TCP
# listeners on TABLET_HOST, then adb-connect-probe each candidate in turn.
# Only a real adb TLS listener actually authenticates and flips to "device"
# in `adb devices` — everything else fails the probe fast and we move on.
# This replaces manually reading the port off the tablet's Wireless
# debugging screen after every Wi-Fi reconnect/reboot/toggle.
discover_port() {
  echo "[relay] port discovery: scanning ${TABLET_HOST} ${DISCOVERY_PORT_RANGE} (can take up to ~60s)"
  local candidates
  candidates="$(nmap -Pn -n -T4 --min-rate 500 -p "${DISCOVERY_PORT_RANGE}" --open "${TABLET_HOST}" 2>/dev/null \
    | awk -F/ '/\/tcp.*open/{print $1}')"
  if [ -z "${candidates}" ]; then
    echo "[relay] port discovery: no open ports found in range ${DISCOVERY_PORT_RANGE}"
    return 1
  fi
  local port
  for port in ${candidates}; do
    echo "[relay] port discovery: probing candidate ${port}"
    if try_known_port "${port}"; then
      echo "[relay] port discovery: confirmed ${TABLET_HOST}:${port}"
      echo "${port}" > "${PORT_CACHE_FILE}" 2>/dev/null || true
      CURRENT_PORT="${port}"
      return 0
    fi
    adb disconnect "${TABLET_HOST}:${port}" >/dev/null 2>&1 || true
  done
  echo "[relay] port discovery: scanned ${TABLET_HOST} but no open port was a connectable adb session (pairing may be missing/stale — see PAIR_* vars)"
  return 1
}

# Establish (or re-establish) the adb connection: cached-last-good port,
# then pinned TABLET_PORT, then (unless disabled) a full discovery scan.
CURRENT_PORT=""
connect_tablet() {
  local cached=""
  [ -f "${PORT_CACHE_FILE}" ] && cached="$(cat "${PORT_CACHE_FILE}" 2>/dev/null || true)"

  local port
  for port in "${cached}" "${TABLET_PORT}"; do
    if try_known_port "${port}"; then
      CURRENT_PORT="${port}"
      echo "${port}" > "${PORT_CACHE_FILE}" 2>/dev/null || true
      echo "[relay] connected on ${TABLET_HOST}:${port}"
      return 0
    fi
  done

  if [ "${PORT_DISCOVERY}" = "off" ]; then
    echo "[relay] port discovery disabled (ADB_PORT_DISCOVERY=off) and no known port worked"
    return 1
  fi
  if ! command -v nmap >/dev/null 2>&1; then
    echo "[relay] nmap not available — cannot auto-discover port"
    return 1
  fi

  if discover_port; then
    echo "[relay] connected on ${TABLET_HOST}:${CURRENT_PORT}"
    return 0
  fi
  return 1
}

# Kill the keepalive loop and ws-scrcpy, then disconnect adb.
cleanup() {
  echo "[relay] shutting down"
  kill "${KEEPALIVE_PID:-}" 2>/dev/null || true
  kill "${NODE_PID:-}" 2>/dev/null || true
  if [ -n "${CURRENT_PORT}" ]; then
    adb disconnect "${TABLET_HOST}:${CURRENT_PORT}" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup TERM INT

connect_tablet || echo "[relay] initial connect failed — keepalive loop will keep retrying/rediscovering"

# ---- keepalive loop ----
(
  while true; do
    sleep "${KEEPALIVE_INTERVAL}"
    if ! is_connected >/dev/null; then
      echo "[keepalive] ${TABLET_HOST} not connected — reconnecting (will re-discover port if it rotated)"
      connect_tablet || echo "[keepalive] reconnect/discovery failed, will retry next tick"
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
cd /opt/ws-scrcpy || exit 1
node dist/index.js &
NODE_PID=$!
wait "${NODE_PID}"
cleanup
