const host = Deno.env.get('SERVER_IP');
const portStr = Deno.env.get('SERVER_PORT');
const port = Number(portStr);

if (!host) {
    console.error('SERVER_IP env var is required (set by harness_run_test.sh).');
    Deno.exit(1);
}
if (!Number.isInteger(port) || port <= 0) {
    console.error('SERVER_PORT env var must be a positive integer.');
    Deno.exit(1);
}

const certDir = new URL('../', import.meta.url);
const cert = await Deno.readTextFile(new URL('cert.pem', certDir));
const key = await Deno.readTextFile(new URL('key.pem', certDir));

const endpoint = new Deno.QuicEndpoint({ hostname: host, port });
const listener = endpoint.listen({ cert, key, alpnProtocols: ['h3'] });

console.log(`webtransport datagram echo listening on ${host}:${port}`);

async function handleConnection(conn: Deno.QuicConn): Promise<void> {
    const peer = `${conn.remoteAddr.hostname}:${conn.remoteAddr.port}`;
    let wt: WebTransport;
    try {
        wt = await Deno.upgradeWebTransport(conn);
        await wt.ready;
    } catch (err) {
        console.error(`upgrade failed ${peer}:`, err);
        return;
    }
    console.log(`conn open ${peer}`);

    const reader = wt.datagrams.readable.getReader();
    const writer = wt.datagrams.writable.getWriter();
    try {
        while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            await writer.write(value);
        }
    } catch {} finally {
        try { reader.releaseLock(); } catch {}
        try { writer.releaseLock(); } catch {}
    }
    console.log(`conn close ${peer}`);
}

try {
    for await (const incoming of listener) {
        void (async () => {
            try {
                await handleConnection(await incoming.accept());
            } catch (err) {
                console.error('accept failed:', err);
            }
        })();
    }
} catch {}
