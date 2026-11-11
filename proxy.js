#!/usr/bin/env node
/*
 * Magpie public API gateway (authenticating reverse proxy).
 *
 * Why this exists
 * ---------------
 * Magpie listens on 127.0.0.1:3425 only, and it deliberately accepts requests
 * that arrive from loopback without a gateway key (that is how local agents
 * such as Codex / Claude Code / ZCode call it). A Cloudflare tunnel connects
 * to Magpie *from loopback*, so pointing a tunnel straight at 3425 would
 * publish an unauthenticated inference API to the internet.
 *
 * This proxy is the missing gate: it listens on loopback (so only the local
 * cloudflared process can reach it), requires the Magpie-generated lanKey on
 * every request, and only forwards the inference routes. The management
 * surface (/v1/magpie/**, /api/**) is never forwarded, so it stays local-only.
 *
 * No dependencies: Node core modules only.
 */

"use strict";

const http = require("node:http");
const https = require("node:https");
const fs = require("node:fs");
const path = require("node:path");
const { URL } = require("node:url");

const HERE = __dirname;
const CONFIG_PATH = path.join(HERE, "config.json");

function loadConfig() {
  const raw = fs.readFileSync(CONFIG_PATH, "utf8");
  const cfg = JSON.parse(raw);
  const rateLimit = cfg.rateLimit || {};
  return {
    listenHost: cfg.listenHost || "127.0.0.1",
    listenPort: Number(cfg.listenPort || 8790),
    upstream: cfg.upstream || "http://127.0.0.1:3425",
    // Where Magpie stores its settings (and therefore its auto-generated lanKey).
    settingsPath: cfg.settingsPath,
    lanKeyCacheMs: Number(cfg.lanKeyCacheMs || 5000),
    // Caller identity handed to Magpie so the public key never lands in usage logs.
    callerAgent: cfg.callerAgent || "magpie-public",
    allowedPaths: cfg.allowedPaths || [],
    rateLimit: {
      windowMs: Number(rateLimit.windowMs || 60000),
      maxRequests: Number(rateLimit.maxRequests || 600),
      globalMaxRequests: Number(rateLimit.globalMaxRequests || 1800),
      authFailMax: Number(rateLimit.authFailMax || 20),
    },
    maxBodyBytes: Number(cfg.maxBodyBytes || 32 * 1024 * 1024),
    upstreamTimeoutMs: Number(cfg.upstreamTimeoutMs || 600000),
    maxLogBytes: Number(cfg.maxLogBytes || 8 * 1024 * 1024),
    logPath: cfg.logPath || path.join(HERE, "logs", "proxy.log"),
  };
}

const cfg = loadConfig();

/* ---------------------------------------------------------------- logging */

/*
 * Size-based rotation. The proxy writes one line per request, so without a cap
 * the file grows without bound and can eventually fill the disk. When the
 * active file passes maxLogBytes it is renamed to .1 (replacing any older .1)
 * and a fresh file is opened.
 */
const MAX_LOG_BYTES = Number(cfg.maxLogBytes || 8 * 1024 * 1024);
let logBytes = 0;
let logStream = openLog();

function makeLogStream() {
  const s = fs.createWriteStream(cfg.logPath, { flags: "a" });
  // A failing log sink (disk full, folder removed, permissions changed) must
  // never take the gateway down; an unhandled 'error' event would throw.
  s.on("error", () => {});
  return s;
}

function openLog() {
  try {
    const st = fs.statSync(cfg.logPath);
    logBytes = st.size;
  } catch {
    logBytes = 0;
  }
  return makeLogStream();
}

function rotateIfNeeded() {
  if (logBytes < MAX_LOG_BYTES) return;
  try {
    logStream.end();
    fs.renameSync(cfg.logPath, cfg.logPath + ".1");
  } catch {
    /* rotation is best effort; keep appending rather than losing the handle */
  }
  logStream = makeLogStream();
  logBytes = 0;
}

function log(...parts) {
  // Strip CR/LF and other control characters: request paths reach this function
  // and an unauthenticated caller could otherwise forge extra log lines.
  const clean = parts.map((p) => String(p).replace(/[\u0000-\u001f\u007f]/g, "?"));
  const line = `${new Date().toISOString()} ${clean.join(" ")}\n`;
  logBytes += Buffer.byteLength(line);
  logStream.write(line);
  rotateIfNeeded();
}

/*
 * Synchronous variant for the paths that call process.exit() immediately.
 * logStream writes are asynchronous, so a plain log() followed by exit can be
 * lost entirely -- exactly when the message matters most (port already in use,
 * uncaught exception).
 */
function logSync(...parts) {
  const clean = parts.map((p) => String(p).replace(/[\u0000-\u001f\u007f]/g, "?"));
  const line = `${new Date().toISOString()} ${clean.join(" ")}\n`;
  try {
    fs.appendFileSync(cfg.logPath, line);
    logBytes += Buffer.byteLength(line);
  } catch {
    try { process.stderr.write(line); } catch {}
  }
}

/* ------------------------------------------------------------- lanKey read */

let keyCache = { value: null, readAt: 0, lastLogged: null };

/**
 * Read the Magpie-generated lanKey from settings.json.
 *
 * Magpie rewrites settings.json on its own schedule, so a read can land on a
 * half-written file. We retry briefly and fall back to the cached value rather
 * than failing requests.
 */
function readLanKey(force) {
  const now = Date.now();
  if (!force && keyCache.value && now - keyCache.readAt < cfg.lanKeyCacheMs) {
    return keyCache.value;
  }

  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const text = fs.readFileSync(cfg.settingsPath, "utf8");
      const parsed = JSON.parse(text);
      const key = typeof parsed.lanKey === "string" ? parsed.lanKey.trim() : "";
      if (key) {
        if (keyCache.value && keyCache.value !== key && keyCache.lastLogged !== key) {
          log("WARN lanKey changed; public clients must switch to the new key");
          keyCache.lastLogged = key;
        }
        keyCache = { value: key, readAt: now, lastLogged: keyCache.lastLogged };
        return key;
      }
      log("WARN settings.json has no lanKey");
      break;
    } catch (err) {
      if (attempt === 2) {
        log("WARN cannot read lanKey:", err.code || err.message);
      } else {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
      }
    }
  }

  // Stale-but-known key beats rejecting every caller while Magpie rewrites.
  return keyCache.value;
}

/* --------------------------------------------------------- key comparison */

function timingSafeEqualStr(a, b) {
  const ab = Buffer.from(String(a), "utf8");
  const bb = Buffer.from(String(b), "utf8");
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

/** Pull the presented key from any supported header form. */
function presentedKey(req) {
  const auth = req.headers["authorization"];
  if (typeof auth === "string") {
    const m = /^Bearer\s+(.+)$/i.exec(auth.trim());
    if (m) return m[1].trim();
  }
  const xApiKey = req.headers["x-api-key"];
  if (typeof xApiKey === "string" && xApiKey.trim()) return xApiKey.trim();
  // Google GenAI SDKs send the key in this header (Gemini compatibility).
  // Accepting it keeps the /v1beta/models* routes usable by stock SDKs; it is
  // still an exact, timing-safe comparison against lanKey.
  const googKey = req.headers["x-goog-api-key"];
  if (typeof googKey === "string" && googKey.trim()) return googKey.trim();
  return "";
}

/* ----------------------------------------------------------- path matching */

function pathAllowed(pathname) {
  for (const rule of cfg.allowedPaths) {
    if (rule === pathname) return true;
    if (rule.endsWith("/*")) {
      const prefix = rule.slice(0, -1); // keep trailing slash
      if (pathname.startsWith(prefix)) return true;
    }
  }
  return false;
}

/* -------------------------------------------------------------- rate limit */

const buckets = new Map();
const globalBucket = { start: Date.now(), count: 0 };

/**
 * Per-caller identity for rate limiting.
 *
 * SECURITY: only headers the Cloudflare edge itself writes may be trusted.
 * X-Forwarded-For is attacker-controlled on a public endpoint -- trusting it
 * lets any caller mint unlimited identities and bypass the limit entirely
 * (verified during audit). So we read CF-Connecting-IP only.
 *
 * Direct loopback use (no edge in front) falls back to the socket peer, which
 * is 127.0.0.1 and therefore shares one bucket -- coarse but not forgeable.
 */
function callerId(req, peer) {
  const cf = req.headers["cf-connecting-ip"];
  if (typeof cf === "string" && cf.trim()) return cf.trim();
  return peer;
}

function bucketExceeded(bucket, limit) {
  const now = Date.now();
  if (now - bucket.start >= cfg.rateLimit.windowMs) {
    bucket.start = now;
    bucket.count = 1;
    return false;
  }
  bucket.count += 1;
  return bucket.count > limit;
}

/**
 * Two-tier limiting: a per-caller bucket, plus a global ceiling so that one
 * caller cannot exhaust the machine's capacity for everyone else.
 */
function rateLimited(id) {
  // Global ceiling first: it is the backstop when identities are somehow
  // still per-request (e.g. many real client IPs).
  if (bucketExceeded(globalBucket, cfg.rateLimit.globalMaxRequests)) return true;

  let b = buckets.get(id);
  if (!b) {
    b = { start: Date.now(), count: 0 };
    buckets.set(id, b);
  }
  return bucketExceeded(b, cfg.rateLimit.maxRequests);
}

/**
 * Failed-authentication throttle.
 *
 * Auth failures are counted separately and checked BEFORE the key comparison,
 * so brute-forcing costs the attacker a hard lockout instead of unlimited
 * free attempts (and unlimited log writes).
 */
const authFails = new Map();
const AUTH_FAIL_LIMIT = cfg.rateLimit.authFailMax || 20;

function authBlocked(id) {
  const f = authFails.get(id);
  if (!f) return false;
  if (Date.now() - f.start >= cfg.rateLimit.windowMs) {
    authFails.delete(id);
    return false;
  }
  return f.count >= AUTH_FAIL_LIMIT;
}

function recordAuthFail(id) {
  const now = Date.now();
  const f = authFails.get(id);
  if (!f || now - f.start >= cfg.rateLimit.windowMs) {
    authFails.set(id, { start: now, count: 1 });
  } else {
    f.count += 1;
  }
}

setInterval(() => {
  const now = Date.now();
  for (const [ip, b] of buckets) {
    if (now - b.start >= cfg.rateLimit.windowMs) buckets.delete(ip);
  }
  for (const [ip, f] of authFails) {
    if (now - f.start >= cfg.rateLimit.windowMs) authFails.delete(ip);
  }
  if (now - globalBucket.start >= cfg.rateLimit.windowMs) {
    globalBucket.start = now;
    globalBucket.count = 0;
  }
}, 60000).unref();

/* --------------------------------------------------------------- responses */

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  res.end(body);
}

/* ------------------------------------------------------------ proxy target */

const upstreamUrl = new URL(cfg.upstream);
const upstreamLib = upstreamUrl.protocol === "https:" ? https : http;

/*
 * No keep-alive pool on purpose.
 *
 * Magpie may be started, restarted, or stopped at any time independently of
 * this proxy. A pooled connection that Magpie closed (or that died with a
 * previous Magpie process) would be handed to the next request and fail with
 * ECONNRESET -- surfacing as a spurious 502 even though Magpie is healthy.
 *
 * Opening a fresh connection per request costs a local loopback handshake and
 * makes "Magpie started after the tunnel" work with no proxy restart.
 */
const upstreamAgent = false;

/* -------------------------------------------------------------- the server */

const server = http.createServer((req, res) => {
  const started = Date.now();
  const peer = req.socket.remoteAddress || "unknown";

  // Defense in depth: only loopback peers are legitimate here (cloudflared).
  if (!/^(127\.|::1|::ffff:127\.)/.test(peer)) {
    log("DENY non-loopback peer", peer, req.method, req.url);
    sendJson(res, 403, { error: { message: "forbidden", type: "forbidden" } });
    return;
  }

  let url;
  try {
    url = new URL(req.url, "http://localhost");
  } catch {
    sendJson(res, 400, { error: { message: "bad request", type: "invalid_request_error" } });
    return;
  }

  const pathname = url.pathname;
  const caller = callerId(req, peer);

  /*
   * Path traversal / normalization guard.
   *
   * The allow-list below is prefix based, and Node does not decode %2f, so a
   * raw "/v1/models/..%2fmagpie/limit" would otherwise be forwarded verbatim
   * and rely on Magpie's own routing to reject it. Refuse such shapes here
   * instead of trusting the upstream to keep agreeing with us.
   *
   * "//" is refused too: upstream answers it with a 307 that points at a path
   * we do not intend to expose. No legitimate client sends a double slash.
   */
  const rawPath = req.url.split("?")[0];
  if (
    /(^|\/)\.\.(\/|$)/.test(rawPath) ||
    /%2e|%2f|%5c|%00/i.test(rawPath) ||
    rawPath.includes("\\") ||
    rawPath.includes("//")
  ) {
    log("DENY suspicious path", caller, req.method, rawPath);
    sendJson(res, 404, { error: { message: "not found", type: "invalid_request_error" } });
    return;
  }

  // Management surface is never reachable from the public side.
  if (pathname.startsWith("/v1/magpie") || pathname.startsWith("/api")) {
    log("DENY management path", caller, req.method, pathname);
    sendJson(res, 404, { error: { message: "not found", type: "invalid_request_error" } });
    return;
  }

  if (!pathAllowed(pathname)) {
    log("DENY path not allowed", caller, req.method, pathname);
    sendJson(res, 404, { error: { message: "not found", type: "invalid_request_error" } });
    return;
  }

  // Rate limit before authentication, so brute force costs the caller a
  // lockout rather than unlimited free attempts.
  if (rateLimited(caller)) {
    log("DENY rate limited", caller, req.method, pathname);
    res.setHeader("retry-after", String(Math.ceil(cfg.rateLimit.windowMs / 1000)));
    sendJson(res, 429, {
      error: { message: "rate limit exceeded", type: "rate_limit_error" },
    });
    return;
  }

  // Too many recent bad keys from this caller: stop comparing entirely.
  if (authBlocked(caller)) {
    log("DENY auth throttled", caller, req.method, pathname);
    res.setHeader("retry-after", String(Math.ceil(cfg.rateLimit.windowMs / 1000)));
    sendJson(res, 429, {
      error: { message: "too many failed attempts", type: "rate_limit_error" },
    });
    return;
  }

  // Reject oversized bodies before streaming them upstream.
  const declaredLen = Number(req.headers["content-length"] || 0);
  if (declaredLen && declaredLen > cfg.maxBodyBytes) {
    log("DENY body too large", caller, declaredLen);
    sendJson(res, 413, {
      error: { message: "request body too large", type: "invalid_request_error" },
    });
    return;
  }

  const expected = readLanKey(false);
  if (!expected) {
    log("ERROR no lanKey available; refusing request");
    sendJson(res, 503, {
      error: { message: "gateway key unavailable", type: "server_error" },
    });
    return;
  }

  const given = presentedKey(req);
  if (!given || !timingSafeEqualStr(given, expected)) {
    // The supervisor's own liveness probe sends a deliberately wrong key on a
    // fixed schedule. Log it distinctly so it never looks like an attack and
    // never pollutes the auth-failure throttle.
    const isProbe =
      String(req.headers["user-agent"] || "").includes("supervisor-healthcheck");
    if (isProbe) {
      log("PROBE bad key (supervisor healthcheck)");
      res.setHeader("www-authenticate", 'Bearer realm="magpie"');
      sendJson(res, 401, {
        error: { message: "invalid api key", type: "invalid_request_error" },
      });
      return;
    }
    recordAuthFail(caller);
    log("DENY bad key", caller, req.method, pathname);
    res.setHeader("www-authenticate", 'Bearer realm="magpie"');
    sendJson(res, 401, {
      error: {
        message: "invalid api key",
        type: "invalid_request_error",
        code: "invalid_api_key",
      },
    });
    return;
  }

  // ---- forward ------------------------------------------------------------

  const headers = { ...req.headers };
  // Magpie's admin guard rejects non-owned Host values; present it as itself.
  headers.host = upstreamUrl.host;
  // Never leak the public key upstream; identify the caller instead.
  headers.authorization = `Bearer ${cfg.callerAgent}`;
  delete headers["x-api-key"];
  delete headers["x-goog-api-key"];
  // Let Node set framing; drop hop-by-hop headers.
  delete headers["content-length"];
  delete headers.connection;
  delete headers["keep-alive"];
  delete headers["proxy-connection"];
  delete headers["transfer-encoding"];
  delete headers.upgrade;
  // Do not let clients dictate who they are to Magpie.
  for (const h of Object.keys(headers)) {
    if (h.startsWith("cf-") || h.startsWith("x-forwarded") || h === "x-real-ip") {
      delete headers[h];
    }
  }

  const options = {
    protocol: upstreamUrl.protocol,
    hostname: upstreamUrl.hostname,
    port: upstreamUrl.port || (upstreamUrl.protocol === "https:" ? 443 : 80),
    method: req.method,
    path: pathname + (url.search || ""),
    headers,
    agent: upstreamAgent,
  };

  const upstreamReq = upstreamLib.request(options, (upstreamRes) => {
    const resHeaders = { ...upstreamRes.headers };
    delete resHeaders.connection;
    delete resHeaders["keep-alive"];
    delete resHeaders["transfer-encoding"];
    // SSE must not be buffered by any intermediary.
    if (String(resHeaders["content-type"] || "").includes("text/event-stream")) {
      resHeaders["cache-control"] = "no-cache, no-transform";
      resHeaders["x-accel-buffering"] = "no";
    }

    res.writeHead(upstreamRes.statusCode || 502, resHeaders);
    upstreamRes.pipe(res);

    upstreamRes.on("end", () => {
      log(
        "OK",
        caller,
        req.method,
        pathname,
        "->",
        upstreamRes.statusCode,
        `${Date.now() - started}ms`,
      );
    });
    upstreamRes.on("error", (err) => {
      log("ERROR upstream response", err.code || err.message);
      res.destroy();
    });
  });

  // Bound how long a stalled upstream or a slow client may hold a socket.
  // Model calls can be long, so this is generous; it exists to stop a
  // connection that never progresses at all.
  upstreamReq.setTimeout(cfg.upstreamTimeoutMs, () => {
    log("ERROR upstream timeout", caller, pathname);
    upstreamReq.destroy(new Error("upstream timeout"));
  });

  upstreamReq.on("error", (err) => {
    log("ERROR upstream request", pathname, err.code || err.message);
    if (!res.headersSent) {
      const timedOut = err.message === "upstream timeout";
      sendJson(res, timedOut ? 504 : 502, {
        error: {
          message: timedOut ? "upstream timeout" : "upstream unavailable",
          type: "server_error",
        },
      });
    } else if (!res.writableEnded) {
      // Only tear down a response that is still in flight. When we have
      // already written a complete reply (e.g. the 413 for an oversized
      // streamed body), destroying the socket here would reset it and the
      // client would never see the status code.
      res.destroy();
    }
  });

  // Abort upstream work if the client goes away (common with streamed chats).
  res.on("close", () => {
    if (!res.writableEnded) upstreamReq.destroy();
  });

  // Stream the body upstream, but stop if it exceeds the cap. content-length
  // was already checked; this covers chunked requests that declare nothing.
  let sent = 0;
  req.on("data", (chunk) => {
    sent += chunk.length;
    if (sent > cfg.maxBodyBytes) {
      log("DENY body too large (streamed)", caller, sent);
      upstreamReq.destroy(new Error("body too large"));
      req.unpipe(upstreamReq);
      if (!res.headersSent) {
        sendJson(res, 413, {
          error: { message: "request body too large", type: "invalid_request_error" },
        });
      }
      req.destroy();
    }
  });

  req.pipe(upstreamReq);
});

server.on("error", (err) => {
  // Most likely EADDRINUSE (another process already owns the port). Exit with
  // a clear log line instead of letting it surface as an uncaught exception.
  logSync("FATAL server error", err.code || err.message);
  process.exit(1);
});

server.on("clientError", (err, socket) => {
  try {
    socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
  } catch {
    /* ignore */
  }
});

server.keepAliveTimeout = 65000;
server.headersTimeout = 66000;

server.listen(cfg.listenPort, cfg.listenHost, () => {
  log(`listening on http://${cfg.listenHost}:${cfg.listenPort} -> ${cfg.upstream}`);
  log(`allowed paths: ${cfg.allowedPaths.join(", ")}`);
});

function shutdown(signal) {
  logSync(`received ${signal}, shutting down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
}
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("uncaughtException", (err) => {
  logSync("FATAL uncaught", err.stack || err.message);
  process.exit(1);
});
