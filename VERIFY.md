# 安全验证记录

日期：2026-11-22　隧道：`magpie-public`（隧道 ID 略）

## 结果汇总

| # | 测试 | 期望 | 实测 | 结论 |
|---|---|---|---|---|
| 1 | `curl http://127.0.0.1:3425/v1/models`（无 Key，直连 Magpie） | 200 | **200** | ✅ 证实 loopback 免鉴权，代理层必需 |
| 2 | `https://apimagpie.example.com/v1/models`（无 Key） | 401 | **401** | ✅ |
| 3 | 带错误 Key | 401 | **401** | ✅ |
| 4 | 带正确 lanKey（Bearer） | 200 | **200** | ✅ |
| 4b | 带正确 lanKey（`x-api-key`） | 200 | **200** | ✅ |
| 5 | 公网 SSE 流式 | 逐块到达 | **逐块递增到达（实测间隔约 50–100 ms）** | ✅ 未缓冲 |
| 6 | `/v1/magpie/limit`、`/v1/magpie/admin/`、`/api/settings`、`/v1/magpie/quotas` | 404 | **404 ×4** | ✅ 管理面公网不可达 |
| 7 | `/healthz`、`/`、`/admin`、`/v1/magpie` | 404 | **404 ×4** | ✅ |
| 8 | 端口绑定 | 仅 loopback | 3425 / 8790 / 20242 均 `127.0.0.1`，无 `0.0.0.0:3425` | ✅ |
| 9 | 同机其他隧道项目完整性 | 未变 | 另一项目的 `config.yml` 哈希未变；`cloudflared.exe` 哈希 `d5c1d820…`；其凭据目录仍为原有文件 | ✅ |
| 10 | Magpie 未受影响 | 存活且配置未改 | PID 15888 存活；`gateway.json` 仍为 `127.0.0.1:3425`；`settings.json` 仅读 | ✅ |
| 11 | 真实推理调用 | 正常返回 | `chat/completions` 返回 `"content":"OK"` | ✅ |
| 12 | 启动方式 | 纯手动 | 无任何计划任务；`start.cmd` 启停，`start.cmd status` 查状态 | ✅ |
| 13 | 限流按调用方分桶 | 不同来源互不影响 | 调用方 A（`203.0.113.77`）打满后立刻 429；随后调用方 B（`203.0.113.88`）仍能通过 600 次 | ✅ 修复后复验 |
| 14 | 无连接池（Magpie 可后启动） | 连续请求无 502 | 20 次连续公网请求全部 200；`upstreamAgent = false` | ✅ |
| 15 | 伪造 XFF 不能绕过限流 | 同一调用方过 600 次即 429 | 700 次（`CF-Connecting-IP` 固定、`X-Forwarded-For` 每次不同）→ **600×200 + 100×429**，0.8 s 内完成 | ✅ |
| 16 | 错误 Key 暴力破解被节流 | 第 21 次起 429 | 固定调用方 60 次坏 key → **20×401 + 40×429** | ✅ |
| 17 | 编码路径穿越被拒 | 404 | `..%2f`、`%2e%2e`、`%5c`、`%00`、裸 `..`、`..;`、`//` → 全 404；正常路径 200 | ✅ |
| 18 | 超大 body 被拒 | 413 | 40MB（带 `Content-Length`）→ **413**；真正 chunked 40MB（`Transfer-Encoding: chunked`，无长度声明）→ **413**，且同一连接后续请求仍 200 | ✅ |
| 19 | `/v1beta/models` 可用 | 200 | 修复白名单后 → **200**（Gemini SDK 首调不再 404）；`POST …/<model>:generateContent` → **200**，返回 `candidates[0].content.parts[0].text` | ✅ |
| 20 | `secrets\` 与 `API-KEY.txt` 权限 | 仅当前用户/SYSTEM/Administrators | `icacls` 确认已无 `Authenticated Users` / `Users` | ✅ |
| 21 | 看门狗不误杀健康代理 | 长时间无 `restarting` | 修复后分多段实测（21:29:59–21:37:23、21:40:01–21:43:21、21:43:21–21:46:37，累计约 14 分钟），每段 `restarting` **均为 0**；`proxy.log` 每 15 s 一条 `PROBE`。期间 21:38:08 的一次重启是人工 `Stop-Process` 后 15 s 内自动恢复，属预期行为 | ✅ |
| 22 | 三种鉴权头都可用 | 值正确即 200，错误即 401 | `Authorization: Bearer` → **200**；`x-api-key` → **200**；`x-goog-api-key` → **200**；错误 `x-goog-api-key` → **401**；`?key=` 查询串 → **401** | ✅ |
| 23 | 上游启停 × 代理启停（模拟 Magpie） | 代理无需重启即恢复 | 上游未起 → **502**；上游起 → **200**（代理 PID 不变）；上游停 → **502**（PID 仍不变）；上游再起 → **200**；代理重启后 → **200** | ✅ |
| 24 | 协议 × 模型矩阵（真实公网→真实 Magpie） | 全部 200 | OpenAI chat 4/4 模型；OpenAI `/v1/responses`；Anthropic `/v1/messages`、stream、`count_tokens`、`?beta=true`、`thinking`；Gemini `generateContent`、`streamGenerateContent?alt=sse` | ✅ |
| 25 | 思考强度参数 | 透传不报错 | `reasoning_effort` low/high 均 **200**（reasoning_tokens 17/18）；Anthropic `thinking` 1024 → **200**，`thinking_tokens 29`；Gemini `thinkingBudget` 0/1024 均 **200**（后者 `thoughtsTokenCount 9`） | ✅ |
| 26 | 多模态 | 图片真正到达模型 | 三种格式均 **200**，且模型正确说出「左红右蓝」：OpenAI `image_url`（data URL）、Anthropic `image`(base64)、Gemini `inlineData` | ✅ |
| 27 | 并发混合协议 | 无失败 | 11 个并发请求（chat×4 模型 + responses + messages×2 + generateContent×2 + 两个 models 列表）→ **11/11 × 200**，7.2 s | ✅ |
| 28 | 请求头净化 | 上游看不到公网 Key 与伪造头 | mock 回显：`authorization` 变为 `Bearer magpie-public`；`x-api-key`、`x-goog-api-key`、`x-forwarded-for`、`x-real-ip`、`cf-*` 全部缺失；`host` 为上游；请求体/头里搜不到 `sk-magpie-key` | ✅ |
| 29 | 三种错误码路径 | 503 / 502 / 504 | 临时实例实测：`settingsPath` 指向不存在的文件 → **503**；上游端口无人监听 → **502**；上游接受连接但永不应答（超时设 1.5 s）→ **504** | ✅ |
| 30 | 32k 长上下文 | 中间埋的暗号能被找回 | 四组均 **200** 且答对：OpenAI 31,869 tokens → `7F3A`；Anthropic 31,912 → `7F3A`；Gemini 32k → `7F3A`；OpenAI + 图片 31,953 → `7F3A / green` | ✅ |
| 31 | 32k/180KB × 启停矩阵 | 各状态行为确定、可恢复 | mock：上游未起→**502**；上游起→**200**（`receivedBytes:180055`，代理 PID 不变）；代理重启→**200**。生产：停→公网 **502**；起→**200**（32k 真实请求通过）；32k 请求进行中停服务→客户端 **502**，重启后 **200** | ✅ |
| 32 | 协议透明性（无自定义协议） | 响应体不改写、不注入字段 | `/v1/models` 响应体在 **3425 直连 / 8790 代理 / 公网** 三处 SHA-256 完全相同（`c02e751c…`）；SSE 响应经代理带 `cache-control: no-cache, no-transform` + `x-accel-buffering: no`，经 Cloudflare 时后者被过滤（已在文档注明）；上游错误体原样到达 | ✅ |
| 33 | 独立 `stop.cmd` | 只停公网侧、幂等、不动 Magpie | 运行中执行 → 杀掉 `powershell`(看门狗) + `node`(代理) + `cloudflared`(隧道) 三个进程，8790/20242 释放、exit 0，Magpie 仍在 3425；再执行一次 → `[i] Nothing was running.`、exit 0；**只杀看门狗造成孤儿态**后再执行 → 仍能清掉残留的 node/cloudflared；全过程 Magpie PID 15888 未变 | ✅ |

## 已修复的问题

| 问题 | 现象 | 修复 |
|---|---|---|
| **看门狗每 15 秒杀掉健康代理**（HIGH，功能） | `Test-Proxy` 用 `$req.Headers.Add('User-Agent', …)` 设 UA。`User-Agent` 是 `HttpWebRequest` 的**受限标头**，`Headers.Add` 抛 `ArgumentException` → 探针恒返回 `false` → 看门狗认定「进程活着但无响应」，每轮强杀并重启代理。`supervisor.log` 每 15 s 一组 `restarting`，`proxy.log` 里 0 条 `PROBE`；每次强杀都会中断正在进行的 SSE 流 | 改用类型化属性 `$req.UserAgent = …`；判活放宽为 401 **或** 429（429 也证明代理在正常限流）；修复后实测 0 次重启、`PROBE` 每 15 s 一条 |
| **`start.cmd` 只看端口，发现不了看门狗已死**（MED） | 端口在监听就打印「Already running」。若看门狗被杀而 proxy/tunnel 成孤儿，隧道挂掉后无人重启；再跑 `start.cmd` 又因端口被占而失败 | 增加看门狗检测（匹配 `run.ps1` 进程并排除自身）；「端口在监听但看门狗不在」时明确提示先 `stop` 再 `start`；`status` 增加 `Watchdog:` 行 |
| **`Test-Magpie` 定义了却从未调用**（MED，文档与实现不一致） | 文档声称「新增上游可达性检查」，实际循环里没有调用，属于死代码 | 接入主循环：每轮探测 Magpie 端口，**仅在状态变化时**写一行日志（用来解释 502），不触发任何重启 |
| **日志可被换行注入**（LOW） | 拒绝路径时把客户端可控的 `pathname` 直接写进日志；`/x%0a…` 解码后带换行，可伪造日志行 | `log()` 统一把控制字符（`\u0000-\u001f`、`\u007f`）替换为 `?` |
| **文档指向了空的日志文件**（LOW） | 文档让人去 `logs/cloudflared.out.log` 找 `Registered tunnel connection`，但 cloudflared 把 INFO 日志全部写到 **stderr**，该文件实际是 0 字节，真正内容在 `cloudflared.err.log` | 两份文档改为指向 `cloudflared.err.log` 并说明原因；`proxy.out.log` 同理注明"正常时为空" |
| **交付文件被改写后 ACL 漂移**（LOW） | 本轮改完代码/文档后复查发现：被重新写入的文件（`proxy.js`、`run.ps1`、`config.json`、三份 md 等）DACL 变成「当前用户 + SYSTEM + 一个登录会话 SID `S-1-5-5-0-…`」，`Administrators` 丢失 | `icacls <file> /remove *S-1-5-5-0-<id>` 清掉登录会话 ACE，再对整棵树重建「仅 3 个主体」；复查全树无任何额外主体。DEPLOY 4.6 节补充「每次改文件后建议重跑 icacls」 |
| **`sync-key.ps1` 硬编码用户名与域名**（LOW） | 默认 `$SettingsPath` 写死 `C:\Users\<user>\…`，`API-KEY.txt` 里写死 `apimagpie.example.com`；复制到别的电脑会给出错误路径与端点 | 默认值改为 `$env:USERPROFILE\.config\magpie\settings.json`；Endpoint 从 `config.yml` 的 `hostname:` 读取 |
| **限流可被伪造 XFF 绕过**（HIGH） | `callerId()` 回退到 `X-Forwarded-For`，该头公网客户端可任意伪造。审计实测 400 次各带不同 XFF → 全部 200，0 次 429，等于限流形同虚设 | 移除 XFF 回退，**只信 CF 边缘写入的 `CF-Connecting-IP`**；另加全局桶 `globalMaxRequests` 兜底。复验 700 次伪造 XFF → 600×200 + 100×429 |
| **鉴权失败不受限流**（HIGH） | 鉴权在限流之前，坏 key 可无限尝试并刷日志 | 限流提到鉴权之前；新增 `authFailMax`（默认 20）独立计数，超限直接 429。复验 60 次坏 key → 20×401 + 40×429 |
| **目录 ACL 过宽**（HIGH） | `Authenticated Users:(M)` 可读可改 `secrets\`、`proxy.js`、`API-KEY.txt` —— 本机任何账户可接管隧道、篡改代码 | `icacls /inheritance:r`，仅保留 当前用户 / SYSTEM / Administrators；`cert.pem` 设只读 |
| **账户级凭据残留在项目里**（MED） | `orig-cert.pem.bak` 含账户级 `apiToken`（可建删隧道、改 DNS） | 已删除该备份文件；DEPLOY 文档改为备份到**项目之外**、还原后立即删除；并说明 `cert.pem` 是登录凭据而非 TLS 证书 |
| **健康检查漏判上游**（MED） | 探针只看是否 401，Magpie 宕机时仍报「健康」 | 隧道改用 cloudflared 的 `/ready`（`Test-TunnelReady`）而非仅看进程存活；`Test-Magpie` 探测上游并在**状态变化时**记日志（不重启任何东西——重启代理不可能让 Magpie 回来） |
| **无超时/无 body 上限**（MED） | 慢连接可长期占用；公网可推任意大小 body | 加 `upstreamTimeoutMs`（默认 600s，超时 504）与 `maxBodyBytes`（默认 32MB，超限 413，含 chunked 流式分支）；上游 error 时只在响应未写完时才销毁连接，否则 413 会被 reset 掉 |
| **编码路径穿越**（MED） | `/v1/models/..%2fmagpie/limit` 会原样转发到上游，只靠 Magpie 自己拒绝 | 代理层直接拒绝含 `..`、`%2e`、`%2f`、`%5c`、`%00`、反斜杠的原始路径 |
| **日志无轮转 + 探针污染**（MED/LOW） | `proxy.log` 无上限增长；健康探针每 15s 写一行「bad key」淹没真实告警 | 加 `maxLogBytes`（8MB）轮转为 `.1`；探针请求带 `User-Agent: magpie-public-supervisor-healthcheck`，日志记为 `PROBE` 且不计入节流 |
| **`/v1beta/models` 被误拦**（MED） | 上游支持，代理白名单只有 `/v1beta/models/*`，Gemini SDK 首调 404 | 白名单补 `"/v1beta/models"` |
| **「Gemini 兼容」标注与实现不符**（MED） | 文档把 `/v1beta/models*` 标为「Gemini 兼容」，但代理只认 `Bearer`/`x-api-key`；Google SDK 默认发 `x-goog-api-key` → 一律 401，SDK 实际用不了（实测） | `presentedKey()` 增加 `x-goog-api-key`，转发前删除该头；实测三种头均可用、错 Key 仍 401、`?key=` 仍拒绝 |
| **上游对 `//` 返回 307**（LOW） | `/v1/models//magpie/limit` 被原样转发，Magpie 回 307 指向 `/v1/models/magpie/limit`（目标本身 404，未越权，但多出一条不该出现的重定向） | 原始路径含 `//` 直接 404（正常客户端不会发双斜杠）；实测该请求现为 404 |
| **推理模型 max_tokens 太小会返回空 content**（文档缺失） | `vendor-a/reasoning-model` 在 `max_tokens:16` 时 `content` 为空字符串——token 全用在 reasoning 上；客户端会误判为「接口坏了」。该模型还会额外返回 `reasoning_content` | README / DEPLOY 补充「推理模型建议 `max_tokens ≥ 64`，并说明 `reasoning_content` 字段」 |
| **致命日志可能写不进去**（LOW，可诊断性） | `server.listen` 端口被占时没有 `error` 监听，会以未捕获异常退出；且 `log()` 是异步写，紧跟 `process.exit()` 的 FATAL 行会整条丢失（实测日志为空） | 增加 `server.on("error")`；新增 `logSync()`（`appendFileSync`）专供退出路径；实测再监听 8790 → 日志留下 `FATAL server error EADDRINUSE`、退出码 1 |
| **`/v1/completions` 是死路由**（MED） | 上游本就没有该端点（直连 404），白名单却放行 | 从白名单移除 |
| **`start.cmd stop` 会杀掉自身**（MED） | 按命令行匹配会命中调用它的 shell | 排除自身及所有祖先进程（`$PID` 向上遍历） |
| **Key 轮换时机描述错误**（MED） | 文档称「旧 Key 立即失效」，实际有 5s 缓存，且 `settings.json` 读不到时会无限期沿用旧 Key | 文档改为「≤5 秒生效；读不到时沿用旧 Key 直到恢复」 |
| 限流键错误 | 原用 `req.socket.remoteAddress`，隧道流量全来自 loopback，所有调用方共用一个桶 | 见上，改为 `CF-Connecting-IP` + 全局桶 |
| 文档停止命令会误杀终端 | 只匹配命令行会连自己的 bash 一起杀 | 增加进程名白名单；`start.cmd` 再排除祖先进程 |
| 文档称「每次请求现读 Key」 | 实际有 5 秒缓存 | 文档改为「最多每 5 秒重读一次」 |
| 看门狗无单实例保护 | 多实例抢端口和日志，表现为「启动了但端口随即消失」 | `run/supervisor.lock` 独占句柄 |
| 看门狗循环无异常兜底 | 任何瞬时异常都会让脚本永久退出 | 主循环包 `try/catch` |
| metrics 端口多处硬编码 | `config.yml` 与 `run.ps1` 各写一份 | `run.ps1` 改为从 `config.yml` 读取（`Get-MetricsAddr`）；`start.cmd` 的 `METRICS` 仅用于状态展示与端口探测，改端口时需同步（已在 README / DEPLOY 列明） |
| 上游连接池导致 Magpie 重启后 502 | `keepAlive` 池保留失效连接，下一请求 ECONNRESET | `upstreamAgent = false`，每请求新建连接 |
| 限流阈值偏紧 | 240 次/分对长对话偏紧 | 提高到 600/分，全局 1800/分 |
| `start.cmd` 依赖 `timeout.exe` | Git Bash 下被解析为 Linux 版 | 改用 `Start-Sleep` |

## 关键命令与输出

### 1–4 鉴权

```
=== 1. direct 3425 no key (expect 200: proves loopback bypass) ===
200
=== 2. public no key (expect 401) ===
401
=== 3. public wrong key (expect 401) ===
401
=== 4. public correct key (expect 200) ===
200
```

### 6–7 管理面隔离

```
/v1/magpie/limit         404
/v1/magpie/admin/        404
/api/settings            404
/v1/magpie/quotas        404
/healthz     404
/            404
/admin       404
/v1/magpie   404
```

### 5 流式（时间戳递增，非一次性返回）

```
1795349156.385 : heartbeat
1795349156.494 data: {...  "content":"" ...
1795349156.655 data: {...  "content":"1" ...
1795349156.753 data: {...  "content":"," ...
1795349156.856 data: {...  "content":" " ...
1795349156.981 data: {...  "content":"2" ...
```

### 8 端口

```
TCP    127.0.0.1:3425          LISTENING
TCP    127.0.0.1:8790          LISTENING
TCP    127.0.0.1:20242         LISTENING
--- any 0.0.0.0 on 3425? ---
none (good)
```

### 隧道独立（两条并存）

```
ID                 NAME             CONNECTIONS
<this-tunnel-id>   magpie-public    4
<other-tunnel-id>  another-project  0
```

本项目有 **4 条 QUIC 连接**（`/ready` 报 `readyConnections: 4`；
`tunnel list` 的连接 ID 每次重连都会变，不必逐字比对）。
同机的另一条隧道当时未启动，两条隧道互不影响。

### 看门狗修复后的复验（21:30 起）

修复**前**，`supervisor.log` 每 15 秒一组（健康代理被反复强杀）：

```
21:27:25 proxy process alive but unresponsive; restarting
21:27:25 starting proxy on 127.0.0.1:8790
21:27:40 proxy process alive but unresponsive; restarting
21:27:40 starting proxy on 127.0.0.1:8790
```

修复**后**，21:30 之后的记录里 `restarting` 出现 **0 次**，`proxy.log` 每 15 秒一条探针记录：

```
2026-11-22T13:30:14.613Z PROBE bad key (supervisor healthcheck)
```

关键项复测（除注明外均经公网 `apimagpie.example.com`）：

```
1  direct-3425-no-key : 200
2  public-no-key      : 401
3  public-wrong-key   : 401
4  public-ok-bearer   : 200
4b public-ok-xapikey  : 200
6  admin / api ×4     : 404
7  healthz / / / admin / v1-magpie : 404
19 v1beta-models      : 200
17 traversal ×2       : 404
18 40MB body          : 413
14 20 sequential      : 20/20 × 200
5  SSE                : 约 50 ms 一块，逐块到达
```

限流两项改为直连代理、固定 `CF-Connecting-IP` 以便得到确定性计数
（经公网时每个请求约 1.7 s，60 次会跨越 60 秒窗口，计数被窗口重置切碎）：

```
60 次坏 key（同一调用方）          -> 20 × 401  + 40 × 429
700 次（同一调用方，XFF 每次不同） -> 600 × 200 + 100 × 429   (0.8 s)
```

第二条同时证明 `X-Forwarded-For` 完全不参与身份判定——否则 700 次应全部 200。

隧道侧：`GET http://127.0.0.1:20242/ready` → `{"status":200,"readyConnections":4,...}`。

### 端到端矩阵（21:52–22:02）

为了测「上游启停 × 代理启停」而不碰真实 Magpie（PID 15888 全程未动），
在 `%TEMP%` 下另起了一个 mock 上游（`127.0.0.1:3499`）与第二个代理实例（`127.0.0.1:8792`），
测完即删除，生产实例未参与。

#### 1. 停启顺序

```
代理先起、上游未起   -> 502
上游启动             -> 200    （代理 PID 26936 不变，无需重启）
上游停止             -> 502    （代理 PID 仍 26936）
上游重启             -> 200
代理重启（上游在跑） -> 200
```

#### 2. 请求头净化（mock 的 `/v1/models/echo` 回显）

```
authorization    : Bearer magpie-public
x-api-key        : (absent)
x-goog-api-key   : (absent)
x-forwarded-for  : (absent)
x-real-ip        : (absent)
cf-connecting-ip : (absent)
cf-ray           : (absent)
host             : 127.0.0.1:3499
在整份回显里搜索 "sk-magpie-key" -> 未出现
```

#### 3. 限流（打 mock，不消耗模型额度）

```
同一调用方 700 次  -> 600 × 200 + 100 × 429  (0.5 s)
1900 个不同调用方  -> 1800 × 200 + 100 × 429 (1.0 s)   ← 全局桶生效
```

#### 4. 协议 × 模型（真实公网 → 真实 Magpie）

| 请求 | 结果 |
|---|---|
| OpenAI chat，4 个模型，`max_tokens:16` | 4/4 **200**；`vendor-b` / `vendor-c` 返回 `PONG`；`reasoning-model` 的 `content` 为空、`reasoning-model-2` 返回被截断的特殊 token 串（内容略）——都是 token 预算被思考用光 |
| OpenAI chat，`vendor-a/reasoning-model`，`max_tokens:64` | **200**，`content:"PONG"` + `reasoning_content`，`reasoning_tokens 11` |
| OpenAI chat，`stream:true` | **200**，SSE 逐块（约 50 ms） |
| OpenAI `/v1/responses` | **200**，`object:"response"`，`output_text:"PONG"` |
| Anthropic `/v1/messages`（`max_tokens:64`） | **200**，blocks=`thinking,text`，text `"PONG"` |
| Anthropic stream | **200**，`message_start` / `content_block_start` 逐事件到达 |
| Anthropic `count_tokens` | **200**，`input_tokens:87` |
| Anthropic `?beta=true` 查询串 | **200**（查询串正确透传） |
| Anthropic `thinking` budget 1024 | **200**，text `"391"`，`thinking_tokens 29` |
| Gemini `generateContent`（thinkingBudget 0 / 1024） | **200** / **200**（后者 `thoughtsTokenCount 9`） |
| Gemini `streamGenerateContent?alt=sse` | **200**，逐块到达 |

#### 5. 思考强度

| 参数 | 结果 |
|---|---|
| OpenAI `reasoning_effort: "low"` / `"high"` | 均 **200**，content `"391"`，`reasoning_tokens` **17 / 18** |
| Anthropic `thinking:{type:"enabled",budget_tokens:1024}` | **200**，`thinking_tokens 29` |
| Gemini `thinkingConfig.thinkingBudget: 0` / `1024` | **200 / 200**，后者 `thoughtsTokenCount 9` |

> 观察：`reasoning_effort` 被上游接受且不报错，但 low/high 的 reasoning_tokens 只差 1（17/18），
> 说明这个上游/模型并没有按档位显著改变思考量——参数透传成功，但效果不保证。

#### 6. 多模态（同一张 64×64 左红右蓝图，三种格式）

| 格式 | 结果 |
|---|---|
| OpenAI `image_url`（data URL） | **200**；模型在 `reasoning_content` 里描述「red left blue right」 |
| Anthropic `image`（base64） | **200**，text `"Red blue"` |
| Gemini `inlineData` | **200**；描述「left red, right blue」 |

#### 7. 并发混合协议

11 个并发请求（4 模型 chat + responses + 2×messages + 2×generateContent + 两个 models 列表）
→ **11/11 × 200**，总耗时 7.2 s。

#### 8. 错误透传

```
未知模型  -> 404  {"error":{"message":"magpie knows no model \"no/such-model\" ..."}}
坏 JSON   -> 400  {"error":{"message":"invalid request: invalid character 'n' ..."}}
```

上游的状态码与错误体原样到达客户端（代理不吞错、不改写）。

#### 9. 长上下文 32k × 启停 × 协议/思考/多模态

固定载荷 **180,229 字符**（约 **3.2 万 token**），在正中间埋一行
`IMPORTANT RECORD: the test marker is MAGPIE-NEEDLE-7F3A`，末尾要求只回代码。

> 说明：`MAGPIE-NEEDLE-7F3A` 是测试用暗号，不是密钥。

| 组合 | prompt tokens | 结果 |
|---|---|---|
| OpenAI chat · `vendor-b/vision-model` · `reasoning_effort: high` | **31,869** | **200**，`content:"7F3A"`，17.5 s |
| Anthropic messages · `vendor-a/reasoning-model` · `thinking` 1024 | **31,912** | **200**，blocks=`thinking,text`，text `"7F3A"`，18.2 s |
| Gemini `generateContent` · `vendor-c/vision-model-large` · `thinkingBudget: 0` | ≈32k | **200**，文本含 `7F3A`，16.8 s |
| OpenAI chat · `vendor-a/reasoning-model-2` · 32k **+ 8×8 绿色图** | **31,953** | **200**，`content:"7F3A / green"`，50.6 s（暗号与图片颜色都对） |

启停交叉（请求体固定 180 KB，mock 用于不消耗额度的那半边）：

| 场景 | 结果 |
|---|---|
| mock 上游未起，代理在跑 | **502** |
| mock 上游启动后（代理**不重启**） | **200**，`receivedBytes: 180055`（与文件字节数一致），代理 PID 不变 |
| 临时实例代理重启（上游在跑） | **200**，仍完整收到 180,055 字节 |
| 生产栈 `stop` 后公网请求 | Cloudflare **502**（`error code: 502`） |
| 生产栈 `start` 后同一请求 | 请求到达 Magpie（返回它的「未知模型」404，说明链路已通）；换真实模型重跑 32k → **200**、`7F3A` |
| 32k 请求**进行中** `stop` 服务 | 客户端收到 **502**（10.8 s 时中断）；随后 `start` → `/ready` **200**、新请求 **200** |

> 结论：长上下文、180 KB 请求体在「任一组件随时启停」下都能正确透传；
> 唯一会丢的是**正在传输中**的那一个请求（停服务必然中断），重启后立即恢复。

## 未做的改动（按约束）

- 未修改 Magpie 的 `settings.json` / `providers.json` / 任何配置
- 未停止或重启 Magpie（PID 15888 全程存活）
- 未修改同机其他隧道项目的 `config.yml` / 凭据 / 脚本 / 二进制
- 未开启 Magpie 的「Share on local network」（会把 3425 绑到局域网，扩大暴露面）
- 未启动 `magpie web`(3430)
- `~/.cloudflared/cert.pem` 已还原为原始内容（哈希一致）

## 审计报告中经实测否定的一条

审计建议用 `TUNNEL_ORIGIN_CERT` 环境变量让 `tunnel login` 直接写入项目目录，
从而省掉「移走 `~/.cloudflared/cert.pem` → 登录 → 还原」的步骤。

**实测否定**：

```
$ TUNNEL_ORIGIN_CERT="D:\nonexistent-test\cert.pem" cloudflared tunnel login
ERR You have an existing certificate at C:\Users\<user>\.cloudflared\cert.pem
    which login would overwrite.
```

`tunnel login` 不读 `TUNNEL_ORIGIN_CERT`（该变量只被 `create` / `route` / `run` 识别），
所以登录必须落在默认路径。文档保留「备份 → 移走 → 登录 → 复制 → 还原」流程，
并在 DEPLOY-OTHER-MACHINE.md 4.1 节注明该变量对 login 无效。
