"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { once } = require("node:events");

const ROOT = path.resolve(__dirname, "..");
const BASE_CONFIG = JSON.parse(fs.readFileSync(path.join(ROOT, "config.json"), "utf8"));
const KEY = "test-secret-not-a-real-key";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function listen(server, port = 0) {
  server.listen(port, "127.0.0.1");
  await once(server, "listening");
  return server.address().port;
}

async function closeServer(server) {
  if (!server.listening) return;
  if (typeof server.closeAllConnections === "function") server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
}

async function freePort() {
  const server = net.createServer();
  const port = await listen(server);
  await closeServer(server);
  return port;
}

async function waitForPort(child, port) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(`proxy exited before listening: ${child.exitCode || child.signalCode}`);
    }
    const connected = await new Promise((resolve) => {
      const socket = net.connect({ host: "127.0.0.1", port });
      const timer = setTimeout(() => {
        socket.destroy();
        resolve(false);
      }, 150);
      socket.once("connect", () => {
        clearTimeout(timer);
        socket.destroy();
        resolve(true);
      });
      socket.once("error", () => {
        clearTimeout(timer);
        resolve(false);
      });
    });
    if (connected) return;
    await sleep(50);
  }
  throw new Error("proxy did not start listening");
}

async function createFixture(t, overrides = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "magpie-proxy-test-"));
  const requests = [];
  const state = { handler: null, onRequest: null };
  const upstream = http.createServer((req, res) => {
    if (state.onRequest) state.onRequest(req, res);
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", async () => {
      const record = {
        method: req.method,
        url: req.url,
        headers: { ...req.headers },
        body: Buffer.concat(chunks),
      };
      requests.push(record);
      if (state.handler) {
        await state.handler(record, req, res);
        return;
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });
  });
  const upstreamPort = await listen(upstream);
  const listenPort = await freePort();
  const settingsPath = path.join(root, "settings.json");
  const logPath = path.join(root, "proxy.log");
  fs.writeFileSync(settingsPath, JSON.stringify({ lanKey: KEY }));
  const config = {
    ...BASE_CONFIG,
    listenHost: "127.0.0.1",
    listenPort,
    upstream: `http://127.0.0.1:${upstreamPort}`,
    settingsPath,
    logPath,
    ...overrides,
  };
  fs.writeFileSync(path.join(root, "config.json"), JSON.stringify(config));
  fs.copyFileSync(path.join(ROOT, "proxy.js"), path.join(root, "proxy.js"));
  const child = spawn(process.execPath, [path.join(root, "proxy.js")], {
    cwd: root,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.kill();
      await Promise.race([exited, sleep(2000)]);
    }
    await closeServer(upstream);
    fs.rmSync(root, { recursive: true, force: true });
  });

  await waitForPort(child, listenPort);

  async function request(urlPath, options = {}) {
    const headers = { ...(options.headers || {}) };
    if (
      options.auth !== false &&
      !headers.authorization &&
      !headers["x-api-key"] &&
      !headers["x-goog-api-key"]
    ) {
      headers.authorization = `Bearer ${options.key || KEY}`;
    }
    let payload = options.body;
    if (typeof payload === "string") payload = Buffer.from(payload);
    if (payload && !options.chunked && !headers["content-length"]) {
      headers["content-length"] = String(payload.length);
    }
    if (options.chunked) headers["transfer-encoding"] = "chunked";

    return new Promise((resolve, reject) => {
      const req = http.request(
        { host: "127.0.0.1", port: listenPort, path: urlPath, method: options.method || "GET", headers },
        (res) => {
          const chunks = [];
          res.on("data", (chunk) => {
            chunks.push(chunk);
            if (options.onChunk) options.onChunk(chunk);
          });
          res.on("end", () => {
            const bodyBuffer = Buffer.concat(chunks);
            resolve({ status: res.statusCode, headers: res.headers, bodyBuffer, body: bodyBuffer.toString() });
          });
        },
      );
      req.on("error", reject);
      if (options.chunked) {
        (async () => {
          for (const chunk of options.chunks || [payload]) {
            req.write(chunk);
            if (options.chunkDelayMs) await sleep(options.chunkDelayMs);
          }
          req.end();
        })().catch(reject);
      } else {
        req.end(payload);
      }
    });
  }

  return {
    root,
    child,
    config,
    settingsPath,
    logPath,
    requests,
    request,
    state,
    upstream,
    upstreamPort,
    getStderr: () => stderr,
  };
}

test("authentication, methods, management routes and literal Gemini actions", async (t) => {
  const f = await createFixture(t);
  assert.equal((await f.request("/v1/models", { auth: false })).status, 401);
  assert.equal((await f.request(`/v1/models?key=${KEY}`, { auth: false })).status, 401);
  assert.equal((await f.request("/v1/models", { key: "wrong" })).status, 401);
  assert.equal((await f.request("/v1/models")).status, 200);
  assert.equal((await f.request("/v1/magpie/limit")).status, 404);
  assert.equal((await f.request("/v1/chat/completions", { method: "PUT" })).status, 404);
  assert.equal((await f.request("/v1beta/models/foo:generateContent")).status, 404);
  assert.equal(
    (await f.request("/v1beta/models/foo:generateContent", { method: "POST", body: "{}" })).status,
    200,
  );
  assert.equal((await f.request("/v1/models/group/model")).status, 200);
  assert.equal(f.requests.some((r) => r.url.includes("magpie")), false);
});

test("all three auth headers work while source, routing and credential headers are stripped", async (t) => {
  const f = await createFixture(t);
  const response = await f.request("/v1/messages?beta=true", {
    method: "POST",
    body: '{"messages":[]}',
    headers: {
      "x-api-key": KEY,
      "content-type": "application/json",
      "anthropic-version": "2023-06-01",
      "cf-connecting-ip": "203.0.113.10",
      "cf-ray": "fake",
      "x-forwarded-for": "198.51.100.2",
      forwarded: "for=198.51.100.2",
      "true-client-ip": "198.51.100.2",
      "x-client-ip": "198.51.100.2",
      "x-cluster-client-ip": "198.51.100.2",
      "x-originating-ip": "198.51.100.2",
      "x-original-url": "/v1/magpie/limit",
      "x-rewrite-url": "/v1/magpie/limit",
      "x-http-method-override": "DELETE",
      "x-real-ip": "198.51.100.2",
      "api-key": "must-not-leak",
      connection: "x-custom-hop",
      "x-custom-hop": "must-not-leak",
    },
  });
  assert.equal(response.status, 200);
  const seen = f.requests[0];
  assert.equal(seen.url, "/v1/messages?beta=true");
  assert.equal(seen.headers.authorization, "Bearer magpie-public");
  assert.equal(seen.headers["anthropic-version"], "2023-06-01");
  assert.equal(seen.headers["content-type"], "application/json");
  for (const name of [
    "x-api-key", "x-goog-api-key", "cf-ray", "cf-connecting-ip", "x-forwarded-for",
    "forwarded", "true-client-ip", "x-client-ip", "x-cluster-client-ip", "x-originating-ip",
    "x-original-url", "x-rewrite-url", "x-http-method-override", "x-real-ip", "api-key",
    "x-custom-hop",
  ]) {
    assert.equal(seen.headers[name], undefined, name);
  }
  assert.equal((await f.request("/v1/models", { headers: { "x-goog-api-key": KEY } })).status, 200);
});

test("query keys never reach upstream and other query parameters remain intact", async (t) => {
  const f = await createFixture(t);
  assert.equal((await f.request("/v1/models?alt=sse&beta=true")).status, 200);
  assert.equal(f.requests[0].url, "/v1/models?alt=sse&beta=true");
  for (const url of [
    "/v1/models?key=do-not-log&alt=sse",
    "/v1/models?%6bey=do-not-log",
    "/v1/models?key=one&key=two",
  ]) {
    assert.equal((await f.request(url)).status, 400);
  }
  assert.equal(f.requests.length, 1);
  const logs = fs.readFileSync(f.logPath, "utf8");
  assert.equal(logs.includes("do-not-log"), false);
});

test("cached key has a hard stale limit, negative caching and automatic recovery", async (t) => {
  const f = await createFixture(t, { lanKeyCacheMs: 50, lanKeyMaxStaleMs: 250, lanKeyRetryMs: 100 });
  assert.equal((await f.request("/v1/models")).status, 200);
  fs.rmSync(f.settingsPath);
  await sleep(80);
  assert.equal((await f.request("/v1/models")).status, 200);
  await sleep(300);
  const upstreamCount = f.requests.length;
  for (let i = 0; i < 12; i++) {
    assert.equal((await f.request("/v1/models")).status, 503);
  }
  assert.equal(f.requests.length, upstreamCount);
  await sleep(30);
  const failedLogs = fs.readFileSync(f.logPath, "utf8");
  assert.ok((failedLogs.match(/WARN cannot read lanKey/g) || []).length <= 2);

  fs.writeFileSync(f.settingsPath, JSON.stringify({ lanKey: "replacement-test-key" }));
  await sleep(120);
  assert.equal((await f.request("/v1/models", { key: KEY })).status, 401);
  assert.equal((await f.request("/v1/models", { key: "replacement-test-key" })).status, 200);
});

test("invalid upstream path, query, user info and hash fail before listening", async (t) => {
  for (const suffix of ["/base", "?token=x", "#fragment"]) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "magpie-upstream-config-"));
    const port = await freePort();
    fs.writeFileSync(path.join(root, "settings.json"), JSON.stringify({ lanKey: KEY }));
    fs.copyFileSync(path.join(ROOT, "proxy.js"), path.join(root, "proxy.js"));
    fs.writeFileSync(path.join(root, "config.json"), JSON.stringify({
      ...BASE_CONFIG,
      listenPort: port,
      upstream: `http://127.0.0.1:3425${suffix}`,
      settingsPath: path.join(root, "settings.json"),
      logPath: path.join(root, "proxy.log"),
    }));
    const child = spawn(process.execPath, [path.join(root, "proxy.js")], { cwd: root, stdio: "ignore" });
    const [code] = await Promise.race([
      once(child, "exit"),
      sleep(2000).then(() => { child.kill(); throw new Error(`upstream accepted: ${suffix}`); }),
    ]);
    assert.notEqual(code, 0, suffix);
    fs.rmSync(root, { recursive: true, force: true });
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "magpie-upstream-userinfo-"));
  fs.copyFileSync(path.join(ROOT, "proxy.js"), path.join(root, "proxy.js"));
  fs.writeFileSync(path.join(root, "config.json"), JSON.stringify({
    ...BASE_CONFIG,
    listenPort: await freePort(),
    upstream: "http://user:pass@127.0.0.1:3425",
    settingsPath: path.join(root, "missing.json"),
    logPath: path.join(root, "proxy.log"),
  }));
  const child = spawn(process.execPath, [path.join(root, "proxy.js")], { cwd: root, stdio: "ignore" });
  const [code] = await once(child, "exit");
  assert.notEqual(code, 0);
  fs.rmSync(root, { recursive: true, force: true });
});

test("unknown paths consume rate limits and rate-limited logs are sampled and truncated", async (t) => {
  const f = await createFixture(t, {
    rateLimit: { windowMs: 600, maxRequests: 3, globalMaxRequests: 5, authFailMax: 100 },
  });
  assert.equal((await f.request("/not-found")).status, 404);
  assert.equal((await f.request("/still-not-found")).status, 404);
  assert.equal((await f.request("/v1/models")).status, 200);
  for (let i = 0; i < 30; i++) {
    assert.equal((await f.request(`/not-found/${"a".repeat(3000)}`)).status, 429);
  }
  await sleep(40);
  const logs = fs.readFileSync(f.logPath, "utf8");
  const sampled = (logs.match(/DENY rate limited/g) || []).length;
  assert.ok(sampled >= 1 && sampled <= 10, `unexpected sampled log count ${sampled}`);
  assert.ok(logs.includes("further rate-limit denials are suppressed"));
  assert.equal(logs.includes("a".repeat(3000)), false);
  assert.ok(logs.split("\n").every((line) => line.length < 12000));
});

test("global limit covers callers with distinct edge identities", async (t) => {
  const f = await createFixture(t, {
    rateLimit: { windowMs: 600, maxRequests: 100, globalMaxRequests: 5, authFailMax: 100 },
  });
  for (let i = 1; i <= 5; i++) {
    assert.equal((await f.request("/missing", { headers: { "cf-connecting-ip": `203.0.113.${i}` } })).status, 404);
  }
  assert.equal(
    (await f.request("/missing", { headers: { "cf-connecting-ip": "203.0.113.6" } })).status,
    429,
  );
});

test("encoded colons, semicolons and path parameters are rejected without upstream access", async (t) => {
  const f = await createFixture(t);
  for (const url of [
    "/v1beta/models/foo%3AgenerateContent",
    "/v1beta/models/foo%3agenerateContent",
    "/v1beta/models/foo%3Bbar",
    "/v1/models/..;/magpie/limit",
    "/v1/models/foo;bar",
  ]) {
    assert.equal((await f.request(url, { method: "POST" })).status, 404, url);
  }
  assert.equal(f.requests.length, 0);
});

test("content-length/chunked limits and late upstream responses do not kill the proxy", async (t) => {
  const f = await createFixture(t, { maxBodyBytes: 16 });
  f.state.onRequest = (_req, res) => {
    f.state.onRequestCalls = (f.state.onRequestCalls || 0) + 1;
    setTimeout(() => {
      f.state.lateResponseAttempts = (f.state.lateResponseAttempts || 0) + 1;
      res.writeHead(200, { "content-type": "application/json" });
      res.end("{}");
    }, 300);
  };
  f.state.handler = async () => {};
  const url = "/v1/chat/completions";
  assert.equal((await f.request(url, { method: "POST", body: "x".repeat(17) })).status, 413);
  const chunked = await f.request(url, {
    method: "POST",
    chunked: true,
    chunks: ["x", "x".repeat(64)],
    chunkDelayMs: 100,
  });
  assert.equal(chunked.status, 413);
  await sleep(450);
  assert.equal(f.child.exitCode, null);
  assert.ok(f.state.onRequestCalls >= 1, "upstream never received the oversized request");
  assert.ok(f.state.lateResponseAttempts >= 1, "late upstream response was not exercised");
  f.state.onRequest = null;
  f.state.handler = null;
  assert.equal((await f.request(url, { method: "POST", body: "x".repeat(16) })).status, 200);
  const logs = fs.readFileSync(f.logPath, "utf8");
  assert.equal(logs.includes("ERR_HTTP_HEADERS_SENT"), false);
  assert.equal(logs.includes("FATAL"), false);
});

test("production body limit is exactly 55 MiB with one-byte overflow rejected", async (t) => {
  const source = fs.readFileSync(path.join(ROOT, "proxy.js"), "utf8");
  assert.match(source, /cfg\.maxBodyBytes \|\| 55 \* 1024 \* 1024/);
  const f = await createFixture(t);
  const exact = 55 * 1024 * 1024;
  assert.equal(f.config.maxBodyBytes, 57671680);
  assert.equal(f.config.maxBodyBytes, exact);
  const accepted = await f.request("/v1/chat/completions", {
    method: "POST",
    body: Buffer.alloc(exact, 120),
  });
  assert.equal(accepted.status, 200);
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].body.length, exact);
  const overflow = await f.request("/v1/chat/completions", {
    method: "POST",
    headers: { "content-length": String(exact + 1) },
  });
  assert.equal(overflow.status, 413);
  assert.equal(f.requests.length, 1);
});

test("SSE remains streamed and a stalled upstream returns 504 without poisoning later calls", async (t) => {
  const f = await createFixture(t, { upstreamTimeoutMs: 150 });
  f.state.handler = async (record, _req, res) => {
    if (record.url.includes("mode=sse")) {
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write('data: {"text":"PO"}\n\n');
      await sleep(60);
      res.end('data: {"text":"NG"}\n\n');
      return;
    }
    if (record.url.includes("mode=timeout")) return;
    res.end("{}");
  };
  const chunks = [];
  const sse = await f.request("/v1/chat/completions?mode=sse", {
    method: "POST",
    body: "{}",
    onChunk: (chunk) => chunks.push({ at: Date.now(), text: chunk.toString() }),
  });
  assert.equal(sse.status, 200);
  assert.ok(chunks.length >= 2);
  assert.equal(sse.headers["cache-control"], "no-cache, no-transform");
  assert.equal((await f.request("/v1/chat/completions?mode=timeout", { method: "POST", body: "{}" })).status, 504);
  assert.equal((await f.request("/v1/chat/completions", { method: "POST", body: "{}" })).status, 200);
});

test("a slow chunked upload is unpiped when the upstream idle timeout fires", async (t) => {
  const f = await createFixture(t, { upstreamTimeoutMs: 100 });
  f.state.handler = async (record, _req, res) => {
    if (record.url.includes("mode=timeout")) return;
    res.end("{}");
  };
  const timedOut = await f.request("/v1/chat/completions?mode=timeout", {
    method: "POST",
    chunked: true,
    chunks: ["first", "second"],
    chunkDelayMs: 250,
  });
  assert.equal(timedOut.status, 504);
  await sleep(300);
  assert.equal(f.child.exitCode, null);
  assert.equal((await f.request("/v1/chat/completions", { method: "POST", body: "{}" })).status, 200);
  const logs = fs.readFileSync(f.logPath, "utf8");
  assert.equal(logs.includes("FATAL"), false);
});

test("upstream stop/recovery preserves the proxy and response hop headers are stripped", async (t) => {
  const f = await createFixture(t);
  await closeServer(f.upstream);
  assert.equal((await f.request("/v1/models")).status, 502);
  await listen(f.upstream, f.upstreamPort);
  const pid = f.child.pid;
  f.state.handler = (_record, _req, res) => {
    res.writeHead(200, { connection: "x-response-hop", "x-response-hop": "secret" });
    res.end("ok");
  };
  const response = await f.request("/v1/models");
  assert.equal(response.status, 200);
  assert.equal(response.headers["x-response-hop"], undefined);
  assert.equal(f.child.pid, pid);
  assert.equal(f.child.exitCode, null);
});

test("only the exact direct watchdog probe is quiet and it still consumes auth failures", async (t) => {
  const f = await createFixture(t);
  const probeHeaders = {
    authorization: "Bearer definitely-not-the-key",
    "user-agent": "magpie-public-supervisor-healthcheck",
  };
  assert.equal((await f.request("/v1/models", { headers: probeHeaders })).status, 401);
  await sleep(30);
  let logs = fs.readFileSync(f.logPath, "utf8");
  assert.equal(logs.includes("DENY bad key"), false);
  assert.equal((await f.request("/v1/models", {
    headers: { ...probeHeaders, "cf-connecting-ip": "203.0.113.99" },
  })).status, 401);
  await sleep(30);
  logs = fs.readFileSync(f.logPath, "utf8");
  assert.equal(logs.includes("DENY bad key 203.0.113.99"), true);
  for (let i = 0; i < 19; i++) {
    assert.equal((await f.request("/v1/models", { headers: probeHeaders })).status, 401);
  }
  assert.equal((await f.request("/v1/models", { headers: probeHeaders })).status, 429);
});

test("size-based proxy log rotation retains one backup", async (t) => {
  const f = await createFixture(t, { maxLogBytes: 1024 });
  for (let i = 0; i < 15; i++) await f.request(`/missing/${i}`);
  await sleep(80);
  assert.equal(fs.existsSync(`${f.logPath}.1`), true);
});

test("synchronous fatal logs also pass through size-based rotation", async (t) => {
  const f = await createFixture(t, { maxLogBytes: 1 });
  const second = spawn(process.execPath, [path.join(f.root, "proxy.js")], {
    cwd: f.root,
    stdio: "ignore",
    windowsHide: true,
  });
  const [code] = await once(second, "exit");
  assert.equal(code, 1);
  await sleep(30);
  const backup = fs.readFileSync(`${f.logPath}.1`, "utf8");
  assert.ok(backup.includes("FATAL server error"));
  assert.ok(backup.includes("EADDRINUSE"));
});
