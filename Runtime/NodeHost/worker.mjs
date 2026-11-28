// worker.mjs — one bundle, in a worker thread of its own.
//
// host.mjs starts one worker per bundle. The worker has its own V8
// heap with a limit: a bundle that runs out of memory ends only this
// thread, where in the host's own isolate it would abort the app.
//
// TWO bundle shapes (v2.1.3):
//
//  1. CatPawOpen bundles — the contract this file was written for:
//     they export a `start(config)` function; inside start() they
//     build a Fastify app on the server `globalThis.catServerFactory`
//     makes, then serve GET /config and POST
//     /spider/<key>/{init,home,category,detail,play,search}. The
//     worker forces their server onto 127.0.0.1 with an ephemeral
//     port, waits until it listens, and reports {ready: true, port}.
//
//  2. Standalone bundles (e.g. the 9280.kstore.vip index.js,
//     CatVodSpiderios format) — they have NO exports.start at all
//     (their only module.exports is dead code) and autostart
//     themselves, but ONLY when run as `node index.js` with no
//     catServerFactory defined: their entry is
//     `BTr()&&Dtt().catch(...)`, where BTr() returns false while
//     `typeof globalThis.catServerFactory === "function"` or
//     `process.argv[1]` does not end in `index.js`. Defining the
//     factory for them (the old behaviour) silently prevents the
//     server from ever starting, and the worker then threw
//     "The script is not a CatPawOpen bundle". For these the worker
//     re-loads the bundle with the factory removed and argv[1]
//     pointing at the bundle file — the `node index.js` shape —
//     then waits for its GET /health to answer (port 9988 by
//     default, PORT / DEV_HTTP_PORT env, +1 while occupied, per the
//     bundle's own rule) and reports that port to host.mjs.
//     host.mjs's /call routing needs no change: it only ever talks
//     HTTP to the reported port.
import http from 'node:http';
import { createRequire } from 'node:module';
import { parentPort, workerData } from 'node:worker_threads';
import { inspect } from 'node:util';

const { bundle, configFile } = workerData;

let messagesPort = workerData.messagesPort;
// No proxy support in YiPlayer v2 (there is no proxy UI): bundles
// reach their sites directly. host.mjs therefore sends no proxy, and
// there is no agents.mjs to import.

// Logging never throws: what JSON can't write (a circular object, a
// BigInt) is written as Node's own console writes it, and a failed
// write is dropped.
function logText(value) {
    if (typeof value === 'string') return value;
    try { return JSON.stringify(value); } catch { return inspect(value); }
}
function log(...values) {
    try { process.stderr.write(values.map(logText).join(' ') + '\n'); } catch { }
}
function thrownText(error) {
    try { return error?.stack || String(error); } catch { return error; }
}

process.env.NODE_ENV = 'development'; // Fastify then skips its per-request logger
Object.assign(console, { log, info: log, warn: log, error: log, debug: log });

// Some bundles' handlers answer a request twice; the CatVod apps keep
// serving, so this does too.
process.on('uncaughtException', error => log('CATPAW_UNCAUGHT', thrownText(error)));
process.on('unhandledRejection', error => log('CATPAW_UNHANDLED', thrownText(error)));

// Where bundles send their messages to the app: the host's `messages` server.
globalThis.catDartServerPort = () => messagesPort;

// A bundle's `start(config)` builds a Fastify app on the server
// `catServerFactory` makes, then lists its sources at GET /config and
// serves each at POST /spider/<key>/<type>/{init,home,category,detail,play,search}.
let server;
globalThis.catServerFactory = handler => {
    server = http.createServer(handler);
    const listen = server.listen.bind(server);
    server.listen = (...args) => listen(0, '127.0.0.1', args.find(arg => typeof arg === 'function'));
    return server;
};

parentPort.on('message', message => {
    if (message.messagesPort) messagesPort = message.messagesPort;
    // iOS took the app's listening sockets back while it was suspended:
    // listen on a new port.
    if (message.relisten) {
        const answer = reply => parentPort.postMessage({ relistened: message.relisten, ...reply });
        // Standalone bundles own their server (the worker never got a
        // handle on it), so there is nothing to re-listen here; the
        // bundle keeps its own port.
        if (!server) { answer({ error: 'standalone bundle owns its server; cannot relisten' }); return; }
        server.close();
        server.once('error', error => answer({ error: error.message }));
        server.listen(() => answer({ port: server.address().port }));
    }
});

// One GET /health attempt: any HTTP answer at all means a server is
// listening on that port (a 404 only means it has no /health route);
// a refused connection or a timeout means nothing is there (yet).
function probeHealth(port, timeoutMs = 1000) {
    return new Promise(resolve => {
        const req = http.get({ host: '127.0.0.1', port, path: '/health', timeout: timeoutMs }, res => {
            res.resume();
            resolve({ ok: true, status: res.statusCode });
        });
        req.on('timeout', () => { req.destroy(new Error('timeout')); resolve({ ok: false, error: 'timeout' }); });
        req.on('error', error => resolve({ ok: false, error: error.message }));
    });
}

// Standalone bundles pick their own port: 9988 by default, the PORT /
// DEV_HTTP_PORT env var when set, +1 while occupied (their own rule).
// Poll /health on that port and the next few, until one answers.
async function waitForHealth(deadlineMs = 20_000) {
    const basePort = Number(process.env.PORT || process.env.DEV_HTTP_PORT || 9988) || 9988;
    const startedAt = Date.now();
    let last = 'no attempt yet';
    while (Date.now() - startedAt < deadlineMs) {
        for (let port = basePort; port < basePort + 10; port++) {
            const result = await probeHealth(port);
            if (result.ok) return { port, healthStatus: result.status };
            last = `port ${port}: ${result.status ? `HTTP ${result.status}` : result.error}`;
        }
        await new Promise(resolve => setTimeout(resolve, 200));
    }
    const waited = ((Date.now() - startedAt) / 1000).toFixed(1);
    throw new Error(`standalone 模式启动失败：bundle 没有 exports.start，已按 node index.js 方式启动，等了 ${waited} 秒 /health 仍未通（最后一次：${last}）`);
}

// Standalone start: the bundle was already required once above (to
// inspect its exports) with catServerFactory defined, so its BTr()
// autostart check saw the factory and refused to start. Load it a
// second time with the factory gone and argv[1] pointing at the
// bundle file — the `node index.js` shape its BTr() accepts — and
// the top-level `BTr()&&Dtt()` entry starts its server. The first
// load only ran definitions (BTr() short-circuited Dtt()), so the
// re-load is the load that actually starts anything.
async function startStandalone(require, bundle) {
    try { delete require.cache[require.resolve(bundle)]; } catch { }
    delete globalThis.catServerFactory;
    delete process.env.CATVOD_DISABLE_AUTOSTART;
    // argv is process-global, shared by all workers — but host.mjs
    // starts bundles one at a time (its `starting` promise chain),
    // and this assignment is immediately followed by the synchronous
    // require below, so no other worker can interleave in between.
    process.argv[1] = bundle;
    require(bundle);
    const { port, healthStatus } = await waitForHealth();
    if (healthStatus < 200 || healthStatus >= 300) {
        log('CATPAW_STANDALONE_HEALTH', `port ${port} answers HTTP ${healthStatus} on /health (not 2xx); using it anyway`);
    }
    return port;
}

try {
    const require = createRequire(bundle);

    // The bundle's settings sit beside it (index.js -> index.config.js);
    // without them it starts with none.
    let config = {};
    if (configFile) {
        try {
            const module = require(configFile);
            config = module?.default ?? module ?? {};
        } catch (error) { log('CATPAW_CONFIG', error.message); }
    }

    const exports = require(bundle);
    if (typeof exports.start === 'function') {
        // CatPawOpen path: start(config) builds the app on the server
        // catServerFactory makes; wait until it listens.
        await exports.start(config);

        const deadline = Date.now() + 20_000;
        while (!server?.listening) {
            if (Date.now() > deadline) throw new Error('The CatPawOpen server did not start');
            await new Promise(resolve => setTimeout(resolve, 50));
        }

        parentPort.postMessage({ ready: true, port: server.address().port });
    } else {
        // Standalone path (e.g. the 9280 bundle): no exports.start,
        // the bundle starts its own server — see startStandalone.
        const port = await startStandalone(require, bundle);
        parentPort.postMessage({ ready: true, port });
    }
} catch (error) {
    parentPort.postMessage({ ready: false, error: error?.message || String(error) });
}
