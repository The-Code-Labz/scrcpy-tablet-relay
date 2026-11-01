/*
 * scrcpy-tablet-relay — in-process reconnect API.
 *
 * Copied into src/server/RelayApi.ts and mounted at /relay-api by a small
 * patch to HttpServer.ts (see Dockerfile) — rides the existing ws-scrcpy
 * HTTP port, so it works through BIND_HOST and the Traefik labels with zero
 * extra network exposure.
 *
 * Why this exists: Android 11+ Wireless Debugging's connect *port* rotates
 * on every Wi-Fi reconnect (entrypoint.sh already self-heals that via a
 * bounded nmap scan), but the adb *trust* (TLS key pairing) is a separate
 * thing that can be revoked independently (toggling Wireless debugging
 * off/on, "Revoke wireless debugging authorizations", etc.) — when that
 * happens, every connect attempt reports "offline" forever and no amount
 * of port rediscovery fixes it. Until now, fixing that required someone
 * with shell access to exec into the container and run `adb pair`
 * manually. This gives that same `adb pair`/`adb connect` capability to
 * the web UI, with two flows:
 *   - Port + code: mirrors Settings > Wireless debugging > "Pair device
 *     with pairing code" — you type what the tablet shows.
 *   - QR code: mirrors Settings > Wireless debugging > "Pair device with
 *     QR code" — we render the QR, the tablet scans it and broadcasts an
 *     mDNS pairing service, we watch for it and pair automatically.
 *     CAVEAT: this depends on mDNS multicast actually reaching this
 *     container from the tablet (same LAN/host-network segment). Over a
 *     pure Tailscale hop it generally will NOT work — Tailscale doesn't
 *     relay multicast — in which case the port+code tab is the reliable
 *     path. The job reports that plainly on timeout rather than hanging.
 *
 * Either way, once `adb pair` succeeds we attempt one immediate opportunistic
 * `adb connect`, but we don't depend on it: entrypoint.sh's keepalive loop
 * polls every KEEPALIVE_INTERVAL and already re-runs full port discovery on
 * its own, so trust alone is enough to self-heal within ~60s even if our
 * opportunistic connect attempt misses.
 */
import { Router, Request, Response } from 'express';
import { execFile } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as crypto from 'crypto';
// eslint-disable-next-line @typescript-eslint/no-var-requires
const QRCode: { toDataURL: (text: string, opts?: Record<string, unknown>) => Promise<string> } = require('qrcode');

const ADB = process.env.ADB_BIN || 'adb';
const DEFAULT_HOST = process.env.TABLET_HOST || '';
const DEFAULT_PORT = process.env.TABLET_PORT || '';
const PORT_CACHE_FILE = process.env.PORT_CACHE_FILE || path.join(os.homedir(), '.android', 'relay_last_port');

type DeviceState = { host: string; port: string; state: string } | null;

function runAdb(args: string[], timeoutMs = 15000): Promise<{ ok: boolean; stdout: string; stderr: string }> {
    return new Promise((resolve) => {
        execFile(ADB, args, { timeout: timeoutMs }, (err, stdout, stderr) => {
            resolve({ ok: !err, stdout: stdout ? stdout.toString() : '', stderr: stderr ? stderr.toString() : '' });
        });
    });
}

function wait(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function randomToken(len: number): string {
    return crypto
        .randomBytes(len + 4)
        .toString('base64')
        .replace(/[^a-zA-Z0-9]/g, '')
        .slice(0, len);
}

function readCachedPort(): string {
    try {
        return fs.readFileSync(PORT_CACHE_FILE, 'utf8').trim();
    } catch {
        return '';
    }
}

function cachePort(port: string): void {
    try {
        fs.mkdirSync(path.dirname(PORT_CACHE_FILE), { recursive: true });
        fs.writeFileSync(PORT_CACHE_FILE, port);
    } catch {
        /* best effort — the keepalive loop will rediscover it anyway */
    }
}

async function deviceState(host: string): Promise<DeviceState> {
    const { stdout } = await runAdb(['devices', '-l']);
    for (const raw of stdout.split('\n')) {
        const line = raw.trim();
        if (!line.startsWith(`${host}:`)) {
            continue;
        }
        const parts = line.split(/\s+/);
        const [addr, state] = parts;
        const port = addr.slice(host.length + 1);
        return { host, port, state };
    }
    return null;
}

// Pulls the trailing "ip:port" token out of an `adb mdns services` line,
// same heuristic used by the open-source adb-qr CLI this flow is modeled
// on: the address is whichever space-separated column has a colon and
// isn't the `_adb-tls-*._tcp` service-type column.
function extractAddr(line: string): string | null {
    const parts = line.trim().split(/\s+/);
    const addr = parts.find((p) => p.includes(':') && !p.includes('_adb'));
    return addr || null;
}

export function createRelayApiRouter(): Router {
    const router = Router();

    router.get('/status', async (req: Request, res: Response) => {
        const host = (req.query.host as string) || DEFAULT_HOST;
        if (!host) {
            res.status(400).json({ ok: false, error: 'no TABLET_HOST configured' });
            return;
        }
        res.json({ ok: true, host, device: await deviceState(host) });
    });

    router.post('/connect', async (req: Request, res: Response) => {
        const host = (req.body?.host as string) || DEFAULT_HOST;
        const port = String(req.body?.port || '').trim();
        if (!host || !port) {
            res.status(400).json({ ok: false, error: 'host and port are required' });
            return;
        }
        const result = await runAdb(['connect', `${host}:${port}`]);
        await wait(1200);
        const device = await deviceState(host);
        const success = !!device && device.port === port && device.state === 'device';
        if (success) {
            cachePort(port);
        }
        res.json({ ok: success, output: (result.stdout || result.stderr).trim(), device });
    });

    router.post('/pair', async (req: Request, res: Response) => {
        const host = (req.body?.host as string) || DEFAULT_HOST;
        const pairPort = String(req.body?.pairPort || '').trim();
        const code = String(req.body?.code || '').trim();
        const connectPort = String(req.body?.connectPort || '').trim();
        if (!host || !pairPort || !code) {
            res.status(400).json({ ok: false, error: 'host, pairPort and code are required' });
            return;
        }
        const pairResult = await runAdb(['pair', `${host}:${pairPort}`, code]);
        const paired = pairResult.ok && /successfully paired/i.test(pairResult.stdout);
        if (!paired) {
            res.json({ ok: false, stage: 'pair', output: (pairResult.stdout || pairResult.stderr).trim() });
            return;
        }
        const candidate = connectPort || readCachedPort() || DEFAULT_PORT;
        let device: DeviceState = null;
        if (candidate) {
            await runAdb(['connect', `${host}:${candidate}`]);
            await wait(1200);
            device = await deviceState(host);
            if (device?.state === 'device') {
                cachePort(device.port);
            }
        }
        const connected = device?.state === 'device';
        res.json({
            ok: true,
            stage: connected ? 'connected' : 'paired',
            output: pairResult.stdout.trim(),
            device,
            message: connected
                ? `Paired and reconnected on ${host}:${device?.port}.`
                : 'Paired. Waiting for the keepalive loop to rediscover the connect port (up to ~60s) — or enter it manually with Connect once the tablet shows it.',
        });
    });

    // ---- QR pairing ----
    const qrJobs = new Map<string, QrJob>();
    setInterval(() => {
        const cutoff = Date.now() - 10 * 60 * 1000;
        for (const [id, job] of qrJobs) {
            if (job.startedAt < cutoff) {
                qrJobs.delete(id);
            }
        }
    }, 60 * 1000);

    router.post('/qr/start', async (req: Request, res: Response) => {
        const host = (req.body?.host as string) || DEFAULT_HOST;
        if (!host) {
            res.status(400).json({ ok: false, error: 'no TABLET_HOST configured' });
            return;
        }
        const name = `ADB_WIFI_RELAY_${randomToken(10)}`;
        const password = randomToken(16);
        const qrText = `WIFI:T:ADB;S:${name};P:${password};;`;
        const qrDataUrl = await QRCode.toDataURL(qrText, { margin: 1, scale: 6 });
        const jobId = randomToken(12);
        const job: QrJob = {
            id: jobId,
            host,
            name,
            password,
            state: 'waiting-for-scan',
            message: 'Scan this QR on the tablet: Settings -> Developer options -> Wireless debugging -> Pair device with QR code.',
            startedAt: Date.now(),
            cancelled: false,
        };
        qrJobs.set(jobId, job);
        runQrJob(job).catch((e) => {
            job.state = 'error';
            job.message = e instanceof Error ? e.message : String(e);
        });
        res.json({ ok: true, jobId, qrDataUrl, expiresInSec: 90 });
    });

    router.get('/qr/status/:jobId', (req: Request, res: Response) => {
        const job = qrJobs.get(req.params.jobId);
        if (!job) {
            res.status(404).json({ ok: false, error: 'unknown or expired job' });
            return;
        }
        res.json({ ok: true, state: job.state, message: job.message, device: job.device });
    });

    router.post('/qr/cancel/:jobId', (req: Request, res: Response) => {
        const job = qrJobs.get(req.params.jobId);
        if (job) {
            job.cancelled = true;
        }
        res.json({ ok: true });
    });

    return router;
}

interface QrJob {
    id: string;
    host: string;
    name: string;
    password: string;
    state: 'waiting-for-scan' | 'pairing' | 'connecting' | 'connected' | 'timeout' | 'error' | 'cancelled';
    message: string;
    device?: DeviceState;
    startedAt: number;
    cancelled: boolean;
}

async function runQrJob(job: QrJob): Promise<void> {
    const pairDeadline = Date.now() + 90000;
    let pairAddr = '';
    while (Date.now() < pairDeadline && !job.cancelled) {
        const { stdout } = await runAdb(['mdns', 'services']);
        const line = stdout.split('\n').find((l) => l.includes('_adb-tls-pairing._tcp') && l.includes(job.name));
        const addr = line ? extractAddr(line) : null;
        if (addr) {
            pairAddr = addr;
            break;
        }
        await wait(1000);
    }
    if (job.cancelled) {
        job.state = 'cancelled';
        job.message = 'Cancelled.';
        return;
    }
    if (!pairAddr) {
        job.state = 'timeout';
        job.message =
            'No pairing broadcast seen within 90s. Usually means mDNS multicast from the tablet never reached this container (common over a Tailscale-only link, since Tailscale does not relay multicast) — use the Port + Code tab instead.';
        return;
    }

    job.state = 'pairing';
    job.message = `Found ${pairAddr} — pairing...`;
    const pairResult = await runAdb(['pair', pairAddr, job.password]);
    if (!pairResult.ok || !/successfully paired/i.test(pairResult.stdout)) {
        job.state = 'error';
        job.message = `Pairing failed: ${(pairResult.stdout || pairResult.stderr).trim()}`;
        return;
    }

    const ip = pairAddr.split(':')[0];
    job.state = 'connecting';
    job.message = 'Paired. Waiting for the connect port to be advertised...';
    const connectDeadline = Date.now() + 20000;
    let connectAddr = '';
    while (Date.now() < connectDeadline && !job.cancelled) {
        const { stdout } = await runAdb(['mdns', 'services']);
        const line = stdout.split('\n').find((l) => l.includes('_adb-tls-connect._tcp') && l.includes(ip));
        const addr = line ? extractAddr(line) : null;
        if (addr) {
            connectAddr = addr;
            break;
        }
        await wait(1000);
    }
    if (job.cancelled) {
        job.state = 'cancelled';
        job.message = 'Cancelled.';
        return;
    }
    if (!connectAddr) {
        job.state = 'connected';
        job.message = 'Paired, but the connect port was not advertised in time — the relay keepalive loop will auto-discover it (up to ~60s).';
        return;
    }

    await runAdb(['connect', connectAddr]);
    await wait(1200);
    const device = await deviceState(ip);
    if (device?.state === 'device') {
        cachePort(device.port);
    }
    job.device = device;
    job.state = 'connected';
    job.message =
        device?.state === 'device'
            ? `Connected on ${ip}:${device.port}.`
            : 'Paired and connect attempted — the keepalive loop will confirm/retry.';
}
