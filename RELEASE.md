# v2.1.1 - 资源限制、Key 缓存与验证加固 / Resource limits, key caching and verification hardening

发布日期 / Release date：**2026-11-24 00:00:00 +08:00**

Tag：**v2.1.1**

[中文](#中文) · [English](#english)

---

## 中文

**magpie-public v2.1.1** 是 v2.0.0 之后的安全与可靠性维护版本：请求体上限统一为 55 MiB，缓存 Key 增加硬失效上限和失败负缓存，ingress 与路由校验进一步收紧，并加入仓库内可重复执行的 Node 与 PowerShell 回归。

本公开仓库从脱敏快照重建，不包含私有部署的 Git 历史、真实域名、Tunnel ID、密钥、日志或本机运行状态。

### 主要变化

- **55 MiB 请求体上限。** `config.json.maxBodyBytes` 与 `proxy.js` 缺省回退值统一为 57,671,680 字节；同时检查声明的 `Content-Length` 和 chunked 实际流量，超限返回 413。迟到的上游响应不会再触发 `ERR_HTTP_HEADERS_SENT` 或重置已完成的 413。
- **Key 缓存有界。** 正常每 5 秒重读 `settings.json`（`lanKeyCacheMs=5000`）；文件不可读或没有有效 `lanKey` 时，缓存最多沿用 5 分钟（`lanKeyMaxStaleMs=300000`）；失败读取由 2 秒负缓存节流（`lanKeyRetryMs=2000`）。超过上限返回 503 并 fail-closed，文件恢复后自动恢复，新进程没有缓存时绝不放行。
- **ingress 全量校验。** 除末尾 `http_status:404` 外，每条 forwarding service 都必须精确等于代理 listener；带引号 `service` 键、flow collection、anchor/alias/merge key 等未支持 YAML 形式直接拒绝，避免轻量解析器漏读规则。metrics 只允许 loopback。Node 与 PowerShell 也拒绝非根 upstream URL；PowerShell 还要求 `allowedRoutes` 顶层为非空数组、path 以 `/` 开头、methods 全大写。
- **限流前移与日志采样。** 每个可解析请求先计入按调用方和全局限流，再进入路径/管理面/白名单拒绝，未鉴权请求不能靠刷拒绝路径无限写日志。429 日志每窗口最多记录 10 条拒绝日志，随后只输出一条抑制提示；字段截断到 2048 字符。
- **来源头与路径净化。** 删除公网 Key、CF/XFF、`Forwarded`、常见 client-IP、URL/method 覆盖头及 `api-key`；删除标准逐跳头和 `Connection` 动态列出的头。编码点/斜杠/反斜杠/冒号/分号/NUL、`..;`、字面分号和 `//` 在代理层拒绝。
- **查询 Key 语义明确。** 只有查询 Key、没有有效请求头时返回 401；有效请求头同时携带 `key` 查询参数时返回 400；两种情况都不会转发到 Magpie，也不会把秘密写入代理日志。
- **健康与生命周期语义。** 任何 HTTP 响应都证明代理进程存活；401/429 视为 ready，503 为 `key-unavailable`，不会触发重启；cloudflared 连续 3 次 `/ready` 失败才重启。`stop` 不再被损坏配置阻断，`restart -Json` 只输出一个 JSON（默认仍是文本），退出码按实际行为记录。PID 文件写失败只记录警告，仍继续监督已启动的进程对象。
- **IPv6 支持。** `listenHost`、upstream、metrics 和健康检查均支持显式 `::1`；状态地址使用 `[::1]:port`，Windows PowerShell 5.1 的 TCP 探测显式使用 `InterNetworkV6`。
- **同步与面板加固。** `sync-key.ps1` 在 Key 不可用/为空时删除陈旧副本，比较 Key/Endpoint/Source 后原子替换，完全不变时保留 mtime；面板增加 75 秒动作超时、异步输出完成检查、异常后按钮恢复和关闭时 helper 清理。
- **cloudflared 哈希门禁。** 每次启动 Tunnel 前重新计算 `bin/cloudflared.exe` 的 SHA-256 并与 `bin/README.md` 记录比较；缺失或不匹配时保留代理用于本机诊断，但 Tunnel 不会启动，公网状态保持 degraded。
- **仓库内回归。** `tests/proxy.test.js` 覆盖 16 组代理行为，`tests/control.test.ps1` 覆盖 13 组控制层行为；两者都不接触真实服务，可在 Windows PowerShell 5.1 和 PowerShell 7 下重复执行。

### 与 v2.0.0 的行为变化

1. `maxBodyBytes` 从 32 MiB 改为 55 MiB（57,671,680 字节），声明长度和 chunked 实际流量都受同一上限约束。
2. 新增 `lanKeyMaxStaleMs=300000` 和 `lanKeyRetryMs=2000`。缓存 Key 不再无限期沿用；超过 5 分钟仍没有有效 Key 时返回 503。
3. ingress 校验从“只检查第一条”改为逐条检查全部 forwarding service；每条规则必须恰好有一个未加引号的 block-style `service`。
4. `stop` 在配置损坏时仍按本目录精确归属清理；`start` 和 `status` 继续严格校验配置。退出码与 `control.ps1` 的实际分支一致。
5. 只有查询 Key 返回 401；有效请求头附带 `key` 查询参数返回 400。编码冒号/分号、字面分号和 `//` 路径直接 404。
6. 404/500 等意外 HTTP 状态不再触发重启；503 继续按 `key-unavailable` 处理，不会重启；只有连接失败或超时才重启。
7. `sync-key.ps1` 会删除陈旧 `API-KEY.txt`，并在内容未变化时保留原文件时间戳。

### 从 v2.0.0 升级

1. 备份自己的 `config.json`、`config.yml`、`API-KEY.txt` 和 Tunnel 凭据，不要直接覆盖真实配置。
2. 复制全部 v2.1.1 脚本、`config.json` 示例和 `tests/`；只复制 `proxy.js` 会缺少控制层和回归。
3. 在 `config.json` 中加入 `lanKeyMaxStaleMs`、`lanKeyRetryMs`，并把 `maxBodyBytes` 设为 `57671680`。
4. 确认 `config.yml` 中每条 forwarding service 都精确指向代理 listener，保留末尾 `http_status:404`；不要把 Tunnel 直接指向 3425。
5. 替换示例域名、Tunnel ID、`credentials-file` 和 `settingsPath`；如需自定义调用方标识，再调整 `callerAgent`。
6. 执行 `start.cmd restart`，确认状态为 `ready` 或 `waiting-upstream`；再验证无 Key 为 401、正确 Key 为 200，并运行两个仓库内回归。

### 环境要求

- Windows 10/11，Windows PowerShell 5.1+；
- Node.js 18 或更高版本；
- 本机 Magpie gateway（本轮实测 0.1.4720）；
- Cloudflare 托管域名与 `cloudflared.exe`（版本和 SHA-256 见 `bin/README.md`）。

### 快速开始

1. 克隆仓库，把官方 `cloudflared.exe` 放进 `bin/`。
2. 按 `DEPLOY-OTHER-MACHINE.md` 创建 Tunnel、DNS 和本机凭据。
3. 在 `config.yml` 填入自己的 Tunnel ID、凭据路径和 hostname；在 `config.json` 确认 `settingsPath`、端口和 `allowedRoutes`。
4. 运行 `start.cmd`，或双击 `panel.cmd` 使用本机面板。
5. 使用 `API-KEY.txt` 中的本机 Key 调用 `https://<your-host>/v1/models`。

### 验证

`VERIFY.md` 记录本轮实际执行的检查：

- 仓库内 Node 隔离回归 16/16；控制回归在 Windows PowerShell 5.1 与 PowerShell 7 下各 13/13；
- 真实公网协议矩阵 30/30 组，55 MiB 更新后复选 12/12 组；
- 真实生命周期 5/5 组，IPv6 补充实测 2/2，桌面 GUI 场景 8/8；
- 完整性、ACL、哈希、监听和相邻项目隔离检查 0 失败；
- 55 MiB 恰好通过、55 MiB + 1 拒绝；并发复测 11 路全部 200。

仓库内测试不接触真实服务；真实公网、生命周期和 GUI 证据保存在仓库外，不作为运行依赖。首次出现的瞬时 `ECONNRESET`/超时保留了原始证据，按组重跑通过，未改写首次结果。

### 已知限制

- 停止公网侧会中断在途请求，代理不会自动重放。
- cloudflared 输出日志超过 4 MiB 时会通过受控重启轮转，这会中断该 Tunnel 上全部在途请求，包括长推理和 SSE；代理自身日志轮转不重启代理。
- 所有公网客户端共享同一个 Magpie `lanKey`，没有按客户端独立吊销、独立配额或 Key 所有者识别。轮换会影响所有显式使用该 Key 的公网客户端；依赖 Magpie loopback 免鉴权的本机客户端不受影响。缓存窗口也不等于即时吊销。
- 看门狗、启停和面板是 Windows 专用实现。
- 很长的非流式请求可能先触发 Cloudflare 边缘超时，长请求建议使用流式响应。
- 已在 Magpie 0.1.4720 验证，其他版本的路由或鉴权行为可能不同。
- 手工以相对路径启动的 `node proxy.js` 或 `run.ps1` 无法可靠验证工作目录，不受控制脚本管理；请使用标准入口。

### 发布说明

- 所有域名、Tunnel ID、路径和密钥均为示例值或本机环境变量。
- `secrets/`、`API-KEY.txt`、`logs/`、`run/`、证书、私钥和 `bin/*.exe` 均被 Git 忽略。
- 重建后的 `main` 只有一个脱敏初始提交；提交与 Tag 时间统一为 2026-11-24 00:00:00 +08:00。
- License：MIT，详见 `LICENSE`。

---

## English

**magpie-public v2.1.1** is a security and reliability maintenance release after v2.0.0. It unifies the request-body cap at 55 MiB, adds a hard stale limit and negative caching to the key cache, tightens ingress and route validation, and adds repeatable in-repository Node and PowerShell regressions.

This public repository was rebuilt from a sanitized snapshot. It contains no private deployment history, real endpoint, tunnel ID, key, log, or local runtime state.

### Highlights

- **55 MiB body cap.** `config.json.maxBodyBytes` and the `proxy.js` fallback both use 57,671,680 bytes. Declared `Content-Length` and actual chunked traffic are checked; overflow returns 413. A late upstream response can no longer trigger `ERR_HTTP_HEADERS_SENT` or reset a completed 413.
- **Bounded key cache.** `settings.json` is normally re-read every 5 seconds (`lanKeyCacheMs=5000`). If the file is unreadable or has no usable `lanKey`, the cached key is reused for at most 5 minutes (`lanKeyMaxStaleMs=300000`); failed reads are throttled by a 2-second negative cache (`lanKeyRetryMs=2000`). After the limit the gateway returns 503 and fails closed. Recovery is automatic; a fresh process with no cache never forwards.
- **Full ingress validation.** Except for the final `http_status:404`, every forwarding service must exactly match the proxy listener. Quoted `service` keys, flow collections, anchors/aliases, and merge keys are rejected rather than silently skipped. Metrics must be loopback-only. Both Node and PowerShell reject non-root upstream URLs; PowerShell also requires `allowedRoutes` to be a non-empty array with absolute paths and uppercase methods.
- **Rate limiting before denials.** Every parseable request consumes the per-caller and global budget before path, management, or allowlist rejection, so unauthenticated callers cannot write unlimited denial logs. Only the first 10 rate-limit denials are logged per window; the 11th writes one suppression notice. Fields are truncated to 2048 characters.
- **Header and path hygiene.** Public credentials, CF/XFF, `Forwarded`, common client-IP headers, URL/method overrides, and `api-key` are removed. Standard hop-by-hop headers and headers named by `Connection` are stripped. Encoded dot/slash/backslash/colon/semicolon/NUL, `..;`, literal semicolons, and `//` are rejected at the gateway.
- **Explicit query-key semantics.** A query key without a valid header returns 401; a valid header combined with a `key` query parameter returns 400. Neither is forwarded to Magpie, and the secret is not written to the gateway log.
- **Health and lifecycle.** Any HTTP response proves the proxy process is alive; 401/429 are ready, 503 is `key-unavailable` and does not cause a restart. cloudflared is restarted only after three consecutive `/ready` failures. `stop` works even with an invalid config, `restart -Json` emits one JSON document (the default remains text), and exit codes match actual behavior. A PID-file write failure only logs a warning; the already started process is still supervised.
- **IPv6.** Listener, upstream, metrics, and health checks support explicit `::1`; status addresses use `[::1]:port`, and the Windows PowerShell 5.1 TCP probe explicitly uses `InterNetworkV6`.
- **Sync and panel hardening.** `sync-key.ps1` removes a stale key copy when the key is unavailable, compares key/endpoint/source metadata, replaces atomically, and keeps the mtime when nothing changed. The panel adds a 75-second action timeout, async output completion checks, button recovery, and helper cleanup on close.
- **cloudflared hash gate.** The SHA-256 of `bin/cloudflared.exe` is recomputed before every tunnel start and compared with `bin/README.md`. A missing or mismatched binary keeps the proxy available for local diagnosis but prevents the tunnel from becoming ready.
- **In-repository regressions.** `tests/proxy.test.js` covers 16 proxy groups and `tests/control.test.ps1` covers 13 control groups. Both use temporary fixtures and no real services, and run under Windows PowerShell 5.1 and PowerShell 7.

### Behavior changes from v2.0.0

1. `maxBodyBytes` changes from 32 MiB to 55 MiB (57,671,680 bytes); both declared and chunked bodies share the limit.
2. New `lanKeyMaxStaleMs=300000` and `lanKeyRetryMs=2000`. The cached key is no longer reused indefinitely; after 5 minutes without a usable key the gateway returns 503.
3. Ingress validation now checks every forwarding service, not only the first. Each rule must contain exactly one unquoted block-style `service`.
4. `stop` still cleans owned processes when the config is invalid; `start` and `status` remain strict. Exit codes match the actual `control.ps1` branches.
5. Query-only keys return 401; a valid header plus a `key` query parameter returns 400. Encoded colons/semicolons, literal semicolons, and `//` paths return 404.
6. Unexpected HTTP statuses such as 404/500 no longer restart the proxy; 503 remains alive-but-degraded and does not restart; only connection failure or timeout does.
7. `sync-key.ps1` removes a stale `API-KEY.txt` and preserves the file timestamp when content is unchanged.

### Upgrading from v2.0.0

1. Back up your `config.json`, `config.yml`, `API-KEY.txt`, and tunnel credentials; do not overwrite real configuration in place.
2. Copy all v2.1.1 scripts, the `config.json` sample, and `tests/`. Copying only `proxy.js` leaves out the control layer and regressions.
3. Add `lanKeyMaxStaleMs` and `lanKeyRetryMs` to `config.json`, and set `maxBodyBytes` to `57671680`.
4. Make every forwarding service in `config.yml` exactly target the proxy listener, keep the final `http_status:404`, and never point the tunnel directly at 3425.
5. Replace the example hostname, tunnel ID, `credentials-file`, and `settingsPath`; adjust `callerAgent` only if you need a different caller identity.
6. Run `start.cmd restart`, confirm `ready` or `waiting-upstream`, verify 401 without a key and 200 with the correct key, and run both in-repository regressions.

### Requirements

- Windows 10/11 with Windows PowerShell 5.1+
- Node.js 18 or newer
- A local Magpie gateway (0.1.4720 was used for this verification)
- A Cloudflare-managed domain and `cloudflared.exe` (version and SHA-256 in `bin/README.md`)

### Getting started

1. Clone the repository and place the official `cloudflared.exe` in `bin/`.
2. Follow `DEPLOY-OTHER-MACHINE.md` to provision the tunnel, DNS, and local credentials.
3. Fill in your tunnel ID, credentials path, and hostname in `config.yml`; confirm `settingsPath`, ports, and `allowedRoutes` in `config.json`.
4. Run `start.cmd`, or open `panel.cmd` for the local panel.
5. Call `https://<your-host>/v1/models` with the key from `API-KEY.txt`.

### Verification

`VERIFY.md` records the checks actually run in this round:

- 16/16 in-repository Node isolation groups; 13/13 control groups under both Windows PowerShell 5.1 and PowerShell 7;
- 30/30 real public protocol groups, and 12/12 groups re-selected after the 55 MiB change;
- 5/5 real lifecycle groups, 2/2 IPv6 checks, and 8/8 desktop GUI scenarios;
- 0 failures in integrity, ACL, hash, listener, and adjacent-project isolation checks;
- exactly 55 MiB accepted, 55 MiB + 1 rejected; all 11 concurrent calls returned 200.

The in-repository tests do not touch real services; real public, lifecycle, and GUI evidence stays outside the repository and is not a runtime dependency. Transient first-attempt `ECONNRESET`/timeout evidence is preserved; the affected groups passed on targeted reruns, and the initial results were not rewritten.

### Known limitations

- Stopping the public side interrupts in-flight requests; the gateway does not replay them.
- When a cloudflared output log exceeds 4 MiB, the supervisor rotates it by restarting cloudflared, which interrupts every in-flight request on that tunnel, including long generations and SSE. Proxy log rotation does not restart the proxy.
- All public clients share one Magpie `lanKey`; there is no per-client revocation, quota, or key-owner identity. Rotating it affects every public client that explicitly uses it. Loopback clients that rely on Magpie's gateway-key exemption are unaffected. The cache window is not an instant-revocation mechanism.
- The supervisor, lifecycle commands, and panel are Windows-only.
- Very long non-streaming generations may hit Cloudflare's edge timeout; streaming is recommended.
- Verified with Magpie 0.1.4720; routing or authentication behavior may differ on other versions.
- Manual relative-path starts of `node proxy.js` or `run.ps1` cannot be reliably attributed to a working directory and are not managed by the control scripts. Use the standard entry points.

### Notes

- Every endpoint, tunnel ID, path, and key is a placeholder or a local environment variable.
- `secrets/`, `API-KEY.txt`, `logs/`, `run/`, certificates, private keys, and `bin/*.exe` are git-ignored.
- The rebuilt `main` contains one sanitized initial commit; commit and tag timestamps are both 2026-11-24 00:00:00 +08:00.
- License: MIT. See `LICENSE`.
