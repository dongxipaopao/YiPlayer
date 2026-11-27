// host.mjs — YiPlayer's embedded Node.js host for CatPawOpen (猫源) bundles.
//
// PROTOCOL (verified against tvbox-silicon Runtime/NodeHost/main.mjs +
// worker.mjs, 2026-11-27): the Swift side (NodeHost.swift) starts Node
// once as `node host.mjs <controlFile> <relistenFile>`. This script
// writes {"port": <n>, "token": "..."} to <controlFile> once its
// control server listens, then answers POST /call with the header
// `x-yingxia-token: <token>`:
//   POST /call {bundle, api, profile, params} -> {"result": "<text>"}
//                                             or {"error": "<msg>"}
// Each bundle runs in a worker thread of its own (worker.mjs) with a
// capped heap, so a bundle that runs out of memory ends only its
// thread, not the app. The worker loads the bundle (a Fastify server
// bundle — e.g. the 9280.kstore.vip index.js), which serves
//   GET  /config
//   POST /spider/<key>/{init,home,category,detail,play,search}
// and this script routes the app's calls to those routes.
//
// What YiPlayer DELIBERATELY leaves out (Yingxia has them, YiPlayer
// has no UI for them): cloud-drive account sharing (quark/UC/Baidu/
// 115/Xunlei sign-ins), HTTP proxy support, and bundle config-center
// sign-in (catLogin). A bundle that needs those answers gets the same
// "no answer" a fresh install would give it, and carries on.
//
// License note: this file is YiPlayer's own implementation of the
// control protocol above. It is NOT a copy of tvbox-silicon's
// main.mjs; the protocol (route names, /call shape, worker split) is
// dictated by the CatPawOpen bundle format itself.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import os from 'node:os';
import crypto from 'node:crypto';
import { Worker } from 'node:worker_threads';
import { inspect } from 'node:util';

const [controlFile, relistenFile] = process.argv.slice(2);
const token = crypto.randomBytes(16).toString('hex');

// Logging never throws: a circular object or BigInt is written the
// way Node's console writes it, and a failed write is dropped.
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

process.env.NODE_ENV = 'development';
Object.assign(console, { log, info: log, warn: log, error: log, debug: log });
process.on('uncaughtException', error => log('CATPAW_UNCAUGHT', thrownText(error)));
process.on('unhandledRejection', error => log('CATPAW_UNHANDLED', thrownText(error)));

// ---- Playback / danmu bookkeeping ------------------------------------
// Bundles ask the app what is playing ("getPlayInfo") a moment after
// a play starts, match it in their danmu_api, and send the comments'
// address back ("danmuPush"). The app asks for that address with
// catDanmaku and fetches the comments itself.
const catTitles = new Map(); // play id -> {title, episodeName, flag}
let catPlaying = { title: '', episodeName: '', flag: '', at: 0, asked: 0 };
let catPushed = { url: '', at: 0 };

function rememberTitles(text) {
    let list;
    try { list = JSON.parse(text)?.list; } catch { return; }
    for (const video of Array.isArray(list) ? list : []) {
        const title = String(video?.vod_name ?? '').trim();
        if (!title) continue;
        const flags = String(video.vod_play_from ?? '').split('$$$');
        String(video.vod_play_url ?? '').split('$$$').forEach((line, index) => {
            for (const item of line.split('#')) {
                const cut = item.indexOf('$');
                const episodeName = cut < 0 ? '' : item.slice(0, cut).trim();
                const id = cut < 0 ? item : item.slice(cut + 1);
                if (!id.trim()) continue;
                catTitles.delete(id);
                catTitles.set(id, { title, episodeName, flag: flags[index] || '' });
            }
        });
    }
    while (catTitles.size > 3000) catTitles.delete(catTitles.keys().next().value);
}

function startedPlaying(flag, id) {
    const known = catTitles.get(id);
    catPlaying = { title: known?.title || '', episodeName: known?.episodeName || '', flag: flag || known?.flag || '', at: Date.now(), asked: 0 };
}

function danmakuAddress(port, params) {
    const now = Date.now(), name = String(params.name || ''), episode = String(params.episode || '');
    const current = catPlaying.title === name && catPlaying.episodeName === episode;
    const pushed = current && catPushed.at >= catPlaying.at && catPushed.url.startsWith(`http://127.0.0.1:${port}/`) ? catPushed.url : '';
    const pending = current && !pushed && now - catPlaying.at < 3000 && !(catPlaying.asked && now - catPlaying.asked > 500);
    const query = new URLSearchParams({ name });
    if (episode) query.set('episode', episode);
    return { result: JSON.stringify({ url: pushed || `http://127.0.0.1:${port}/danmu/auto?${query}`, pushed: !!pushed, pending }) };
}

// ---- Messages server (bundles -> app) --------------------------------
const pageWatchers = new Set();
const loopbackPage = page => page && /^http:\/\/(127\.0\.0\.1|localhost):\d+(\/|$)/.test(page) ? page : undefined;

async function answerMessage(req, res) {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let message = {};
    try { message = JSON.parse(Buffer.concat(chunks).toString('utf8')) || {}; } catch { }
    const page = String(message.opt?.url || '');
    if (message.action === 'getPlayInfo') {
        catPlaying.asked = Date.now();
        const { title, episodeName, flag } = catPlaying;
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ title, episodeName, flag }));
        return;
    }
    if (message.action === 'danmuPush' && loopbackPage(page)) {
        catPushed = { url: page.replace('//localhost:', '//127.0.0.1:'), at: Date.now() };
    }
    if (['openInternalWebview', 'openWeb'].includes(message.action) && /^http:\/\/(127\.0\.0\.1|localhost|\d+\.\d+\.\d+\.\d+):\d+(\/|$)/.test(page)) {
        for (const watch of pageWatchers) watch(page);
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('null');
}

const messages = http.createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/msg') return answerMessage(req, res);
    res.writeHead(404); res.end();
});
messages.on('error', error => log('CATPAW_MESSAGES', error?.stack || String(error)));
messages.listen(0, '127.0.0.1');

// ---- Bundle workers ---------------------------------------------------
const heapLimit = Number(process.env.YIPLAYER_NODE_HEAP_MB) || Math.round(Math.min(768, Math.max(256, os.totalmem() / 2 ** 20 / 8)));
const bundles = new Map(); // bundle file -> Promise<instance>
let starting = Promise.resolve();

function fetchText(url, timeoutMs = 20_000) {
    return new Promise((resolve, reject) => {
        const lib = url.startsWith('https:') ? https : http;
        const req = lib.get(url, { timeout: timeoutMs }, res => {
            const chunks = [];
            res.on('data', c => chunks.push(c));
            res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
        });
        req.on('timeout', () => { req.destroy(new Error('timeout')); });
        req.on('error', reject);
    });
}

async function start({ bundle, api, profile }) {
    fs.mkdirSync(profile, { recursive: true });
    // The bundle's settings sit beside it (index.js -> index.config.js).
    let configFile;
    try {
        const response = await fetchText(api.replace(/\.js(?=$|[?#])/, '.config.js'));
        const text = response.status === 200 ? response.text : '';
        if (text) {
            configFile = bundle.replace(/\.js$/, '.config.js');
            fs.writeFileSync(configFile, text);
        }
    } catch (error) { log('CATPAW_CONFIG', error.message); }

    const worker = new Worker(new URL('./worker.mjs', import.meta.url), {
        workerData: { bundle, configFile, messagesPort: messages.address()?.port || 0 },
        env: { ...process.env, NODE_PATH: profile },
        resourceLimits: { maxOldGenerationSizeMb: heapLimit },
    });
    const instance = { worker, port: 0, ports: [], started: new Set(), exited: false, failure: null, startedAt: Date.now() };
    worker.on('error', error => { instance.failure = error; log('CATPAW_WORKER', bundle, error?.code || '', error?.stack || String(error)); });
    instance.ended = new Promise(resolve => worker.once('exit', code => { instance.exited = true; log('CATPAW_WORKER_EXIT', bundle, code); resolve(); }));

    try {
        instance.port = await alive(instance, new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('The CatPawOpen server did not start')), 25_000);
            timer.unref();
            worker.on('message', function ready(reply) {
                if (!('ready' in reply)) return;
                clearTimeout(timer);
                worker.off('message', ready);
                reply.ready ? resolve(reply.port) : reject(new Error(reply.error));
            });
        }));
    } catch (error) {
        await worker.terminate();
        throw error;
    }
    instance.ports.push(instance.port);
    return instance;
}

function stopped(instance) {
    const reason = instance.failure?.code === 'ERR_WORKER_OUT_OF_MEMORY' ? 'ran out of memory' : 'stopped';
    return new Error(`The source ${reason} and was closed. Try again to start it again.`);
}

function alive(instance, promise) {
    const ended = instance.ended.then(() => { throw stopped(instance); });
    ended.catch(() => { });
    const answered = promise.catch(async error => {
        await Promise.race([instance.ended, new Promise(resolve => setTimeout(resolve, 500).unref())]);
        throw instance.exited ? stopped(instance) : error;
    });
    answered.catch(() => { });
    return Promise.race([answered, ended]);
}

// Bundles reuse keep-alive connections the far end has since dropped;
// a "socket hang up" / reset fails at once, and one retry on a fresh
// connection fixes it. A slow failure is not retried.
async function sendFresh(send, route, body) {
    const startedAt = Date.now();
    try { return await send(route, body); } catch (error) {
        if (error.status !== 500 || !/socket hang up|ECONNRESET|EPIPE/.test(error.message) || Date.now() - startedAt > 2500) throw error;
        log('CATPAW_RETRY', route, error.message);
        return send(route, body);
    }
}

async function call(instance, params) {
    const send = async (route, body) => {
        const init = body === undefined ? {} : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
        const ask = () => alive(instance, postJson(`http://127.0.0.1:${instance.port}${route}`, init));
        // A refused connection means iOS took the bundle's socket back
        // while the app was suspended, unless its worker ended.
        return ask().catch(async error => {
            if (error.code !== 'ECONNREFUSED') throw error;
            if (instance.exited) throw stopped(instance);
            await relisten();
            return ask();
        });
    };

    if (params.catConfig) return { result: await getText(`http://127.0.0.1:${instance.port}/config`) };
    if (params.catDanmaku) return danmakuAddress(instance.port, params);

    const api = String(params.catPawOpen || '');
    if (!/^\/spider\/[^?#]+$/.test(api)) throw new Error('Invalid CatPawOpen source');

    if (!instance.started.has(api)) {
        await postJson(`http://127.0.0.1:${instance.port}${api}/init`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' })
            .catch(error => { if (error.status !== 404) throw error; });
        instance.started.add(api);
    }

    let route, body;
    if ('play' in params) { route = '/play'; body = { flag: params.flag || '', id: params.play }; startedPlaying(body.flag, body.id); }
    else if ('ids' in params) { route = '/detail'; body = { id: params.ids }; }
    else if ('wd' in params) { route = '/search'; body = { wd: params.wd, page: Number(params.pg || 1), quick: params.quick === 'true' }; }
    else if ('t' in params) { route = '/category'; body = { id: params.t, page: Number(params.pg || 1), filter: true, filters: params.filters ? JSON.parse(params.filters) : {} }; }
    else { route = '/home'; body = {}; }

    const { text, page } = await watchingPages(route, () => sendFresh(send, api + route, body)
        .then(text => route === '/search' && !text.trim() ? '{"list":[]}' : text)
        .catch(error => { if (route === '/search' && error.status === 404) return '{"list":[]}'; throw error; }));

    if (route === '/detail') rememberTitles(text);
    const ports = instance.ports.join('|');
    const local = address => address.replace(new RegExp(`http://\\d+\\.\\d+\\.\\d+\\.\\d+:(?:${ports})/`, 'g'), `http://127.0.0.1:${instance.port}/`);
    const result = local(text), shown = loopbackPage(page && local(page));
    return { result: shown ? withPage(result, shown) : result };
}

// Small HTTP helpers (GET text / POST JSON) with status attached to errors.
function httpJson(url, init = {}) {
    return new Promise((resolve, reject) => {
        const lib = url.startsWith('https:') ? https : http;
        const req = lib.request(url, init, res => {
            const chunks = [];
            res.on('data', c => chunks.push(c));
            res.on('end', () => {
                const text = Buffer.concat(chunks).toString('utf8');
                if (res.statusCode < 200 || res.statusCode >= 300) {
                    let message = text;
                    try { message = JSON.parse(text).message || text; } catch { }
                    reject(Object.assign(new Error(`HTTP ${res.statusCode}: ${String(message).slice(0, 300)}`), { status: res.statusCode }));
                } else resolve(text);
            });
        });
        req.on('error', reject);
        if (init.body) req.write(init.body);
        req.end();
    });
}
const getText = url => httpJson(url);
const postJson = (url, init) => httpJson(url, init);

async function watchingPages(route, send) {
    if (!route.endsWith('/detail')) return { text: await send() };
    let page, arrived;
    const watch = address => { page = address; arrived?.(); };
    pageWatchers.add(watch);
    try {
        const text = await send();
        if (!page && !playable(text)) await new Promise(resolve => { arrived = resolve; setTimeout(resolve, 300); });
        return { text, page };
    } finally { pageWatchers.delete(watch); }
}

function playable(text) {
    try { return (JSON.parse(text)?.list ?? []).some(video => video?.vod_play_url); } catch { return true; }
}

function withPage(text, page) {
    let answer;
    try { answer = JSON.parse(text); } catch { return text; }
    if (!answer || typeof answer !== 'object' || Array.isArray(answer)) return text;
    const list = Array.isArray(answer.list) ? answer.list : [];
    const video = list[0] && typeof list[0] === 'object' ? list[0] : {};
    if (!`${video.vod_content ?? ''}\n${video.vod_remarks ?? ''}`.includes(page)) {
        video.vod_content = [video.vod_content, page].filter(Boolean).join('\n');
    }
    answer.list = [video, ...list.slice(1)];
    return JSON.stringify(answer);
}

async function relocate(address) {
    const url = new URL(address);
    for (const pending of bundles.values()) {
        const instance = await pending.catch(() => null);
        if (!instance?.ports.includes(Number(url.port))) continue;
        url.port = String(instance.port);
        return url.toString();
    }
    return address;
}

async function restartBehind(address, olderThan) {
    const port = Number(new URL(address).port);
    for (const [bundle, pending] of bundles) {
        const instance = await pending.catch(() => null);
        if (!instance?.ports.includes(port)) continue;
        if (instance.exited || Date.now() - instance.startedAt < olderThan) return false;
        if (bundles.get(bundle) === pending) bundles.delete(bundle);
        log('CATPAW_RESTART', bundle);
        await instance.worker.terminate();
        return true;
    }
    return false;
}

// ---- Control server (Swift -> Node) -----------------------------------
const control = http.createServer(async (req, res) => {
    const reply = body => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (req.method !== 'POST' || req.url !== '/call' || req.headers['x-yingxia-token'] !== token) { res.writeHead(403); res.end(); return; }
    try {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (input.relocate) { reply({ result: await relocate(String(input.relocate)) }); return; }
        if (input.restartBehind) { reply({ result: await restartBehind(String(input.restartBehind), Number(input.olderThan) || 0) }); return; }

        let instance = bundles.get(input.bundle);
        if (!instance) {
            const pending = instance = starting = starting.catch(() => { }).then(() => start(input));
            bundles.set(input.bundle, pending);
            const forget = () => { if (bundles.get(input.bundle) === pending) bundles.delete(bundle); };
            pending.then(started => started.ended.then(forget), forget);
        }
        instance = await instance;
        reply(await call(instance, input.params || {}));
    } catch (error) {
        log(error?.stack || String(error));
        reply({ error: String(error), errorCode: 'script_error' });
    }
});

function announce() {
    fs.writeFileSync(controlFile + '.tmp', JSON.stringify({ port: control.address().port, token }));
    fs.renameSync(controlFile + '.tmp', controlFile);
}

// iOS takes back the listening sockets of a suspended app. Swift
// appends a line to <relistenFile> when the control port refuses it;
// every server then listens on a new port, and the control file is
// rewritten so Swift finds the new port.
let relistening = null;
function relisten() {
    relistening ??= (async () => {
        const listen = server => new Promise(resolve => { server.close(); server.listen(0, '127.0.0.1', resolve); });
        await listen(control);
        await listen(messages);
        for (const pending of bundles.values()) {
            const instance = await pending.catch(() => null);
            if (!instance || instance.exited) continue;
            instance.worker.postMessage({ relisten: true });
            instance.ports.push(instance.port);
        }
        announce();
        relistening = null;
    })();
    return relistening;
}

if (relistenFile) {
    fs.watchFile(relistenFile, { interval: 2000 }, (curr, prev) => {
        if (curr.mtimeMs !== prev.mtimeMs) relisten().catch(error => log('CATPAW_RELISTEN', error?.stack || String(error)));
    });
}

control.listen(0, '127.0.0.1', () => announce());
control.on('error', error => log('CATPAW_CONTROL', error?.stack || String(error)));
