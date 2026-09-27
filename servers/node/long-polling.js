import { createServer } from 'node:https';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

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

const pending = new Map();

const buffered = new Map();

let parkedEchoes = 0;
let bufferedEchoes = 0;
let slotConflicts = 0;

let parkedWaitSum = 0, parkedWaitMax = 0;
let bufferedWaitSum = 0, bufferedWaitMax = 0;

function readBody(req, limitBytes = 64 * 1024) {
    return new Promise((resolve, reject) => {
        let size = 0;
        const chunks = [];
        req.on('data', (chunk) => {
            size += chunk.length;
            if (size > limitBytes) {
                reject(new Error('payload too large'));
                req.destroy();
                return;
            }
            chunks.push(chunk);
        });
        req.on('end', () => resolve(Buffer.concat(chunks)));
        req.on('error', reject);
    });
}

const dir = dirname(fileURLToPath(import.meta.url));
const cert = readFileSync(join(dir, '../cert.pem'), 'utf8');
const key = readFileSync(join(dir, '../key.pem'), 'utf8');

const server = createServer({ cert, key }, async (req, res) => {
    const url = new URL(req.url, 'http://placeholder');
    const clientId = url.searchParams.get('clientId');
    if (!clientId) {
        res.writeHead(400).end('clientId required');
        return;
    }

    if (req.method === 'GET') {
        const previous = pending.get(clientId);
        if (previous) {
            pending.delete(clientId);
            previous.res.writeHead(409).end();
        }

        const early = buffered.get(clientId);
        if (early !== undefined) {
            buffered.delete(clientId);
            bufferedEchoes++;
            const waited = performance.now() - early.at;
            bufferedWaitSum += waited;
            if (waited > bufferedWaitMax) bufferedWaitMax = waited;
            res.writeHead(200, {
                'Content-Type': 'application/json',
                'Content-Length': early.body.length,
            });
            res.end(early.body);
            return;
        }

        pending.set(clientId, { res, at: performance.now() });
        req.on('close', () => {
            if (pending.get(clientId)?.res === res) {
                pending.delete(clientId);
                buffered.delete(clientId);
            }
        });
        return;
    }

    if (req.method === 'POST') {
        let body;
        try {
            body = await readBody(req);
        } catch (err) {
            res.writeHead(413).end(err.message);
            return;
        }

        const parked = pending.get(clientId);
        if (!parked) {
            if (buffered.has(clientId)) {
                slotConflicts++;
                res.writeHead(409).end('payload already buffered for clientId');
                return;
            }
            buffered.set(clientId, { body, at: performance.now() });
            res.writeHead(204).end();
            return;
        }
        pending.delete(clientId);
        parkedEchoes++;
        const parkedFor = performance.now() - parked.at;
        parkedWaitSum += parkedFor;
        if (parkedFor > parkedWaitMax) parkedWaitMax = parkedFor;

        res.writeHead(204).end();

        const hangingRes = parked.res;
        hangingRes.writeHead(200, {
            'Content-Type': 'application/json',
            'Content-Length': body.length,
        });
        hangingRes.end(body);
        return;
    }

    res.writeHead(405).end();
});

server.on('listening', () => console.log(`long-polling echo listening on ${host}:${port}`));
server.on('error', (err) => {
    console.error('server error:', err);
    process.exit(1);
});
server.listen(port, host);

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        const total = parkedEchoes + bufferedEchoes;
        const pct = total > 0 ? (parkedEchoes / total * 100).toFixed(3) : 'n/a';
        console.log(
            `poll-paths parked=${parkedEchoes} buffered=${bufferedEchoes} `
            + `parked_pct=${pct} slot_conflicts=${slotConflicts} `
            + `parked_wait_mean_ms=${(parkedEchoes ? parkedWaitSum / parkedEchoes : 0).toFixed(4)} `
            + `parked_wait_max_ms=${parkedWaitMax.toFixed(4)} `
            + `buffered_wait_mean_ms=${(bufferedEchoes ? bufferedWaitSum / bufferedEchoes : 0).toFixed(4)} `
            + `buffered_wait_max_ms=${bufferedWaitMax.toFixed(4)}`,
        );
        for (const p of pending.values()) {
            try { p.res.end(); } catch {}
        }
        server.close(() => process.exit(0));
    });
}
