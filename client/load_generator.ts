declare const setImmediate: (cb: () => void) => void;

type Protocol = 'ws' | 'sse' | 'short-polling' | 'long-polling' | 'webtransport' | 'webtransport-datagram';

interface Args {
    target: string;
    protocol: Protocol;
    duration: number;
    clients: number;
    workers: number;
    resultsDir: string;
    profile: string;
    runtime: string;
    protocolVariant: string;
    packetLossPct: string;
    delayMs: string;
}

function parseArgs(argv: string[]): Args {
    const map = new Map<string, string>();
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (!a.startsWith('--')) continue;
        const key = a.slice(2);
        const val = argv[i + 1];
        if (val === undefined || val.startsWith('--')) {
            throw new Error(`flag --${key} requires a value`);
        }
        map.set(key, val);
        i++;
    }

    const get = (k: string): string => {
        const v = map.get(k);
        if (v === undefined) throw new Error(`missing required flag --${k}`);
        return v;
    };

    const protocol = get('protocol') as Protocol;
    if (
        protocol !== 'ws' &&
        protocol !== 'sse' &&
        protocol !== 'short-polling' &&
        protocol !== 'long-polling' &&
        protocol !== 'webtransport' &&
        protocol !== 'webtransport-datagram'
    ) {
        throw new Error(`--protocol must be one of: ws, sse, short-polling, long-polling, webtransport, webtransport-datagram`);
    }

    const duration = Number(get('duration'));
    if (!Number.isFinite(duration) || duration <= 0) {
        throw new Error(`--duration must be a positive number`);
    }

    const clients = Number(get('clients'));
    if (!Number.isInteger(clients) || clients <= 0) {
        throw new Error(`--clients must be a positive integer`);
    }

    const workers = map.has('workers') ? Number(map.get('workers')) : 1;
    if (!Number.isInteger(workers) || workers <= 0) {
        throw new Error(`--workers must be a positive integer`);
    }

    const resultsDir = map.get('results-dir') ?? Deno.env.get('RESULTS_DIR') ?? './results';

    const env = (k: string): string => Deno.env.get(k) ?? '';
    const profile = env('RUN_PROFILE') || 'standalone';
    const runtime = env('RUN_RUNTIME') || 'unknown';
    const protocolVariant = env('RUN_VARIANT') || protocol;
    const packetLossPct = env('RUN_LOSS_PCT');
    const delayMs = env('RUN_DELAY_MS');

    return {
        target: get('target'), protocol, duration, clients, workers, resultsDir,
        profile, runtime, protocolVariant, packetLossPct, delayMs,
    };
}

function makePayload(id: number, clientTimeMs: number): string {
    return `{"id":${id},"client_time":${clientTimeMs}}`;
}

const RTT_CAP_PER_CLIENT = 5_000_000;

class RttBuffer {
    readonly data: Float64Array;
    length = 0;
    overflows = 0;

    constructor(cap: number = RTT_CAP_PER_CLIENT) {
        this.data = new Float64Array(cap);
    }

    push(rttMs: number): void {
        if (this.length >= this.data.length) {
            this.overflows++;
            return;
        }
        this.data[this.length++] = rttMs;
    }
}

interface ClientStats {
    connectTimeMs: number;
    readyTimeMs: number;
    echoesOk: number;
    errors: number;
    dgramSent: number;
    dgramTimeouts: number;
    rtts: RttBuffer;
}

interface ProtocolClient {
    run(stopSignal: AbortSignal): Promise<ClientStats>;
}

interface RttView {
    readonly data: Float64Array;
    readonly length: number;
    readonly overflows: number;
}

interface AggStats {
    connectTimeMs: number;
    readyTimeMs: number;
    echoesOk: number;
    errors: number;
    dgramSent: number;
    dgramTimeouts: number;
    rtts: RttView;
}

interface WorkerRunMsg { protocol: Protocol; target: string; indices: number[]; durationSec: number; }
interface WorkerClientStat {
    connectTimeMs: number; readyTimeMs: number; echoesOk: number; errors: number;
    dgramSent: number; dgramTimeouts: number; overflows: number;
    rttsBuffer: ArrayBuffer;
    rttsLen: number;
}
interface WorkerDoneMsg { stats: WorkerClientStat[]; }

class WebSocketClient implements ProtocolClient {
    constructor(private readonly target: string, private readonly clientId: number) {}

    run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = {
            connectTimeMs: -1, readyTimeMs: -1, echoesOk: 0, errors: 0,
            dgramSent: 0, dgramTimeouts: 0, rtts: new RttBuffer(),
        };

        return new Promise((resolve) => {
            const connectStart = performance.now();
            const ws = new WebSocket(`wss://${this.target}/`);
            let sendStart = 0;
            let nextId = 0;
            let settled = false;

            const finish = () => {
                if (settled) return;
                settled = true;
                stopSignal.removeEventListener('abort', onAbort);
                try { ws.close(); } catch {}
                resolve(stats);
            };

            const onAbort = () => finish();
            stopSignal.addEventListener('abort', onAbort);

            const sendNext = () => {
                if (stopSignal.aborted) { finish(); return; }
                sendStart = performance.now();
                try {
                    ws.send(makePayload(nextId++, Date.now()));
                } catch {
                    stats.errors++;
                    finish();
                }
            };

            ws.onopen = () => {
                stats.connectTimeMs = performance.now() - connectStart;
                sendNext();
            };

            ws.onmessage = () => {
                stats.rtts.push(performance.now() - sendStart);
                stats.echoesOk++;
                sendNext();
            };

            ws.onerror = () => {
                stats.errors++;
            };

            ws.onclose = () => finish();
        });
    }
}

class SseClient implements ProtocolClient {
    private readonly httpClient: Deno.HttpClient = Deno.createHttpClient({ http2: false });

    constructor(private readonly target: string, private readonly clientId: number) {}

    run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = {
            connectTimeMs: -1, readyTimeMs: -1, echoesOk: 0, errors: 0,
            dgramSent: 0, dgramTimeouts: 0, rtts: new RttBuffer(),
        };
        const idParam = `bench-${this.clientId}-${Date.now()}`;
        const base = `https://${this.target}`;
        const eventsUrl = `${base}/events?clientId=${idParam}`;
        const sendUrl = `${base}/send?clientId=${idParam}`;

        return new Promise((resolve) => {
            const connectStart = performance.now();
            const es = new EventSource(eventsUrl);
            let pendingResolve: (() => void) | null = null;
            let nextId = 0;
            let settled = false;

            const finish = () => {
                if (settled) return;
                settled = true;
                stopSignal.removeEventListener('abort', onAbort);
                try { es.close(); } catch {}
                try { this.httpClient.close(); } catch {}
                resolve(stats);
            };

            const onAbort = () => finish();
            stopSignal.addEventListener('abort', onAbort);

            es.onopen = async () => {
                stats.connectTimeMs = performance.now() - connectStart;
                while (!stopSignal.aborted) {
                    const sendStart = performance.now();
                    const payload = makePayload(nextId++, Date.now());

                    const echoArrived = new Promise<void>((res) => { pendingResolve = res; });

                    try {
                        const r = await fetch(sendUrl, {
                            method: 'POST',
                            body: payload,
                            headers: { 'Content-Type': 'application/json' },
                            client: this.httpClient,
                        });
                        if (!r.ok) {
                            stats.errors++;
                            pendingResolve = null;
                            await new Promise((res) => setTimeout(res, 1));
                            continue;
                        }
                        await r.body?.cancel();
                    } catch {
                        stats.errors++;
                        pendingResolve = null;
                        continue;
                    }

                    await echoArrived;
                    if (stopSignal.aborted) break;
                    stats.rtts.push(performance.now() - sendStart);
                    stats.echoesOk++;
                }
                finish();
            };

            es.onmessage = () => {
                const r = pendingResolve;
                pendingResolve = null;
                r?.();
            };

            es.onerror = () => {
                stats.errors++;
                if (stats.connectTimeMs < 0 || stats.echoesOk > 0) finish();
            };
        });
    }
}

class ShortPollingClient implements ProtocolClient {
    private readonly httpClient: Deno.HttpClient = Deno.createHttpClient({ http2: false });

    constructor(private readonly target: string, private readonly clientId: number) {}

    async run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = {
            connectTimeMs: -1, readyTimeMs: -1, echoesOk: 0, errors: 0,
            dgramSent: 0, dgramTimeouts: 0, rtts: new RttBuffer(),
        };
        const url = `https://${this.target}/echo`;
        let nextId = 0;
        const connectStart = performance.now();
        let firstRequest = true;

        while (!stopSignal.aborted) {
            const sendStart = performance.now();
            try {
                const r = await fetch(url, {
                    method: 'POST',
                    body: makePayload(nextId++, Date.now()),
                    headers: { 'Content-Type': 'application/json' },
                    client: this.httpClient,
                });
                if (!r.ok) {
                    stats.errors++;
                    await r.body?.cancel();
                    continue;
                }
                await r.text();
                const now = performance.now();
                if (firstRequest) {
                    stats.connectTimeMs = now - connectStart;
                    firstRequest = false;
                }
                stats.rtts.push(now - sendStart);
                stats.echoesOk++;
            } catch {
                stats.errors++;
            }
        }
        this.httpClient.close();
        return stats;
    }
}

class LongPollingClient implements ProtocolClient {
    private readonly httpClient: Deno.HttpClient = Deno.createHttpClient({ poolSize: 2, http2: false });

    constructor(private readonly target: string, private readonly clientId: number) {}

    async run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = {
            connectTimeMs: -1, readyTimeMs: -1, echoesOk: 0, errors: 0,
            dgramSent: 0, dgramTimeouts: 0, rtts: new RttBuffer(),
        };
        const idParam = `bench-${this.clientId}-${Date.now()}`;
        const base = `https://${this.target}`;
        const getUrl = `${base}/?clientId=${idParam}`;
        const postUrl = `${base}/?clientId=${idParam}`;
        let nextId = 0;
        const connectStart = performance.now();
        let firstEcho = true;

        const armGet = () => {
            const abort = new AbortController();
            const promise = fetch(getUrl, {
                method: 'GET',
                client: this.httpClient,
                signal: AbortSignal.any([stopSignal, abort.signal]),
            });
            promise.catch(() => {});
            return { promise, abort };
        };

        let armed = armGet();
        await new Promise<void>((res) => setImmediate(() => res()));

        while (!stopSignal.aborted) {
            const sendStart = performance.now();
            let postOk = false;
            try {
                const postRes = await fetch(postUrl, {
                    method: 'POST',
                    body: makePayload(nextId++, Date.now()),
                    headers: { 'Content-Type': 'application/json' },
                    client: this.httpClient,
                    signal: stopSignal,
                });
                if (!postRes.ok) {
                    stats.errors++;
                    await postRes.body?.cancel();
                } else {
                    await postRes.body?.cancel();
                    postOk = true;
                }
            } catch (e) {
                if ((e as Error).name !== 'AbortError') stats.errors++;
            }

            if (!postOk) armed.abort.abort();

            try {
                const getRes = await armed.promise;
                if (!getRes.ok) {
                    if (postOk) stats.errors++;
                    await getRes.body?.cancel();
                } else {
                    await getRes.text();
                    if (postOk) {
                        const now = performance.now();
                        if (firstEcho) {
                            stats.connectTimeMs = now - connectStart;
                            firstEcho = false;
                        }
                        stats.rtts.push(now - sendStart);
                        stats.echoesOk++;
                    }
                }
            } catch (e) {
                if ((e as Error).name !== 'AbortError') stats.errors++;
            }

            if (!stopSignal.aborted) armed = armGet();
        }
        armed.abort.abort();
        this.httpClient.close();
        return stats;
    }
}

function decodePemToDer(pem: string): Uint8Array {
    const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
    return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

class WebTransportClient implements ProtocolClient {
    constructor(
        private readonly target: string,
        private readonly clientId: number,
        private readonly certHash: ArrayBuffer,
    ) {}

    async run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = {
            connectTimeMs: -1, readyTimeMs: -1, echoesOk: 0, errors: 0,
            dgramSent: 0, dgramTimeouts: 0, rtts: new RttBuffer(),
        };
        const encoder = new TextEncoder();

        const connectStart = performance.now();
        let wt: WebTransport;
        try {
            wt = new WebTransport(`https://${this.target}`, {
                serverCertificateHashes: [{ algorithm: 'sha-256', value: this.certHash }],
                allowPooling: false,
            });
            wt.closed.catch(() => {});
            await wt.ready;
        } catch (err) {
            stats.errors++;
            console.error(`[wt client ${this.clientId}] connect failed:`, err);
            return stats;
        }
        stats.readyTimeMs = performance.now() - connectStart;

        let stream: { readable: ReadableStream<Uint8Array>; writable: WritableStream<Uint8Array> };
        try {
            stream = await wt.createBidirectionalStream();
        } catch {
            stats.errors++;
            wt.close();
            return stats;
        }
        stats.connectTimeMs = performance.now() - connectStart;

        const writer = stream.writable.getWriter();
        const reader = stream.readable.getReader();

        const onAbort = () => {
            try { wt.close(); } catch {}
        };
        stopSignal.addEventListener('abort', onAbort);

        try {
            while (!stopSignal.aborted) {
                const sendStart = performance.now();
                try {
                    await writer.write(encoder.encode(makePayload(this.clientId, Date.now())));
                    const { value, done } = await reader.read();
                    if (done) break;
                    if (value) {
                        stats.rtts.push(performance.now() - sendStart);
                        stats.echoesOk++;
                    }
                } catch {
                    if (!stopSignal.aborted) stats.errors++;
                    break;
                }
            }
        } finally {
            stopSignal.removeEventListener('abort', onAbort);
            try { await writer.close(); } catch {}
            reader.releaseLock();
            try { wt.close(); } catch {}
        }

        return stats;
    }
}

const _oneWayDelayMs = Number(Deno.env.get('RUN_DELAY_MS'));
const DATAGRAM_RECV_TIMEOUT_MS = Math.max(
    60,
    3 * (Number.isFinite(_oneWayDelayMs) ? _oneWayDelayMs : 50),
);

class WebTransportDatagramClient implements ProtocolClient {
    constructor(
        private readonly target: string,
        private readonly clientId: number,
        private readonly certHash: ArrayBuffer,
    ) {}

    async run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = {
            connectTimeMs: -1, readyTimeMs: -1, echoesOk: 0, errors: 0,
            dgramSent: 0, dgramTimeouts: 0, rtts: new RttBuffer(),
        };
        const encoder = new TextEncoder();

        const connectStart = performance.now();
        let wt: WebTransport;
        try {
            wt = new WebTransport(`https://${this.target}`, {
                serverCertificateHashes: [{ algorithm: 'sha-256', value: this.certHash }],
                allowPooling: false,
            });
            wt.closed.catch(() => {});
            await wt.ready;
        } catch (err) {
            stats.errors++;
            console.error(`[wt-datagram client ${this.clientId}] connect failed:`, err);
            return stats;
        }
        stats.connectTimeMs = performance.now() - connectStart;
        stats.readyTimeMs = stats.connectTimeMs;

        const writer = wt.datagrams.writable.getWriter();
        const reader = wt.datagrams.readable.getReader();

        const waiters = new Map<number, (arrivalMs: number) => void>();

        let abortResolve: () => void = () => {};
        const abortPromise = new Promise<'abort'>((resolve) => { abortResolve = () => resolve('abort'); });
        const onAbort = () => {
            try { wt.close(); } catch {}
            abortResolve();
        };
        stopSignal.addEventListener('abort', onAbort);

        const receiveLoop = (async () => {
            try {
                while (true) {
                    const { value, done } = await reader.read();
                    if (done) break;
                    if (!value || value.byteLength < 4) continue;
                    const seq = new DataView(value.buffer, value.byteOffset, value.byteLength).getUint32(0, false);
                    const resolve = waiters.get(seq);
                    if (resolve) {
                        waiters.delete(seq);
                        resolve(performance.now());
                    }
                }
            } catch {}
        })();

        try {
            let seq = 0;
            while (!stopSignal.aborted) {
                seq++;
                const body = encoder.encode(makePayload(this.clientId, Date.now()));
                const frame = new Uint8Array(4 + body.byteLength);
                new DataView(frame.buffer).setUint32(0, seq, false);
                frame.set(body, 4);

                const sendStart = performance.now();
                let timer: number | undefined;
                const arrival = new Promise<number>((resolve) => waiters.set(seq, resolve));
                const timeout = new Promise<'timeout'>((resolve) => {
                    timer = setTimeout(() => resolve('timeout'), DATAGRAM_RECV_TIMEOUT_MS);
                });

                try {
                    await writer.write(frame);
                } catch {
                    waiters.delete(seq);
                    clearTimeout(timer);
                    if (!stopSignal.aborted) stats.errors++;
                    break;
                }
                stats.dgramSent++;

                const result = await Promise.race([arrival, timeout, abortPromise]);
                clearTimeout(timer);
                if (result === 'abort') {
                    waiters.delete(seq);
                    break;
                }
                if (result === 'timeout') {
                    waiters.delete(seq);
                    stats.dgramTimeouts++;
                    stats.errors++;
                } else {
                    stats.rtts.push(result - sendStart);
                    stats.echoesOk++;
                }
            }
        } finally {
            stopSignal.removeEventListener('abort', onAbort);
            try { wt.close(); } catch {}
            try { writer.releaseLock(); } catch {}
            await receiveLoop.catch(() => {});
        }

        return stats;
    }
}

function makeClient(protocol: Protocol, target: string, clientId: number, certHash?: ArrayBuffer): ProtocolClient {
    switch (protocol) {
        case 'ws':             return new WebSocketClient(target, clientId);
        case 'sse':            return new SseClient(target, clientId);
        case 'short-polling':  return new ShortPollingClient(target, clientId);
        case 'long-polling':   return new LongPollingClient(target, clientId);
        case 'webtransport':   return new WebTransportClient(target, clientId, certHash!);
        case 'webtransport-datagram': return new WebTransportDatagramClient(target, clientId, certHash!);
    }
}

function percentile(sorted: Float64Array, p: number): number {
    if (sorted.length === 0) return NaN;
    const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1));
    return sorted[idx];
}

function mergeRtts(buffers: RttView[]): Float64Array {
    let total = 0;
    for (const b of buffers) total += b.length;
    const out = new Float64Array(total);
    let off = 0;
    for (const b of buffers) {
        out.set(b.data.subarray(0, b.length), off);
        off += b.length;
    }
    out.sort();
    return out;
}

const METRICS_HEADER = 'Timestamp,Profile,Runtime,ProtocolVariant,Protocol,Concurrency,DurationSec,PacketLossPct,DelayMs,Throughput,p50_ms,p95_ms,p99_ms,Errors,Overflows,MeanConnect_ms,DgramSent,DgramTimeouts,DgramTimeoutPct,DgramTimeoutMs,MeanReady_ms\n';

async function appendMetricsRow(metricsPath: string, row: string): Promise<void> {
    let needsHeader = false;
    try {
        await Deno.stat(metricsPath);
    } catch (e) {
        if (e instanceof Deno.errors.NotFound) needsHeader = true;
        else throw e;
    }
    const text = needsHeader ? METRICS_HEADER + row : row;
    await Deno.writeTextFile(metricsPath, text, { append: true });
}

async function writeRawRtts(rawPath: string, clientStats: AggStats[]): Promise<void> {
    const file = await Deno.open(rawPath, { write: true, create: true, truncate: true });
    const encoder = new TextEncoder();
    try {
        await file.write(encoder.encode('client_id,rtt_ms\n'));
        for (let c = 0; c < clientStats.length; c++) {
            const buf = clientStats[c].rtts;
            let chunk = '';
            for (let i = 0; i < buf.length; i++) {
                chunk += `${c},${buf.data[i]}\n`;
                if (chunk.length >= 65536) {
                    await file.write(encoder.encode(chunk));
                    chunk = '';
                }
            }
            if (chunk.length > 0) await file.write(encoder.encode(chunk));
        }
    } finally {
        file.close();
    }
}

async function writeConnectTimes(path: string, clientStats: AggStats[]): Promise<void> {
    let out = 'client_id,connect_ms,ready_ms\n';
    for (let c = 0; c < clientStats.length; c++) {
        const t = clientStats[c].connectTimeMs;
        const r = clientStats[c].readyTimeMs;
        out += `${c},${t >= 0 ? t.toFixed(4) : ''},${r >= 0 ? r.toFixed(4) : ''}\n`;
    }
    await Deno.writeTextFile(path, out);
}

function installRejectionGuard(): void {
    globalThis.addEventListener('unhandledrejection', (e: PromiseRejectionEvent) => {
        const r = e.reason;
        const name = r?.name ?? '';
        const msg = String(r?.message ?? r ?? '');
        if (
            name === 'WebTransportError' ||
            /timed out|reset by (peer|remote)|(connection|stream) (reset|closed|lost|aborted)|aborted by (peer|remote)/i.test(msg)
        ) {
            e.preventDefault();
        }
    });
}

async function computeCertHash(protocol: Protocol): Promise<ArrayBuffer | undefined> {
    if (protocol !== 'webtransport' && protocol !== 'webtransport-datagram') return undefined;
    const certPem = await Deno.readTextFile(new URL('../servers/cert.pem', import.meta.url));
    return await crypto.subtle.digest('SHA-256', decodePemToDer(certPem).buffer as ArrayBuffer);
}

async function runClients(
    protocol: Protocol, target: string, indices: number[],
    durationSec: number, certHash: ArrayBuffer | undefined,
): Promise<ClientStats[]> {
    const stop = new AbortController();
    const timer = setTimeout(() => { try { stop.abort(); } catch {} }, durationSec * 1000);
    const stats = await Promise.all(
        indices.map((i) => makeClient(protocol, target, i, certHash).run(stop.signal)),
    );
    clearTimeout(timer);
    return stats;
}

function runWithWorkers(args: Args, nWorkers: number): Promise<AggStats[]> {
    const chunks: number[][] = Array.from({ length: nWorkers }, () => []);
    for (let i = 0; i < args.clients; i++) chunks[i % nWorkers].push(i);

    const results = new Array<AggStats>(args.clients);
    const jobs = chunks.map((indices, w) => new Promise<void>((resolve, reject) => {
        const worker = new Worker(import.meta.url, { type: 'module', name: `lg-worker-${w}` });
        worker.onmessage = (e: MessageEvent<WorkerDoneMsg>) => {
            const per = e.data.stats;
            for (let k = 0; k < indices.length; k++) {
                const c = per[k];
                results[indices[k]] = {
                    connectTimeMs: c.connectTimeMs,
                    readyTimeMs: c.readyTimeMs,
                    echoesOk: c.echoesOk,
                    errors: c.errors,
                    dgramSent: c.dgramSent,
                    dgramTimeouts: c.dgramTimeouts,
                    rtts: { data: new Float64Array(c.rttsBuffer), length: c.rttsLen, overflows: c.overflows },
                };
            }
            worker.terminate();
            resolve();
        };
        worker.onerror = (e: ErrorEvent) => {
            worker.terminate();
            reject(new Error(`worker ${w} failed: ${e.message}`));
        };
        const msg: WorkerRunMsg = {
            protocol: args.protocol, target: args.target, indices, durationSec: args.duration,
        };
        worker.postMessage(msg);
    }));

    return Promise.all(jobs).then(() => results);
}

function setupWorker(): void {
    installRejectionGuard();
    const scope = self as unknown as {
        onmessage: ((e: MessageEvent<WorkerRunMsg>) => void) | null;
        postMessage: (msg: WorkerDoneMsg, transfer: Transferable[]) => void;
        close: () => void;
    };
    scope.onmessage = async (e: MessageEvent<WorkerRunMsg>) => {
        const { protocol, target, indices, durationSec } = e.data;
        const certHash = await computeCertHash(protocol);
        const stats = await runClients(protocol, target, indices, durationSec, certHash);
        const out: WorkerClientStat[] = stats.map((s) => {
            const used = s.rtts.data.slice(0, s.rtts.length);
            return {
                connectTimeMs: s.connectTimeMs, readyTimeMs: s.readyTimeMs,
                echoesOk: s.echoesOk, errors: s.errors,
                dgramSent: s.dgramSent, dgramTimeouts: s.dgramTimeouts,
                overflows: s.rtts.overflows, rttsBuffer: used.buffer as ArrayBuffer, rttsLen: used.length,
            };
        });
        scope.postMessage({ stats: out }, out.map((o) => o.rttsBuffer));
        scope.close();
    };
}

async function main(): Promise<void> {
    const args = parseArgs(Deno.args);

    installRejectionGuard();

    await Deno.mkdir(args.resultsDir, { recursive: true });

    console.log(`[load_generator] protocol=${args.protocol} target=${args.target} clients=${args.clients} duration=${args.duration}s`);

    const certHash = await computeCertHash(args.protocol);

    const effectiveWorkers = Math.max(1, Math.min(args.workers, args.clients));
    console.log(`[load_generator] workers=${effectiveWorkers} (requested ${args.workers})`);

    const runStart = performance.now();
    let allStats: AggStats[];
    if (effectiveWorkers === 1) {
        const indices = Array.from({ length: args.clients }, (_, i) => i);
        allStats = await runClients(args.protocol, args.target, indices, args.duration, certHash);
    } else {
        allStats = await runWithWorkers(args, effectiveWorkers);
    }
    const wallMs = performance.now() - runStart;

    const merged = mergeRtts(allStats.map((s) => s.rtts));
    const totalOk = allStats.reduce((a, s) => a + s.echoesOk, 0);
    const totalErr = allStats.reduce((a, s) => a + s.errors, 0);
    const totalOverflows = allStats.reduce((a, s) => a + s.rtts.overflows, 0);
    const connectTimes = allStats.map((s) => s.connectTimeMs).filter((t) => t >= 0);
    const readyTimes = allStats.map((s) => s.readyTimeMs).filter((t) => t >= 0);
    const totalDgramSent = allStats.reduce((a, s) => a + s.dgramSent, 0);
    const totalDgramTimeouts = allStats.reduce((a, s) => a + s.dgramTimeouts, 0);

    const throughput = totalOk / (wallMs / 1000);
    const p50 = percentile(merged, 0.50);
    const p95 = percentile(merged, 0.95);
    const p99 = percentile(merged, 0.99);
    const meanConnect = connectTimes.length > 0
        ? connectTimes.reduce((a, b) => a + b, 0) / connectTimes.length
        : NaN;
    const meanReady = readyTimes.length > 0
        ? readyTimes.reduce((a, b) => a + b, 0) / readyTimes.length
        : NaN;
    const dgramTimeoutPct = totalDgramSent > 0
        ? (100 * totalDgramTimeouts) / totalDgramSent
        : NaN;
    const isDatagram = args.protocol === 'webtransport-datagram';

    console.log('');
    console.log('=== summary ===');
    console.log(`protocol         : ${args.protocol}`);
    console.log(`concurrency      : ${args.clients}`);
    console.log(`wall time (s)    : ${(wallMs / 1000).toFixed(3)}`);
    console.log(`echoes ok        : ${totalOk}`);
    console.log(`errors           : ${totalErr}`);
    console.log(`rtt samples      : ${merged.length}`);
    console.log(`buffer overflows : ${totalOverflows}`);
    console.log(`throughput (msg/s): ${throughput.toFixed(2)}`);
    if (isDatagram) {
        console.log(`dgram sent       : ${totalDgramSent}`);
        console.log(`dgram timeouts   : ${totalDgramTimeouts} (${dgramTimeoutPct.toFixed(2)}%)`);
        console.log(`dgram timeout(ms): ${DATAGRAM_RECV_TIMEOUT_MS}`);
    }
    console.log(`mean connect (ms): ${meanConnect.toFixed(3)}`);
    if (!Number.isNaN(meanReady)) {
        console.log(`mean ready (ms)  : ${meanReady.toFixed(3)}`);
    }
    console.log(`p50 (ms)         : ${p50.toFixed(3)}`);
    console.log(`p95 (ms)         : ${p95.toFixed(3)}`);
    console.log(`p99 (ms)         : ${p99.toFixed(3)}`);

    const metricsPath = `${args.resultsDir.replace(/\/+$/, '')}/../metrics.csv`;
    const rawPath = `${args.resultsDir.replace(/\/+$/, '')}/rtts.csv`;
    const connectPath = `${args.resultsDir.replace(/\/+$/, '')}/connects.csv`;

    const row = [
        new Date().toISOString(),
        args.profile,
        args.runtime,
        args.protocolVariant,
        args.protocol,
        args.clients,
        args.duration,
        args.packetLossPct,
        args.delayMs,
        throughput.toFixed(3),
        p50.toFixed(4),
        p95.toFixed(4),
        p99.toFixed(4),
        totalErr,
        totalOverflows,
        Number.isNaN(meanConnect) ? '' : meanConnect.toFixed(4),
        isDatagram ? totalDgramSent : '',
        isDatagram ? totalDgramTimeouts : '',
        Number.isNaN(dgramTimeoutPct) ? '' : dgramTimeoutPct.toFixed(4),
        isDatagram ? DATAGRAM_RECV_TIMEOUT_MS : '',
        Number.isNaN(meanReady) ? '' : meanReady.toFixed(4),
    ].join(',') + '\n';

    await appendMetricsRow(metricsPath, row);
    await writeRawRtts(rawPath, allStats);
    await writeConnectTimes(connectPath, allStats);

    console.log('');
    console.log(`wrote summary row -> ${metricsPath}`);
    console.log(`wrote raw rtts    -> ${rawPath}`);
    console.log(`wrote connects    -> ${connectPath}`);
}

if (typeof (globalThis as Record<string, unknown>).WorkerGlobalScope !== 'undefined') {
    setupWorker();
} else {
    main().catch((err) => {
        console.error('[load_generator] fatal:', err);
        Deno.exit(1);
    });
}
