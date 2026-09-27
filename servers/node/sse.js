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

const streams = new Map();

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
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

const dir = dirname(fileURLToPath(import.meta.url));
const cert = readFileSync(join(dir, '../cert.pem'), 'utf8');
const key = readFileSync(join(dir, '../key.pem'), 'utf8');

const server = createServer({ cert, key }, async (req, res) => {
    const url = new URL(req.url, 'http://placeholder');

    if (req.method === 'GET' && url.pathname === '/events') {
        const clientId = url.searchParams.get('clientId');
        if (!clientId) {
            res.writeHead(400).end('clientId required');
            return;
        }

        res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache, no-transform',
            Connection: 'keep-alive',
            'X-Accel-Buffering': 'no',
        });
        res.flushHeaders?.();

        streams.set(clientId, res);
        console.log(`stream open ${clientId} (active=${streams.size})`);

        req.on('close', () => {
            if (streams.get(clientId) === res) streams.delete(clientId);
            console.log(`stream close ${clientId} (active=${streams.size})`);
        });
        return;
    }

    if (req.method === 'POST' && url.pathname === '/send') {
        const clientId = url.searchParams.get('clientId');
        if (!clientId) {
            res.writeHead(400).end('clientId required');
            return;
        }
        const stream = streams.get(clientId);
        if (!stream) {
            res.writeHead(409).end('no open stream for clientId');
            return;
        }

        let body;
        try {
            body = await readBody(req);
        } catch (err) {
            res.writeHead(413).end(err.message);
            return;
        }

        stream.write(`data: ${body}\n\n`);
        res.writeHead(204).end();
        return;
    }

    res.writeHead(404).end();
});

server.on('listening', () => console.log(`sse echo listening on ${host}:${port}`));
server.on('error', (err) => {
    console.error('server error:', err);
    process.exit(1);
});
server.listen(port, host);

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        for (const s of streams.values()) s.end();
        server.close(() => process.exit(0));
    });
}
