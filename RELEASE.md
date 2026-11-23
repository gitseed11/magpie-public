# v2.2.0 - 限流分层、鉴权失败语义与配置校验 / Rate-limit isolation, auth-failure semantics and config validation

发布日期 / Release date：**2026-11-24 00:00:00 +08:00**

Tag：**v2.2.0**

[中文](#中文) · [English](#english)

---

## 中文

**magpie-public v2.2.0** 是 v2.1.1 之后的加固版本：把匿名拒绝流量与已鉴权配额彻底分离，修正鉴权失败节流被跨站请求利用的问题，处理上游提前响应时的半开连接，并补齐配置数值校验与面板错误显示。本版不改变架构、启停语义和公网协议路径。

本公开仓库从脱敏快照重建，不包含私有部署的 Git 历史、真实域名、Tunnel ID、密钥、日志或本机运行状态。

### 主要变化

- **限流分层。** 此前全局限流在所有请求上先扣减，匿名探测流量可以把已鉴权客户端挤出配额。现在分成三个独立预算：每个调用方（`CF-Connecting-IP`）的 `maxRequests` 窗口配额；通过鉴权后才计入的 `globalMaxRequests` 全局配额；未鉴权拒绝类响应（未知路径、管理面、缺失/错误 Key、超限声明）单独使用的 `globalMaxRequests × 10` 上限。匿名洪泛无法再占用已鉴权预算，同时仍受独立上限约束，不能把代理变成免费的日志/CPU 放大器。
- **鉴权失败只统计携带了错误 Key 的请求。** 未携带 Key 的 401 不再计入失败节流。此前任意网页都能用跨站 no-cors 请求（无自定义头、无预检）连发 20 次无 Key 请求，把一个出口 IP 锁死 60 秒。成功鉴权现在还会清零该来源的计数，正常客户端不会因为偶发错误被持续累计。
- **上游提前响应时关闭未完成的连接。** 上游在请求体接收完成前就返回并结束响应时（例如快速拒绝），Node 会停止向代理投递剩余请求体，客户端可能一直阻塞到 `requestTimeout`。现在在响应 `finish` 且 `req.complete` 为 false 时主动关闭该连接；完整接收的请求仍然复用连接，keep-alive 行为不变。
- **配置数值校验前移。** `common.ps1` 在启动任何进程前校验 `lanKeyCacheMs`、`lanKeyMaxStaleMs`、`lanKeyRetryMs`、`maxBodyBytes`、`upstreamTimeoutMs`、`maxLogBytes` 和 `rateLimit.*` 必须为正的有限数，`listenPort` 必须是 1–65535 的整数。`0`、负值、`NaN`、`Infinity`、`8790.5` 这类写法会被直接拒绝，而不是让看门狗反复重启一个必然失败的进程、把原因埋在 `logs\proxy.err.log`。`proxy.js` 也自行校验 `listenPort` 的整数与范围，直接 `node proxy.js` 启动时不会绕过该规则。
- **面板状态失败不再弹模态框。** 15 秒自动刷新读取状态失败时（例如配置损坏），面板改为在界面内显示“状态：读取失败”和原因，并保留上一次已知的组件状态。启动/停止等主动操作仍弹出错误框。
- **Key 同步的 hostname 解析与配置校验一致。** `sync-key.ps1` 改用与 `common.ps1` 相同的锚定正则，只匹配行首的 `hostname:`（允许 `- hostname:` 列表形式），不再被注释行或缩进文本误命中；取到的值会 trim。`API-KEY.txt` 里显示的 Endpoint 因此不会指向错误域名。
- **拒绝类日志采样补齐。** 没有可用 `lanKey` 时的 503、`authBlocked` 的 429 与已鉴权全局超限的 429 都走采样日志，避免 Key 文件缺失或锁定期间每个请求都写一行。
- **无凭据的 503 也计入匿名上限。** `lanKey` 不可用时返回 503 的分支在任何 Key 比较之前就可达，此前只扣每个调用方配额，轮换出口 IP 的调用方可以绕过总量约束。现在它与其他拒绝路径一样计入匿名上限，503 语义保持不变，看门狗仍映射为 `key-unavailable`。

### 与 v2.1.1 的行为变化

1. 全局限流拆成两个全局桶（加上原有的每调用方配额，共三层）：匿名拒绝计入 `10 × globalMaxRequests`，已鉴权请求计入 `globalMaxRequests`。同样的配置下，匿名探测的容忍度是原来的 10 倍，而已鉴权客户端不会再被匿名流量挤掉。
2. 未携带 Key 的 401 不再计入鉴权失败节流；只有携带了错误 Key 的请求才累计。成功鉴权会清零该来源的计数。
3. 上游提前结束响应且请求体未收完时，代理关闭连接。客户端可能看到连接提前结束；这属于预期行为，请求没有被转发。
4. `common.ps1` 现在拒绝非正数、非有限数和非整数端口的配置。此前 `8790.5` 会被 PowerShell 静默截断为 `8790`，而 `proxy.js` 会拒绝启动，两层判断不一致。`proxy.js` 也补齐了 `listenPort` 的整数与 1–65535 范围校验：此前越界端口会在 `server.listen` 抛未捕获的 `RangeError`，现在改为启动前报错退出。
5. 面板自动刷新失败不再弹模态框。
6. `sync-key.ps1` 的 hostname 正则改为锚定匹配。
7. `lanKey` 不可用的 503 分支也计入匿名上限，与其他拒绝路径一致；503 状态码与看门狗语义不变。

### 从 v2.1.1 升级

1. 备份自己的 `config.json`、`config.yml`、`API-KEY.txt` 和 Tunnel 凭据，不要直接覆盖真实配置。
2. 复制全部 v2.2.0 脚本与 `tests/`；只复制 `proxy.js` 会缺少控制层的数值校验和面板改动。
3. 检查 `config.json` 的所有数值字段：`listenPort` 必须是整数，其余必须为正数。此前被容忍的 `0`、负值或字符串现在会在启动前报错。
4. `config.json` 不需要新增字段；限流分层使用现有的 `rateLimit.maxRequests` 与 `rateLimit.globalMaxRequests`，匿名上限由后者乘以 10 自动得出。
5. 执行 `start.cmd restart`，确认状态为 `ready` 或 `waiting-upstream`；再验证无 Key 为 401、正确 Key 为 200，并运行两个仓库内回归。

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

`VERIFY.md` 第 12 节记录本轮实际执行的检查：

- 仓库内 Node 隔离回归 20/20（新增限流隔离、缺 Key 语义、提前响应关闭、keep-alive 复用）；
- 控制回归在 Windows PowerShell 5.1 与 PowerShell 7 下各 14/14（新增数值配置校验）；
- mock 功能矩阵 13 组 / 39 项全部通过（假上游，临时目录）；
- 真实公网功能矩阵 11 组 / 26 项：25 通过、1 跳过（声明长度 413 需 Cloudflare 回传完整请求体，20 秒内未回传；同一边界已由仓库内精确测试覆盖）；
- 真实公网长上下文 180,229 字符 × 三协议、多模态 64×64 PNG（左红右蓝）× 三协议，全部正确；
- 真实公网生命周期 6 组 / 24 项：停止/启动、看门狗恢复、在途 SSE 中断；全程 Magpie PID 未变化。

仓库内测试不接触真实服务；真实公网、生命周期和 GUI 证据保存在仓库外，不作为运行依赖。首次出现的瞬时异常保留了原始证据，按组重跑通过，未改写首次结果。

### 已知限制

- 停止公网侧会中断在途请求，代理不会自动重放。
- cloudflared 输出日志超过 4 MiB 时会通过受控重启轮转，这会中断该 Tunnel 上全部在途请求，包括长推理和 SSE；代理自身日志轮转不重启代理。
- 所有公网客户端共享同一个 Magpie `lanKey`，没有按客户端独立吊销、独立配额或 Key 所有者识别。轮换会影响所有显式使用该 Key 的公网客户端；依赖 Magpie loopback 免鉴权的本机客户端不受影响。缓存窗口也不等于即时吊销。
- 限流状态保存在进程内存中，代理重启后清零；它不是跨进程或跨机器的分布式限流。
- 看门狗、启停和面板是 Windows 专用实现。
- 很长的非流式请求可能先触发 Cloudflare 边缘超时，长请求建议使用流式响应。
- 已在 Magpie 0.1.4720 验证，其他版本的路由或鉴权行为可能不同。
- 手工以相对路径启动的 `node proxy.js` 或 `run.ps1` 无法可靠验证工作目录，不受控制脚本管理；请使用标准入口。

### 发布说明

- 所有域名、Tunnel ID、路径和密钥均为示例值或本机环境变量。
- `secrets/`、`API-KEY.txt`、`logs/`、`run/`、证书、私钥和 `bin/*.exe` 均被 Git 忽略。
- 本仓库为脱敏重建，不包含私有部署历史；提交与 Tag 时间统一为 2026-11-24 00:00:00 +08:00。
- License：MIT，详见 `LICENSE`。

### 历史版本

- **v2.1.1**：请求体上限统一为 55 MiB（57,671,680 字节）；Key 缓存增加 5 分钟硬失效上限与 2 秒失败负缓存；ingress 逐条校验全部 forwarding service 并封堵未支持 YAML 形式；`stop` 不再被损坏配置阻断；意外 HTTP 状态不再触发重启；补齐来源头/路径净化与查询 Key 语义；新增 IPv6 支持；`sync-key.ps1` 清理陈旧副本并原子替换；cloudflared 哈希门禁；仓库内 Node 16 组 / PowerShell 13 组回归。
- **v2.0.0**：首个公开版本，建立“Cloudflare Tunnel → 本机鉴权代理 → 本机 Magpie”的固定链路、方法/路径白名单、限流与看门狗。

---

## English

**magpie-public v2.2.0** is a hardening release after v2.1.1. It fully separates anonymous rejection traffic from the authenticated budget, fixes an auth-failure throttle that cross-site requests could exploit, handles half-open connections when the upstream answers early, and adds numeric config validation plus inline panel errors. It does not change the architecture, lifecycle semantics, or public protocol paths.

This public repository was rebuilt from a sanitized snapshot. It contains no private deployment history, real endpoint, tunnel ID, key, log, or local runtime state.

### Highlights

- **Rate-limit isolation.** The global ceiling used to be charged on every request first, so anonymous probing could push authenticated clients out of the budget. There are now three independent budgets: a per-caller `maxRequests` window (`CF-Connecting-IP`); a `globalMaxRequests` ceiling charged only after successful authentication; and a separate `globalMaxRequests × 10` ceiling for unauthenticated rejections (unknown path, management surface, missing or wrong key, oversized declaration). An anonymous flood can no longer consume the authenticated budget, and it is still bounded by its own ceiling so the proxy cannot become a free log/CPU amplifier.
- **Only presented-but-wrong keys count as failed attempts.** A key-less 401 no longer feeds the auth-failure throttle. Previously any web page could send 20 cross-site no-cors requests (no custom header, so no preflight) and lock an egress IP out for 60 seconds. A successful authentication now also clears that caller's counter, so well-behaved clients do not accumulate penalties from occasional mistakes.
- **Unfinished uploads are closed when the upstream answers early.** When the upstream responds and ends before the request body is fully received (for example a fast rejection), Node stops feeding the remaining body to the proxy and the client can block until `requestTimeout`. The proxy now destroys that connection on response `finish` when `req.complete` is false. Fully received requests still reuse the connection, so keep-alive is unchanged.
- **Numeric config validation moved forward.** Before starting any process, `common.ps1` requires `lanKeyCacheMs`, `lanKeyMaxStaleMs`, `lanKeyRetryMs`, `maxBodyBytes`, `upstreamTimeoutMs`, `maxLogBytes`, and `rateLimit.*` to be positive finite numbers, and `listenPort` to be an integer in 1–65535. Values such as `0`, negatives, `NaN`, `Infinity`, or `8790.5` are rejected up front instead of letting the supervisor restart a process that can never start and burying the cause in `logs\proxy.err.log`. `proxy.js` enforces the integer-and-range rule for `listenPort` itself, so a direct `node proxy.js` start cannot bypass it.
- **Panel status failures no longer open a modal dialog.** When the 15-second auto-refresh cannot read status (for example a broken config), the panel shows “status: read failed” and the reason inline, keeping the last known component state. Explicit start/stop failures still raise an error dialog.
- **Key-sync hostname parsing matches config validation.** `sync-key.ps1` now uses the same anchored pattern as `common.ps1`, matching only a line-leading `hostname:` (including the `- hostname:` list form), so comment lines and indented prose no longer match. The captured value is trimmed, so the Endpoint shown in `API-KEY.txt` cannot point at the wrong host.
- **Rejection log sampling completed.** The 503 for a missing `lanKey`, the 429 for `authBlocked`, and the 429 for the authenticated global limit all go through the sampled logger, so a missing key file or an active lockout no longer writes one line per request.
- **The credential-free 503 now counts against the anonymous ceiling.** The branch that returns 503 when `lanKey` is unavailable is reachable before any key comparison, and previously charged only the per-caller quota, so a caller rotating egress IPs could bypass the aggregate bound. It now charges the anonymous ceiling like every other rejection; the 503 itself is unchanged and the watchdog still maps it to `key-unavailable`.

### Behavior changes from v2.1.1

1. The global limit is split into two global buckets (three tiers in total with the existing per-caller quota): anonymous rejections charge `10 × globalMaxRequests`, authenticated requests charge `globalMaxRequests`. With the same configuration, anonymous probing gets 10x the tolerance and authenticated clients are no longer crowded out.
2. Key-less 401s no longer count toward the auth-failure throttle; only requests that presented a wrong key do. A successful authentication clears the caller's counter.
3. When the upstream ends the response before the request body is complete, the proxy closes the connection. Clients may see an early close; this is expected and nothing was forwarded.
4. `common.ps1` now rejects non-positive, non-finite, and non-integer-port values. Previously `8790.5` was silently truncated to `8790` by PowerShell while `proxy.js` refused to start, so the two layers disagreed. `proxy.js` also gained the integer-and-1–65535 check for `listenPort`: an out-of-range port used to raise an uncaught `RangeError` from `server.listen` and now fails before startup.
5. Panel auto-refresh failures no longer open a modal dialog.
6. The `sync-key.ps1` hostname pattern is now anchored.
7. The 503 branch for an unavailable `lanKey` now charges the anonymous ceiling like every other rejection; the status code and watchdog semantics are unchanged.

### Upgrading from v2.1.1

1. Back up your `config.json`, `config.yml`, `API-KEY.txt`, and tunnel credentials; do not overwrite real configuration in place.
2. Copy all v2.2.0 scripts and `tests/`. Copying only `proxy.js` leaves out the control-layer validation and the panel change.
3. Check every numeric field in `config.json`: `listenPort` must be an integer and the rest must be positive. Values previously tolerated (`0`, negatives, strings) now fail before startup.
4. No new `config.json` fields are required. The split reuses the existing `rateLimit.maxRequests` and `rateLimit.globalMaxRequests`; the anonymous ceiling is derived as the latter times 10.
5. Run `start.cmd restart`, confirm `ready` or `waiting-upstream`, verify 401 without a key and 200 with the correct key, and run both in-repository regressions.

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

`VERIFY.md` section 12 records the checks actually run in this round:

- 20/20 in-repository Node isolation groups (new: rate-limit isolation, missing-key semantics, early-response close, keep-alive reuse);
- 14/14 control groups under both Windows PowerShell 5.1 and PowerShell 7 (new: numeric config validation);
- 13 groups / 39 items in the mock functional matrix, all passing (fake upstream, temporary directory);
- 11 groups / 26 items against the real public endpoint: 25 passed, 1 skipped (a declared-length 413 requires Cloudflare to relay the full body, which did not happen within 20 seconds; the same boundary is covered exactly in-repository);
- real public long context of 180,229 characters across all three protocols, and a 64×64 PNG (left red, right blue) across all three protocols, both correct;
- 6 groups / 24 items of real public lifecycle: stop/start, watchdog recovery, in-flight SSE interruption; the Magpie PID never changed.

The in-repository tests do not touch real services; real public, lifecycle, and GUI evidence stays outside the repository and is not a runtime dependency. Transient first-attempt anomalies kept their original evidence; affected groups passed on targeted reruns and the initial results were not rewritten.

### Known limitations

- Stopping the public side interrupts in-flight requests; the gateway does not replay them.
- When a cloudflared output log exceeds 4 MiB, the supervisor rotates it by restarting cloudflared, which interrupts every in-flight request on that tunnel, including long generations and SSE. Proxy log rotation does not restart the proxy.
- All public clients share one Magpie `lanKey`; there is no per-client revocation, quota, or key-owner identity. Rotating it affects every public client that explicitly uses it. Loopback clients that rely on Magpie's gateway-key exemption are unaffected. The cache window is not an instant-revocation mechanism.
- Rate-limit state lives in process memory and resets when the proxy restarts; it is not distributed across processes or machines.
- The supervisor, lifecycle commands, and panel are Windows-only.
- Very long non-streaming generations may hit Cloudflare's edge timeout; streaming is recommended.
- Verified with Magpie 0.1.4720; routing or authentication behavior may differ on other versions.
- Manual relative-path starts of `node proxy.js` or `run.ps1` cannot be reliably attributed to a working directory and are not managed by the control scripts. Use the standard entry points.

### Notes

- Every endpoint, tunnel ID, path, and key is a placeholder or a local environment variable.
- `secrets/`, `API-KEY.txt`, `logs/`, `run/`, certificates, private keys, and `bin/*.exe` are git-ignored.
- This repository is a sanitized rebuild without private deployment history; commit and tag timestamps are normalized to 2026-11-24 00:00:00 +08:00.
- License: MIT. See `LICENSE`.

### Previous releases

- **v2.1.1**: unified the request-body cap at 55 MiB (57,671,680 bytes); added a 5-minute hard stale limit and a 2-second negative cache to the key cache; validated every ingress forwarding service and rejected unsupported YAML forms; `stop` no longer blocked by a broken config; unexpected HTTP statuses no longer restart the proxy; completed source-header/path sanitization and query-key semantics; added IPv6 support; `sync-key.ps1` removes stale copies and replaces atomically; cloudflared hash gate; 16 Node / 13 PowerShell in-repository regression groups.
- **v2.0.0**: first public release, establishing the fixed "Cloudflare Tunnel → local authenticating proxy → local Magpie" chain, method/path allow-listing, rate limiting, and the supervisor.
