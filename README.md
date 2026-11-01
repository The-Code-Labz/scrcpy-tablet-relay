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
* **Audio, optionally** — the main relay (ws-scrcpy) has no audio pipeline at
  all; a separate `scrcpy-audio` sidecar (tango-mirror, WebRTC + Opus) adds
  it — see *Audio* below.
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

## Audio (separate `scrcpy-audio` service)

The main `scrcpy-relay` service (`ws-scrcpy`) has **no audio support at
all** — not a browser-decode limitation, a missing feature. Even on current
upstream `master` it vendors a `scrcpy-server.jar` with **zero audio-related
classes or resources inside it** (checked by listing the jar's contents,
not just string-matching). That part of this README used to stop there and
recommend working around it; it no longer has to.

A second, optional Docker service — `scrcpy-audio` — runs
[`tiann/tango-mirror`](https://github.com/tiann/tango-mirror) (MIT), which
pushes the **stock, current scrcpy v3.1 server** to the device and streams
screen + **Opus audio** + touch over WebRTC straight to any browser, no
transcoding. It's a genuinely different stack under the hood (Node +
WebRTC, its own page), but it's wired into this repo as a sibling service
in the same `docker-compose.yml`, reusing the same image, the same
`./adb-data` adb trust, and the same live Wireless Debugging port that
`scrcpy-relay`'s entrypoint already discovers — so there's no second
pairing dance to do.

**Setup:**

1. Set `TANGO_TOKEN` in `.env` (required — see why below) and optionally
   `TANGO_PORT` (default `8010`).
2. `docker compose up -d` — both services start together.
3. Open `http://<host>:8010/?token=<TANGO_TOKEN>`. Pick the tablet from the
   device dropdown; tap the 🔇 icon to unmute audio (autoplay policies
   block sound until a user gesture).

**Why this needs its own HTTPS entry.** WebRTC/WebCodecs require a secure
context — `https://` or `localhost`, nothing else. This service does **not**
ride through the existing Traefik router/`BIND_HOST:8000` setup (different
port, different container network mode — see below), so you need a second
way to reach it over HTTPS. The cleanest option if the relay host already
runs Tailscale: `tailscale serve --bg --https=8010 http://127.0.0.1:8010`
gives you a real cert at `https://<host>.<tailnet>.ts.net:8010`, reachable
tailnet-wide and nowhere else, with zero extra infrastructure. Plain
Traefik routing also works if you point a router at the host's IP:8010
directly (it's not Docker-network-discoverable since the container runs in
`network_mode: host` — see below).

**Why `network_mode: host`, and why `TANGO_TOKEN` is not optional.**
WebRTC's media (UDP/ICE) needs the browser to reach whatever port the OS
hands out for that session — tango-mirror exposes no flag to pin that
range, so Docker's normal bridge-network NAT (which only forwards ports you
explicitly publish) would silently drop the media stream. Host networking
is the fix, but it means this port is reachable on **every interface the
host has**, not just the tailnet — a materially bigger exposure than the
main relay's `BIND_HOST` pattern. `TANGO_TOKEN` is required (no default) to
compensate: tango-mirror gates the device list and stream behind it
(`?token=...`), though the bare HTML shell itself still loads for anyone —
verified live: `/api/devices` returns `401 {"error":"unauthorized"}`
without the token, `200` with it.

**Honest caveats:**

- Default ICE servers are public STUN (Cloudflare + Google), baked into
  tango-mirror — fine for most home/Tailscale networks. If P2P fails on a
  stricter network (symmetric NAT/CGNAT on both ends), tango-mirror
  supports `--turn cloudflare` for a TURN relay; this repo doesn't wire that
  flag through yet — ask if you hit that wall.
- Verified end-to-end in a container (build, boot, HTTP 200s, token
  gating). **Not yet verified against real hardware** over your actual
  Tailscale link — confirm audio actually plays once deployed.
- The video-only `scrcpy-relay` service is completely unaffected — this is
  an addition, not a replacement. Comment the `scrcpy-audio` service out of
  `docker-compose.yml` if you don't want it running at all.

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
| No audio | Expected on `scrcpy-relay` (:8000) — it has no audio pipeline at all. Use the separate `scrcpy-audio` service (:8010, tango-mirror) instead — see *Audio* |
| No "Install" banner shown | Already dismissed (14-day local cooldown) or already installed (banner never shows in standalone mode) — clear site data to reset, or just use the browser's native Add to Home Screen / install menu directly |
| Screen won't stay off / keeps waking | That's the tablet's own lock timeout firing, not the relay — see *Keeping the screen off*, and make sure "Stay awake while charging" is ON |

## PWA / "Add to Home Screen" behavior

The image ships a real app shell on **both** services: `manifest.webmanifest`,
a minimal service worker, and app icons, generated at build time and served
from each app's static root (`/manifest.webmanifest`, `/sw.js`,
`/icon-*.png`). On top of that, both pages now show an explicit install
banner (`pwa-install.js`) — the manifest/service-worker alone only make the
app *installable*, they don't make either browser tell anyone that:

* **iPhone (Safari) never shows an automatic install prompt — ever.** That's
  an Apple platform limitation, not a bug or something a manifest/SW can
  change. The banner detects iOS Safari (and that the app isn't already
  running standalone) and shows: *"Install this app: tap the Share icon,
  then Add to Home Screen."* Doing that installs it as a standalone app (no
  Safari chrome), with the app icon and a `black-translucent` status bar,
  honoring the notch/home-indicator safe areas.
* **Android (Chrome)** fires a real `beforeinstallprompt` event, which the
  banner now captures and turns into a visible **Install** button instead
  of relying on the easy-to-miss address-bar icon. Tapping it calls the
  browser's own install prompt.
* The banner is dismissible (×) and stays hidden for 14 days per-device
  after dismissal (`localStorage`), and never shows at all once the app is
  already running in standalone/installed mode.
* The service worker only caches the HTML shell for offline opening — it
  deliberately never touches the video/control WebSocket traffic
  (`ws-scrcpy`: `?action=proxy-adb&...`; `tango-mirror`: `/api/*`), so
  there's no risk of it serving stale/cached stream data.
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
| `TANGO_PORT` | `8010` | Port the audio sidecar (`scrcpy-audio`, tango-mirror) listens on — see *Audio* |
| `TANGO_TOKEN` | — (required) | Gates the audio sidecar's device list/stream — required because that service runs with `network_mode: host` |
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
Dockerfile              Node 20 + adb + nmap + ws-scrcpy build + tango-mirror (audio sidecar)
entrypoint.sh           pair → connect (cache/pin/nmap-discover port) → 30s keepalive loop → ws-scrcpy on :8000
entrypoint-audio.sh     reads the port scrcpy-relay already discovered/cached → own adb session → tango-mirror on :8010
docker-compose.yml      scrcpy-relay (bridge, BIND_HOST/Traefik) + scrcpy-audio (network_mode: host, TANGO_TOKEN-gated)
.env.example            configuration template
docker/webclient/       build-time overlay on ws-scrcpy: PWA app shell
                        (manifest/service-worker/icons/install-banner),
                        mobile/touch CSS, the Reconnect widget
                        (pair/connect/QR UI), and the /relay-api server
                        routes backing it — all applied before
                        `npm run dist` in the Dockerfile
docker/tango-pwa/       same PWA app-shell treatment, applied to
                        tango-mirror's bundled page instead
```
