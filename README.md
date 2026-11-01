# scrcpy-tablet-relay

Turn a Samsung Tab A9+ (or any Android 11+ tablet) into a **persistent app host** —
fully viewable and controllable from an iPhone through a web browser, no cables,
no per-session setup.

```
┌──────────────┐   wireless adb (port auto-discovered) ┌──────────────────────┐   HTTPS/WSS   ┌────────┐
│  Tab A9+     │ ──────────────────────────────────▶ │  scrcpy-relay        │ ────────────▶ │ iPhone │
│  (apps run   │                                     │  Docker container    │               │ Safari │
│   24/7)      │ ◀────────────────────────────────── │  adb + ws-scrcpy     │ ◀──────────── │  PWA   │
└──────────────┘   scrcpy video stream + touch input  └──────────────────────┘               └────────┘
                                                            │ bound to Tailscale IP
                                                       (see BIND_HOST below)
```

* **Real touch injection** — scrcpy's native multitouch protocol, not VNC mouse emulation.
  Scrolling, pinch, long-press, and app gestures work like they do in your hand.
* **No audio** — this relay has no audio pipeline at all; see *Audio caveats* below.
* **Screen can stay off** — toggle "Set screen power mode" in the in-stream
  settings panel to turn the tablet's physical display off while mirroring/
  touch control keep working; see *Keeping the screen off* below.
* **Self-healing** — a keepalive loop reconnects adb every 30 s after tablet reboots,
  Wi-Fi flaps, or relay restarts, and auto-rediscovers the Wireless Debugging connect
  port when it rotates. No manual intervention.
* **Tailscale-bound** — `BIND_HOST` publishes port 8000 only on the relay
  host's Tailscale IP, since ws-scrcpy has no built-in authentication.

---

## 1. One-time tablet setup (Tab A9+, Android 13/14/15)

1. **Enable Developer Options**: `Settings → About tablet → Software information` →
   tap **Build number** 7 times.
2. **Enable Wireless debugging**: `Settings → Developer options → Wireless debugging` → ON.
   No USB cable needed at any point — pairing happens over the network too.
3. **Pair once** — tap **Pair device with pairing code**: it shows an `ip:port` and a
   6-digit code (expires in ~60s). Put the ip/port in `PAIR_HOST`/`PAIR_PORT` and the
   code in `PAIR_CODE` in `.env`, then `docker compose up -d` immediately. Check
   `docker compose logs` for `Successfully paired`, then blank `PAIR_*` back out — the
   trust persists in `./adb-data` and survives redeploys/reboots. (This first pairing
   still needs `.env` + a redeploy since nothing is listening yet; every pairing
   *after* this one — see *Reconnecting from the web UI*, below — can be done straight
   from the browser, no shell/redeploy needed.)
4. That's it — you do **not** need to read or pin any port. Wireless Debugging's
   *connect* port (shown on the main Wireless debugging screen, separate from the
   pairing screen) rotates on every Wi-Fi reconnect/reboot/toggle; the relay
   auto-discovers it itself (see `ADB_PORT_DISCOVERY` below) instead of you reading it
   off the tablet's screen each time.
5. **Note the tablet's IP**: `Settings → Wi-Fi → <your network>` (or give the tablet a
   DHCP reservation / use its Tailscale IP if Tailscale is installed on it).

## 2. Deploy the relay

Requires: Docker + docker compose plugin.

```bash
git clone https://github.com/The-Code-Labz/scrcpy-tablet-relay.git
cd scrcpy-tablet-relay
cp .env.example .env
# edit .env — set TABLET_HOST (tablet LAN IP or Tailscale hostname) and
# BIND_HOST (the relay host's own Tailscale IP, from `tailscale ip -4`)
docker compose up -d --build
docker compose logs -f           # watch: "[relay] target ..." then ws-scrcpy startup
```

Open `http://<relay-host>:8000` — the ws-scrcpy page lists your tablet.
Click it → live mirror with full touch control.

## 3. iPhone access (Tailscale)

1. Install [Tailscale](https://tailscale.com) on the relay host **and** the iPhone;
   log both into the same tailnet.
2. On the iPhone: Safari → `http://<relay-tailscale-hostname>:8000` → open the tablet.
3. **Add to Home Screen** (Share → *Add to Home Screen*) — it becomes a fullscreen PWA:
   no Safari chrome, looks like a native app.

> Plain `http` is fine on a tailnet (WireGuard-encrypted). If you want a padlock,
> front the relay with Caddy/nginx on the same host with a Tailscale cert.

## 4. Making the tablet a persistent app host

* **Never let it sleep on Wi-Fi**: `Settings → Display → Screen timeout` → max, and
  `Settings → Developer options → Stay awake` (while charging) ON. Keep it on a charger.
* **Disable battery optimization** for your hosted apps so Android doesn't kill them.
* scrcpy keeps the screen mirrored but the tablet can run fully headless —
  the relay stays attached even when the screen is off. See *Keeping the
  screen off* below for the in-stream toggle that does this on demand.

---

## Keeping the screen off while mirroring

The scrcpy protocol has a dedicated `SET_SCREEN_POWER_MODE` command for this
and ws-scrcpy already exposes it — no code change needed, it's just buried:

1. Connect to the tablet in the browser.
2. Open the **≡ / kebab "more" panel** in the toolbox (the settings icon
   next to the stream, not the device-list "Configure stream" gear — that
   one is pre-connect video settings only).
3. Find the checkbox + **"Set screen power mode OFF/ON"** button. Leave the
   checkbox unchecked and click the button once — it sends power-mode
   **OFF**, which blanks the physical display while the capture pipeline
   (and your touch input) keeps running. Check the box and click again to
   send **ON** and light the screen back up.

Caveats, confirmed by testing:

* This blanks the panel only — it does **not** put the tablet to sleep.
  If the tablet's own idle/lock timeout fires anyway (see step 4 above),
  Android can still Doze the Wi-Fi radio on battery; keep it on a charger
  with "Stay awake while charging" ON so the Wireless Debugging socket
  doesn't drop.
* The toggle is per-session — it doesn't persist across a reconnect to
  the scrcpy stream.

---

## Audio caveats (no audio, on any client)

This relay has **no audio support at all** — not a browser-decode limitation,
a missing feature. The web client (`NetrisTV/ws-scrcpy`), even on current
upstream `master`, vendors a `scrcpy-server.jar` with **zero audio-related
classes or resources inside it** (checked by listing the jar's contents,
not just string-matching) — there is no server-side audio capture path, and
the TypeScript client has no audio decoder/player to go with it either way.
Tracked upstream at [ws-scrcpy#38](https://github.com/NetrisTV/ws-scrcpy/discussions/38),
still an open research discussion, not a shipped feature.

Workarounds:

1. Play audio natively on the tablet (it stays audible on-device through its
   own speakers/Bluetooth) while the relay only mirrors video + input.
2. Casting the tablet's audio separately (e.g. a local Bluetooth speaker near
   the tablet) if you need it audible where the relay client is.

Fixing this for real means swapping the underlying relay technology, not
patching this one — `ws-scrcpy`'s architecture has no audio code path to
extend. A real option exists:
[`tiann/tango-mirror`](https://github.com/tiann/tango-mirror) (MIT) pushes
the **stock, current scrcpy v3.1 server** to the device and streams
screen + Opus audio + touch over WebRTC straight to any browser, no
transcoding. It's a different stack top to bottom (Node CLI + WebRTC +
its own link/token auth, not this repo's Docker/Traefik/Tailscale model),
so adopting it means replacing this relay, not patching it. Ask if you want
that scoped as a separate project.

## Reconnecting from the web UI

Port rotation (the tablet's Wireless Debugging connect port changing on
every Wi-Fi reconnect/reboot) is already self-healed by entrypoint.sh's
keepalive loop — you should never need to do anything for that. What it
*can't* fix is **trust loss**: if the tablet revokes its adb pairing (toggling
Wireless debugging off/on, "Revoke wireless debugging authorizations", a
factory reset, etc.), every connect attempt reports `offline` forever until
someone re-pairs. Previously that meant shelling into the container and
running `adb pair` by hand. Now there's a **Reconnect** button (bottom-right
of the web UI, on every page) that does it from the browser:

- **Port + Code tab** — mirrors `Settings → Developer options → Wireless
  debugging → Pair device with pairing code` on the tablet: type the host,
  the pairing port and the 6-digit code it shows, hit **Pair & Connect**.
  This always works as long as you can reach the tablet's pairing port from
  the relay container (same as the one-time setup in step 1, just without
  needing `.env`/a redeploy).
- **QR Code tab** — mirrors `Pair device with QR code`: the browser shows a
  QR code, you scan it on the tablet, and the relay watches for the
  resulting mDNS pairing broadcast and pairs automatically. **This needs
  mDNS multicast from the tablet to actually reach the container** — true on
  a shared LAN or `network_mode: host`, generally **not** true over a
  Tailscale-only hop (Tailscale doesn't relay multicast). It times out with
  a clear message after 90s if nothing shows up — use Port + Code instead
  when that happens.

Either flow only needs to re-establish trust once; the keepalive loop takes
it from there (within `KEEPALIVE_INTERVAL` seconds) even if the immediate
reconnect attempt misses. The backing API lives at `/relay-api/*` on the same
port 8000 — no extra ports or firewall rules needed, it rides through
`BIND_HOST`/Traefik exactly like the stream itself.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `adb connect` hangs / "unable to connect" | Check Wireless debugging is still ON on the tablet. If it is, `docker compose logs` should show `[relay] port discovery: scanning...` self-healing it within ~60s — if discovery also fails, pairing has likely gone stale (see below) |
| Port discovery finds nothing / scan comes up empty | Pairing trust was lost (factory reset, "Revoke wireless debugging authorizations", or `./adb-data` volume wiped) — use the **Reconnect** button in the web UI (Port + Code or QR tab), or re-run the `PAIR_*` one-time pairing step |
| Shows `unauthorized` | Pairing trust lost — use the **Reconnect** button in the web UI, or re-run the `PAIR_*` one-time pairing step (see *One-time tablet setup*) |
| Works, then drops after tablet reboot/Wi-Fi flap | Normal — the keepalive loop reconnects within `KEEPALIVE_INTERVAL` seconds, re-discovering the connect port if it rotated |
| Tablet IP changed | Use a DHCP reservation, or set `TABLET_HOST` to the tablet's **Tailscale hostname** (stable) and install Tailscale on the tablet |
| ws-scrcpy page is empty / no device | Check `docker compose logs` — adb must show the device as `device`, not `offline`/`unauthorized`; look for `[relay] port discovery` lines to see if a scan is in progress or failing |
| Laggy video | ws-scrcpy has no server-side bitrate flags/env vars. The image now ships higher default quality (MSE player: 16 Mbps / up to 1600px; WebCodecs player: 8 Mbps / up to 1600px / 60 fps, up from upstream's 512 kbps–7.3 Mbps 480–720px defaults) — if it's still laggy, your network is the bottleneck, not the defaults. You can still click the gear/**Configure stream** button next to the tablet *before* connecting to tune **Bitrate** / **Max size** per session |
| No audio | Expected — see *Audio caveats*. This relay has no audio pipeline at all, on any client |
| Screen won't stay off / keeps waking | That's the tablet's own lock timeout firing, not the relay — see *Keeping the screen off*, and make sure "Stay awake while charging" is ON |

## PWA / "Add to Home Screen" behavior

The image now ships a real app shell: `manifest.webmanifest`, a minimal
service worker, and app icons, all generated at build time and served from
the ws-scrcpy static root (`/manifest.webmanifest`, `/sw.js`, `/icon-*.png`).

* **iPhone (Safari):** Share → **Add to Home Screen** installs it as a
  standalone app (no Safari chrome), with the app icon and a
  `black-translucent` status bar, honoring the notch/home-indicator safe
  areas.
* **Android (Chrome):** gets an install prompt / "Install app" menu entry.
* The service worker only caches the HTML shell for offline opening — it
  deliberately never touches the video/control WebSocket traffic
  (`?action=proxy-adb&...`), so there's no risk of it serving stale/cached
  stream data.
* Touch targets (toolbox buttons, device list rows, dialog buttons) are
  enlarged to ≥44px on coarse-pointer (touch) devices, and the stream/touch
  surface disables text-selection callouts and rubber-band scrolling so it
  feels like a native app rather than a web page.
* If iOS evicts the PWA from memory, reopening it reconnects in a few
  seconds — this is normal iOS background-tab behavior, not a relay issue.

## Configuration

All in `.env` (see `.env.example`):

| Variable | Default | Purpose |
|---|---|---|
| `TABLET_HOST` | — (required) | Tablet IP or Tailscale hostname |
| `TABLET_PORT` | _(blank)_ | Optional fast-path/legacy fixed port. Leave blank for Wireless debugging — auto-discovered instead |
| `ADB_PORT_DISCOVERY` | `auto` | `auto` scans for the live port when the known one fails; `off` disables scanning (legacy fixed-port only) |
| `DISCOVERY_PORT_RANGE` | `32768-61000` | Port range scanned during discovery |
| `PAIR_HOST` / `PAIR_PORT` / `PAIR_CODE` | _(blank)_ | One-time Wireless debugging pairing — set from the tablet's pairing screen, redeploy once, blank out again |
| `KEEPALIVE_INTERVAL` | `30` | Seconds between adb reconnect checks |
| `BIND_HOST` | `127.0.0.1` | Host IP port 8000 is published on — set to your Tailscale IP |
| `IMAGE_TAG` | `latest` | Tag pulled from `ghcr.io/the-code-labz/scrcpy-tablet-relay` |
| `SCRCPY_HOSTNAME` | `scrcpy.example.com` | Hostname Traefik routes to this service (Traefik users only) |
| `TRAEFIK_NETWORK` | `dokploy-network` | Docker network your Traefik instance watches (Traefik users only) |
| `TRAEFIK_CERTRESOLVER` | `cloudflare` | Traefik certresolver for automatic TLS (Traefik users only) |

### Traefik (optional)

`docker-compose.yml` ships Traefik labels and attaches the container to an
external `traefik-network` (named via `TRAEFIK_NETWORK`, default
`dokploy-network`) alongside the default bridge network ws-scrcpy/adb use.

- **Running Traefik already?** Set `SCRCPY_HOSTNAME`/`TRAEFIK_NETWORK`/
  `TRAEFIK_CERTRESOLVER` in `.env` to match your setup. Traefik terminates
  TLS and proxies ws-scrcpy's WebSocket upgrade transparently — no extra
  middleware needed (just don't attach a compression middleware to this
  router, that breaks WS).
- **Not running Traefik?** Nothing to do — the direct `BIND_HOST:8000`
  publish still works exactly as before. To fully remove the Traefik
  wiring, delete the `labels:` block, the `traefik-network` network, and
  its entry under the service's `networks:` key.
- The external network must already exist and have Traefik attached to it
  (`docker network create dokploy-network` if you're starting fresh) —
  Traefik only discovers containers on networks it's watching; labels alone
  aren't enough.

## Files

```
Dockerfile              Node 20 + adb + nmap + ws-scrcpy build
entrypoint.sh           pair → connect (cache/pin/nmap-discover port) → 30s keepalive loop → ws-scrcpy on :8000
docker-compose.yml      restart: unless-stopped; BIND_HOST direct publish + optional Traefik labels
.env.example            configuration template
docker/webclient/       build-time overlay on ws-scrcpy: PWA app shell
                        (manifest/service-worker/icons), mobile/touch CSS,
                        the Reconnect widget (pair/connect/QR UI), and the
                        /relay-api server routes backing it — all applied
                        before `npm run dist` in the Dockerfile
```
