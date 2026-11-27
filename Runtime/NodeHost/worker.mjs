// worker.mjs — one CatPawOpen bundle, in a worker thread of its own.
//
// host.mjs starts one worker per bundle. The worker has its own V8
// heap with a limit: a bundle that runs out of memory ends only this
// thread, where in the host's own isolate it would abort the app.
//
// The bundle's contract (CatPawOpen format — this is what the bundle
// itself expects, not an invention of YiPlayer's):
//   * it exports a `start(config)` function;
//   * inside start() it builds a Fastify app on the server that
//     `globalThis.catServerFactory(handler)` returns, then serves
//       GET  /config
//       POST /spider/<key>/{init,home,category,detail,play,search}
//   * it may call `globalThis.catDartServerPort()` to find where the
//     app's messages server listens, and POST messages there.
// The worker forces the bundle's server onto 127.0.0.1 with an
// ephemeral port (the bundle must never pick its own port), waits
// until it listens, and reports {ready: true, port} to host.mjs.
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
        server.close();
        server.once('error', error => answer({ error: error.message }));
        server.listen(() => answer({ port: server.address().port }));
    }
});

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
    if (typeof exports.start !== 'function') throw new Error('The script is not a CatPawOpen bundle');

    await exports.start(config);

    const deadline = Date.now() + 20_000;
    while (!server?.listening) {
        if (Date.now() > deadline) throw new Error('The CatPawOpen server did not start');
        await new Promise(resolve => setTimeout(resolve, 50));
    }

    parentPort.postMessage({ ready: true, port: server.address().port });
} catch (error) {
    parentPort.postMessage({ ready: false, error: error?.message || String(error) });
}
