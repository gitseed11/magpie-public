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
const os = require("node:os");
const { URL } = require("node:url");

const HERE = __dirname;
const CONFIG_PATH = path.join(HERE, "config.json");

function expandEnvironmentVariables(value) {
  return String(value).replace(/%([^%]+)%/g, (whole, name) => process.env[name] ?? whole);
}

function loadConfig() {
  const raw = fs.readFileSync(CONFIG_PATH, "utf8");
  const cfg = JSON.parse(raw.replace(/^\uFEFF/, ""));
  const rateLimit = cfg.rateLimit || {};
  return {
    listenHost: cfg.listenHost || "127.0.0.1",
    listenPort: Number(cfg.listenPort || 8790),
    upstream: cfg.upstream || "http://127.0.0.1:3425",
    // Where Magpie stores its settings (and therefore its auto-generated lanKey).
    settingsPath:
      cfg.settingsPath
      ? expandEnvironmentVariables(cfg.settingsPath)
      : path.join(os.homedir(), ".config", "magpie", "settings.json"),
    lanKeyCacheMs: Number(cfg.lanKeyCacheMs || 5000),
    lanKeyMaxStaleMs: Number(cfg.lanKeyMaxStaleMs || 300000),
    lanKeyRetryMs: Number(cfg.lanKeyRetryMs || 2000),
    // Caller identity handed to Magpie so the public key never lands in usage logs.
    callerAgent: cfg.callerAgent || "magpie-public",
    allowedRoutes: cfg.allowedRoutes || [],
    rateLimit: {
      windowMs: Number(rateLimit.windowMs || 60000),
      maxRequests: Number(rateLimit.maxRequests || 600),
      globalMaxRequests: Number(rateLimit.globalMaxRequests || 1800),
      authFailMax: Number(rateLimit.authFailMax || 20),
    },
    maxBodyBytes: Number(cfg.maxBodyBytes || 55 * 1024 * 1024),
    upstreamTimeoutMs: Number(cfg.upstreamTimeoutMs || 600000),
    maxLogBytes: Number(cfg.maxLogBytes || 8 * 1024 * 1024),
    logPath: cfg.logPath || path.join(HERE, "logs", "proxy.log"),
  };
}

const cfg = loadConfig();

function positiveNumber(value, name) {
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a positive finite number`);
  }
  return value;
}

positiveNumber(cfg.listenPort, "listenPort");
// Range and integrality are checked here too: without this, an out-of-range or
// fractional port survives startup validation and dies later as an uncaught
// RangeError from server.listen. common.ps1 enforces the same rule, so a direct
// `node proxy.js` start must not accept a config the control scripts reject.
if (!Number.isInteger(cfg.listenPort) || cfg.listenPort > 65535) {
  throw new Error("listenPort must be an integer between 1 and 65535");
}
positiveNumber(cfg.lanKeyCacheMs, "lanKeyCacheMs");
positiveNumber(cfg.lanKeyMaxStaleMs, "lanKeyMaxStaleMs");
positiveNumber(cfg.lanKeyRetryMs, "lanKeyRetryMs");
positiveNumber(cfg.maxBodyBytes, "maxBodyBytes");
positiveNumber(cfg.upstreamTimeoutMs, "upstreamTimeoutMs");
positiveNumber(cfg.maxLogBytes, "maxLogBytes");
for (const [name, value] of Object.entries(cfg.rateLimit)) positiveNumber(value, `rateLimit.${name}`);

if (cfg.listenHost !== "127.0.0.1" && cfg.listenHost !== "::1") {
  throw new Error("listenHost must be an explicit loopback address (127.0.0.1 or ::1)");
}
if (!Array.isArray(cfg.allowedRoutes) || cfg.allowedRoutes.length === 0) {
  throw new Error("allowedRoutes must be a non-empty array");
}
for (const route of cfg.allowedRoutes) {
  if (
    !route ||
    typeof route.path !== "string" ||
    !route.path.startsWith("/") ||
    !Array.isArray(route.methods) ||
    route.methods.length === 0 ||
    route.methods.some((m) => typeof m !== "string" || !/^[A-Z]+$/.test(m))
  ) {
    throw new Error("each allowed route needs a path and an uppercase methods array");
  }
}

/* ---------------------------------------------------------------- logging */

/*
 * Size-based rotation. Request traffic produces log lines, so without a cap
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
  let rotated = false;
  try {
    logStream.end();
    fs.renameSync(cfg.logPath, cfg.logPath + ".1");
    rotated = true;
  } catch {
    /* Best effort only. Keep the real size so a failed rotation is not hidden. */
  }
  logStream = makeLogStream();
  if (rotated) {
    logBytes = 0;
  } else {
    try {
      logBytes = fs.statSync(cfg.logPath).size;
    } catch {
      /* If the path is unavailable, keep the previous accounting. */
    }
  }
}

function log(...parts) {
  // Strip CR/LF and other control characters: request paths reach this function
  // and an unauthenticated caller could otherwise forge extra log lines.
  const clean = parts.map((p) => String(p).replace(/[\u0000-\u001f\u007f]/g, "?").slice(0, 2048));
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
  const clean = parts.map((p) => String(p).replace(/[\u0000-\u001f\u007f]/g, "?").slice(0, 2048));
  const line = `${new Date().toISOString()} ${clean.join(" ")}\n`;
  try {
    fs.appendFileSync(cfg.logPath, line);
    logBytes += Buffer.byteLength(line);
    rotateIfNeeded();
  } catch {
    try { process.stderr.write(line); } catch {}
  }
}

/* ------------------------------------------------------------- lanKey read */

let keyCache = { value: null, readAt: 0, retryAt: 0, lastLogged: null };

function cachedLanKey(now) {
  if (keyCache.value && now - keyCache.readAt <= cfg.lanKeyMaxStaleMs) {
    return keyCache.value;
  }
  return null;
}

/**
 * Read the Magpie-generated lanKey from settings.json.
 *
 * Magpie rewrites settings.json on its own schedule, so a read can land on a
 * half-written file. A short negative cache avoids blocking every request,
 * while the independent stale limit makes deletion/corruption fail closed.
 */
function readLanKey(force) {
  const now = Date.now();
  const cached = cachedLanKey(now);
  if (!force && cached && now - keyCache.readAt < cfg.lanKeyCacheMs) {
    return cached;
  }
  if (!force && now < keyCache.retryAt) return cached;

  try {
    const text = fs.readFileSync(cfg.settingsPath, "utf8");
    const parsed = JSON.parse(text.replace(/^\uFEFF/, ""));
    const key = typeof parsed.lanKey === "string" ? parsed.lanKey.trim() : "";
    if (key) {
      if (keyCache.value && keyCache.value !== key && keyCache.lastLogged !== key) {
        log("WARN lanKey changed; public clients must switch to the new key");
        keyCache.lastLogged = key;
      }
      keyCache = { value: key, readAt: now, retryAt: 0, lastLogged: keyCache.lastLogged };
      return key;
    }
    log("WARN settings.json has no lanKey");
  } catch (err) {
    log("WARN cannot read lanKey:", err.code || err.message);
  }

  keyCache.retryAt = now + cfg.lanKeyRetryMs;
  return cachedLanKey(now);
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

/* ------------------------------------------------------ route + method matching */

function routeAllowed(pathname, method) {
  for (const rule of cfg.allowedRoutes) {
    if (!rule.methods.includes(method)) continue;
    const star = rule.path.indexOf("*");
    if (star === -1) {
      if (rule.path === pathname) return true;
      continue;
    }

    // A single '*' covers model IDs, including IDs containing '/'. Requiring a
    // non-empty capture prevents a bare action/prefix from becoming a model.
    if (rule.path.indexOf("*", star + 1) !== -1) continue;
    const prefix = rule.path.slice(0, star);
    const suffix = rule.path.slice(star + 1);
    if (
      pathname.length > prefix.length + suffix.length &&
      pathname.startsWith(prefix) &&
      pathname.endsWith(suffix)
    ) {
      const capture = pathname.slice(prefix.length, pathname.length - suffix.length);
      // A Gemini colon suffix is an RPC action, not part of the model resource.
      // GET/HEAD may query models only; actions must match an explicit POST rule.
      if (rule.path === "/v1beta/models/*" && capture.includes(":")) continue;
      return true;
    }
  }
  return false;
}

/* -------------------------------------------------------------- rate limit */

const buckets = new Map();
const globalBucket = { start: Date.now(), count: 0 };
// Anonymous traffic (unknown paths, bad keys, rejected bodies) must never
// consume the budget that protects real inference calls: a caller sending a
// handful of requests per second could otherwise block every customer. It
// still gets its own, much coarser ceiling so probing floods cannot turn the
// proxy into a free log/CPU amplifier.
const ANON_GLOBAL_MULTIPLIER = 10;
const anonGlobalBucket = { start: Date.now(), count: 0 };
const rateLimitLogBucket = { start: Date.now(), count: 0 };

function logRateLimited(...parts) {
  const now = Date.now();
  if (now - rateLimitLogBucket.start >= cfg.rateLimit.windowMs) {
    rateLimitLogBucket.start = now;
    rateLimitLogBucket.count = 0;
  }
  rateLimitLogBucket.count += 1;
  if (rateLimitLogBucket.count <= 10) log(...parts);
  if (rateLimitLogBucket.count === 11) {
    log("WARN further rate-limit denials are suppressed until the next window");
  }
}

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
 * Per-caller limiting, applied to every request before any path or key work so
 * that one identity cannot monopolise the process regardless of the outcome.
 *
 * The global ceilings are charged separately: rejections to anonGlobalBucket
 * (anonRateLimited) and successful authentication to globalBucket
 * (authenticatedRateLimited). Keeping them apart is what stops anonymous
 * traffic from blocking real clients.
 */
function rateLimited(id) {
  let b = buckets.get(id);
  if (!b) {
    b = { start: Date.now(), count: 0 };
    buckets.set(id, b);
  }
  return bucketExceeded(b, cfg.rateLimit.maxRequests);
}

/**
 * Charge and enforce the anonymous ceiling at the moment a request is rejected
 * (unknown path, bad key, oversized body). Returns true when the 429 was sent.
 *
 * Authenticated requests never touch this bucket, so a flood cannot starve them
 * however many identities it rotates through. The ceiling still bounds log/CPU
 * amplification from probing.
 */
function anonRateLimited(res, caller, method, pathname) {
  if (!bucketExceeded(anonGlobalBucket, cfg.rateLimit.globalMaxRequests * ANON_GLOBAL_MULTIPLIER)) {
    return false;
  }
  logRateLimited("DENY rate limited", caller, method, pathname);
  res.setHeader("retry-after", String(Math.ceil(cfg.rateLimit.windowMs / 1000)));
  sendJson(res, 429, { error: { message: "rate limit exceeded", type: "rate_limit_error" } });
  return true;
}

/** Global ceiling for requests that already presented the correct key. */
function authenticatedRateLimited() {
  return bucketExceeded(globalBucket, cfg.rateLimit.globalMaxRequests);
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
  if (now - anonGlobalBucket.start >= cfg.rateLimit.windowMs) {
    anonGlobalBucket.start = now;
    anonGlobalBucket.count = 0;
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
if (upstreamUrl.protocol !== "http:" && upstreamUrl.protocol !== "https:") {
  throw new Error("upstream must use http or https");
}
if (upstreamUrl.hostname !== "127.0.0.1" && upstreamUrl.hostname !== "[::1]") {
  throw new Error("upstream must use an explicit loopback address");
}
if (
  upstreamUrl.pathname !== "/" ||
  upstreamUrl.search ||
  upstreamUrl.hash ||
  upstreamUrl.username ||
  upstreamUrl.password
) {
  throw new Error("upstream must be a root URL without path/query/user info/hash");
}
const upstreamLib = upstreamUrl.protocol === "https:" ? https : http;

const HOP_BY_HOP_HEADERS = [
  "connection",
  "keep-alive",
  "proxy-connection",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
];

const UNTRUSTED_REQUEST_HEADERS = new Set([
  "forwarded",
  "true-client-ip",
  "x-client-ip",
  "x-cluster-client-ip",
  "x-originating-ip",
  "x-original-url",
  "x-rewrite-url",
  "x-http-method-override",
  "api-key",
]);

function stripHopByHopHeaders(headers) {
  // RFC 7230 section 6.1: every header nominated by Connection is hop-by-hop,
  // not just the fixed examples. Apply this before restoring our own Host/auth.
  const connection = headers.connection;
  if (typeof connection === "string") {
    for (const token of connection.split(",")) {
      const name = token.trim().toLowerCase();
      if (name) delete headers[name];
    }
  }
  for (const name of HOP_BY_HOP_HEADERS) delete headers[name];
}

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
  if (peer !== "::1" && !/^(127\.|::ffff:127\.)/.test(peer)) {
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

  // Charge the per-caller budget for every parseable request, before any
  // path-based rejection or logging. Global ceilings are charged later: at the
  // rejection point (anonymous) or after the key check (authenticated).
  if (rateLimited(caller)) {
    logRateLimited("DENY rate limited", caller, req.method, pathname);
    res.setHeader("retry-after", String(Math.ceil(cfg.rateLimit.windowMs / 1000)));
    sendJson(res, 429, {
      error: { message: "rate limit exceeded", type: "rate_limit_error" },
    });
    return;
  }

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
    /(^|\/)\.\.(?:;|\/|$)/.test(rawPath) ||
    /%2e|%2f|%5c|%00|%3a|%3b/i.test(rawPath) ||
    rawPath.includes("\\") ||
    rawPath.includes(";") ||
    rawPath.includes("//")
  ) {
    if (anonRateLimited(res, caller, req.method, pathname)) return;
    log("DENY suspicious path", caller, req.method, rawPath);
    sendJson(res, 404, { error: { message: "not found", type: "invalid_request_error" } });
    return;
  }

  // Management surface is never reachable from the public side.
  if (pathname.startsWith("/v1/magpie") || pathname.startsWith("/api")) {
    if (anonRateLimited(res, caller, req.method, pathname)) return;
    log("DENY management path", caller, req.method, pathname);
    sendJson(res, 404, { error: { message: "not found", type: "invalid_request_error" } });
    return;
  }

  if (!routeAllowed(pathname, req.method)) {
    if (anonRateLimited(res, caller, req.method, pathname)) return;
    log("DENY path not allowed", caller, req.method, pathname);
    sendJson(res, 404, { error: { message: "not found", type: "invalid_request_error" } });
    return;
  }

  // The per-caller budget is already charged; this throttle adds a hard lockout
  // for callers that keep presenting wrong keys.
  if (authBlocked(caller)) {
    if (anonRateLimited(res, caller, req.method, pathname)) return;
    logRateLimited("DENY auth throttled", caller, req.method, pathname);
    res.setHeader("retry-after", String(Math.ceil(cfg.rateLimit.windowMs / 1000)));
    sendJson(res, 429, {
      error: { message: "too many failed attempts", type: "rate_limit_error" },
    });
    return;
  }

  // Reject oversized bodies before streaming them upstream.
  const declaredLen = Number(req.headers["content-length"] || 0);
  if (declaredLen && declaredLen > cfg.maxBodyBytes) {
    if (anonRateLimited(res, caller, req.method, pathname)) return;
    log("DENY body too large", caller, declaredLen);
    sendJson(res, 413, {
      error: { message: "request body too large", type: "invalid_request_error" },
    });
    return;
  }

  const expected = readLanKey(false);
  if (!expected) {
    // This branch is reachable without any credential, so it is charged to the
    // anonymous ceiling like every other rejection: otherwise a caller rotating
    // egress IPs during a key outage is bounded only per-IP and each request
    // still costs a full settings read. The 503 itself is preserved because the
    // watchdog maps it to key-unavailable.
    if (anonRateLimited(res, caller, req.method, pathname)) return;
    logRateLimited("ERROR no lanKey available; refusing request");
    sendJson(res, 503, {
      error: { message: "gateway key unavailable", type: "server_error" },
    });
    return;
  }

  const given = presentedKey(req);
  if (!given || !timingSafeEqualStr(given, expected)) {
    // Only a request that actually presented a key counts as a brute-force
    // attempt. Counting missing keys would let any web page lock out a victim's
    // IP with a handful of cross-site no-cors requests (no custom header means
    // no preflight), and would punish clients that are merely misconfigured.
    // The exact direct-loopback watchdog request is quiet in this log; a public
    // caller cannot suppress logs merely by forging its User-Agent because
    // Cloudflare supplies CF-Connecting-IP.
    if (given) recordAuthFail(caller);
    if (anonRateLimited(res, caller, req.method, pathname)) return;
    // Must stay in sync with common.ps1 Get-MagpieProxyHealth (token + UA).
    const isProbe =
      !req.headers["cf-connecting-ip"] &&
      req.method === "GET" &&
      pathname === "/v1/models" &&
      given === "definitely-not-the-key" &&
      req.headers["user-agent"] === "magpie-public-supervisor-healthcheck";
    if (isProbe) {
      res.setHeader("www-authenticate", 'Bearer realm="magpie"');
      sendJson(res, 401, {
        error: { message: "invalid api key", type: "invalid_request_error" },
      });
      return;
    }
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

  // The key is valid from here on: this caller is no longer a brute-force
  // suspect, and the request is charged to the authenticated global budget
  // instead of the anonymous one.
  authFails.delete(caller);
  if (authenticatedRateLimited()) {
    logRateLimited("DENY authenticated rate limited", caller, req.method, pathname);
    res.setHeader("retry-after", String(Math.ceil(cfg.rateLimit.windowMs / 1000)));
    sendJson(res, 429, {
      error: { message: "rate limit exceeded", type: "rate_limit_error" },
    });
    return;
  }

  // Query keys are never credentials here and must not reach upstream URL logs.
  // Reject only after authentication so a query-only request keeps its 401 semantics.
  if (url.searchParams.has("key")) {
    log("DENY query key", caller, req.method, pathname);
    sendJson(res, 400, {
      error: {
        message: "query key is not accepted; use an authorization header",
        type: "invalid_request_error",
      },
    });
    return;
  }

  // ---- forward ------------------------------------------------------------

  const headers = { ...req.headers };
  stripHopByHopHeaders(headers);
  // Magpie's admin guard rejects non-owned Host values; present it as itself.
  headers.host = upstreamUrl.host;
  // Never leak the public key upstream; identify the caller instead.
  headers.authorization = `Bearer ${cfg.callerAgent}`;
  delete headers["x-api-key"];
  delete headers["x-goog-api-key"];
  // Let Node set fresh framing after removing the incoming transfer encoding.
  delete headers["content-length"];
  // Do not let clients dictate who they are to Magpie.
  for (const h of Object.keys(headers)) {
    if (
      h.startsWith("cf-") ||
      h.startsWith("x-forwarded") ||
      h === "x-real-ip" ||
      UNTRUSTED_REQUEST_HEADERS.has(h)
    ) {
      delete headers[h];
    }
  }

  const options = {
    protocol: upstreamUrl.protocol,
    hostname: upstreamUrl.hostname === "[::1]" ? "::1" : upstreamUrl.hostname,
    port: upstreamUrl.port || (upstreamUrl.protocol === "https:" ? 443 : 80),
    method: req.method,
    path: pathname + (url.search || ""),
    headers,
    agent: upstreamAgent,
  };

  const upstreamReq = upstreamLib.request(options, (upstreamRes) => {
    if (res.destroyed || res.writableEnded || res.headersSent) {
      // A streamed-body 413 may already be complete before a late upstream reply.
      upstreamRes.on("error", () => {});
      upstreamRes.resume();
      return;
    }
    const resHeaders = { ...upstreamRes.headers };
    stripHopByHopHeaders(resHeaders);
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
    req.unpipe(upstreamReq);
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

  // If the response finishes before the request was fully received (the
  // upstream rejected early), Node stops feeding this request body to us, so
  // the rest of the upload can never be drained. Close the connection instead
  // of leaving the client blocked until Node's requestTimeout; nothing is
  // forwarded here. A fully received request keeps the connection reusable.
  res.on("finish", () => {
    if (!req.complete && !req.destroyed) req.destroy();
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
  log(
    `allowed routes: ${cfg.allowedRoutes
      .map((route) => `${route.methods.join("|")} ${route.path}`)
      .join(", ")}`,
  );
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
