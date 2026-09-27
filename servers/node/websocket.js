import { createServer } from 'node:https';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

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

const dir = dirname(fileURLToPath(import.meta.url));
const cert = readFileSync(join(dir, '../cert.pem'), 'utf8');
const key = readFileSync(join(dir, '../key.pem'), 'utf8');

const httpsServer = createServer({ cert, key });
const wss = new WebSocketServer({ server: httpsServer });

httpsServer.on('listening', () => {
    console.log(`wss echo listening on ${host}:${port}`);
});
httpsServer.listen(port, host);

wss.on('connection', (ws, req) => {
    const peer = `${req.socket.remoteAddress}:${req.socket.remotePort}`;
    console.log(`conn open ${peer}`);

    ws.on('message', (data, isBinary) => {
        ws.send(data, { binary: isBinary });
    });

    ws.on('close', () => console.log(`conn close ${peer}`));
    ws.on('error', (err) => console.error(`conn error ${peer}:`, err.message));
});

wss.on('error', (err) => {
    console.error('server error:', err);
    process.exit(1);
});

httpsServer.on('error', (err) => {
    console.error('server error:', err);
    process.exit(1);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        wss.close(() => httpsServer.close(() => process.exit(0)));
    });
}
