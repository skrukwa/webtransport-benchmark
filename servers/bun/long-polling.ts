import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const host = process.env.SERVER_IP;
const port = Number(process.env.SERVER_PORT);

if (!host) {
    console.error('SERVER_IP env var is required (set by harness_run_test.sh).');
    process.exit(1);
}
if (!Number.isInteger(port) || port <= 0) {
    console.error('SERVER_PORT env var must be a positive integer.');
    process.exit(1);
}

interface Pending {
    resolve: (body: Uint8Array | null) => void;
    at: number;
}

const pending = new Map<string, Pending>();

const buffered = new Map<string, { body: Uint8Array; at: number }>();

let parkedEchoes = 0;
let bufferedEchoes = 0;
let slotConflicts = 0;

let parkedWaitSum = 0, parkedWaitMax = 0;
let bufferedWaitSum = 0, bufferedWaitMax = 0;

const certPem = readFileSync(join(import.meta.dir, '../cert.pem'), 'utf-8');
const keyPem  = readFileSync(join(import.meta.dir, '../key.pem'),  'utf-8');

Bun.serve({
    hostname: host,
    port,
    tls: { cert: certPem, key: keyPem },
    async fetch(req) {
        const url = new URL(req.url);
        const clientId = url.searchParams.get('clientId');
        if (!clientId) return new Response('clientId required', { status: 400 });

        if (req.method === 'GET') {
            const previous = pending.get(clientId);
            if (previous) {
                pending.delete(clientId);
                previous.resolve(null);
            }

            const early = buffered.get(clientId);
            if (early !== undefined) {
                buffered.delete(clientId);
                bufferedEchoes++;
                const waited = performance.now() - early.at;
                bufferedWaitSum += waited;
                if (waited > bufferedWaitMax) bufferedWaitMax = waited;
                return new Response(early.body, {
                    status: 200,
                    headers: {
                        'Content-Type': 'application/json',
                        'Content-Length': String(early.body.byteLength),
                    },
                });
            }

            let resolve!: (body: Uint8Array | null) => void;
            const bodyPromise = new Promise<Uint8Array | null>((res) => { resolve = res; });
            pending.set(clientId, { resolve, at: performance.now() });

            req.signal.addEventListener('abort', () => {
                const cur = pending.get(clientId);
                if (cur && cur.resolve === resolve) {
                    pending.delete(clientId);
                    buffered.delete(clientId);
                    resolve(null);
                }
            });

            const body = await bodyPromise;
            if (body === null) {
                return new Response('hanging GET superseded or cancelled', { status: 409 });
            }
            return new Response(body, {
                status: 200,
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': String(body.byteLength),
                },
            });
        }

        if (req.method === 'POST') {
            const body = new Uint8Array(await req.arrayBuffer());
            const waiter = pending.get(clientId);
            if (waiter) {
                pending.delete(clientId);
                parkedEchoes++;
                const parkedFor = performance.now() - waiter.at;
                parkedWaitSum += parkedFor;
                if (parkedFor > parkedWaitMax) parkedWaitMax = parkedFor;
                waiter.resolve(body);
                return new Response(null, { status: 204 });
            }
            if (buffered.has(clientId)) {
                slotConflicts++;
                return new Response('payload already buffered for clientId', { status: 409 });
            }
            buffered.set(clientId, { body, at: performance.now() });
            return new Response(null, { status: 204 });
        }

        return new Response(null, { status: 405 });
    },
});

console.log(`long-polling echo listening on ${host}:${port}`);

function reportPollPaths(): void {
    const total = parkedEchoes + bufferedEchoes;
    const pct = total > 0 ? (parkedEchoes / total * 100).toFixed(3) : 'n/a';
    console.log(
        `poll-paths parked=${parkedEchoes} buffered=${bufferedEchoes} ` +
        `parked_pct=${pct} slot_conflicts=${slotConflicts} ` +
        `parked_wait_mean_ms=${(parkedEchoes ? parkedWaitSum / parkedEchoes : 0).toFixed(4)} ` +
        `parked_wait_max_ms=${parkedWaitMax.toFixed(4)} ` +
        `buffered_wait_mean_ms=${(bufferedEchoes ? bufferedWaitSum / bufferedEchoes : 0).toFixed(4)} ` +
        `buffered_wait_max_ms=${bufferedWaitMax.toFixed(4)}`,
    );
}

for (const sig of ['SIGINT', 'SIGTERM'] as const) {
    process.on(sig, () => {
        reportPollPaths();
        process.exit(0);
    });
}
