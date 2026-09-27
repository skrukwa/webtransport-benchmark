import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createServer } from '@webtransport-bun/webtransport';

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

async function handleSession(session: any): Promise<void> {
    console.log('conn open');
    try {
        for await (const d of session.incomingDatagrams()) {
            await session.sendDatagram(d);
        }
    } catch {}
    console.log('conn close');
}

createServer({
    host,
    port,
    tls: { certPem, keyPem },
    onSession: (session: any) => { handleSession(session); },
    rateLimits: {
        handshakesPerSec: 200, handshakesBurst: 200,
        datagramsPerSec: 100_000_000, datagramsBurst: 100_000_000,
    },
});

console.log(`webtransport datagram echo listening on ${host}:${port}`);

for (const sig of ['SIGINT', 'SIGTERM'] as const) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        process.exit(0);
    });
}
