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

const certPem = readFileSync(join(import.meta.dir, '../cert.pem'), 'utf-8');
const keyPem  = readFileSync(join(import.meta.dir, '../key.pem'),  'utf-8');

Bun.serve({
    hostname: host,
    port,
    tls: { cert: certPem, key: keyPem },
    async fetch(req) {
        if (req.method !== 'POST' || new URL(req.url).pathname !== '/echo') {
            return new Response(null, { status: 404 });
        }

        const body = new Uint8Array(await req.arrayBuffer());

        return new Response(body, {
            status: 200,
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': String(body.byteLength),
            },
        });
    },
});

console.log(`polling echo listening on ${host}:${port}`);
