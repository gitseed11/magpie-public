# Magpie 公网推理 API

把本机 Magpie 的推理接口，经 Cloudflare 隧道发布为一个**必须携带 API Key** 的公网服务。

- 公网地址：`https://apimagpie.example.com/v1`（示例值，换成你自己的域名）
- 上游：本机 Magpie `http://127.0.0.1:3425`（**未做任何改动**）
- 与机器上已有的其他隧道完全独立：不同隧道、不同凭据、不同 metrics 端口、不同目录。

状态：已在作者本机部署并验证通过（2026-11-22）。本仓库是**脱敏后的开源版本**：
域名、隧道 ID、本机路径与密钥均为占位符，按 `DEPLOY-OTHER-MACHINE.md` 替换成你自己的即可。

---

## 1. 为什么需要中间这层代理

Magpie 只监听 `127.0.0.1:3425`，并且**对来自 loopback 的请求故意不校验 gateway key**
（本机 Codex / Claude Code / ZCode 就是这样直接调它的）。

Cloudflare 隧道是从 **loopback** 连到 Magpie 的，所以：

> 如果把隧道直接指向 `127.0.0.1:3425`，公网任何人都能在**不带 Key** 的情况下调用你的模型额度。

实测确认：`curl http://127.0.0.1:3425/v1/models`（不带任何 Key）返回 `200`。

因此本目录的 `proxy.js` 补上了这层门：

```
公网 → Cloudflare(apimagpie.example.com)
     → cloudflared（隧道 magpie-public，metrics 127.0.0.1:20242）
     → 127.0.0.1:8790  proxy.js  ← 只绑 loopback
            ├─ 必须带 lanKey（Bearer / x-api-key / x-goog-api-key），否则 401
            ├─ 仅放行推理路由，其余 404
            ├─ SSE 流式不缓冲
            └─ 按调用方每分钟 600 次限流（全局 1800；取 CF-Connecting-IP）
     → 127.0.0.1:3425  Magpie（完全不动）
```

由此满足三条硬要求：

| 要求 | 实现 |
|---|---|
| 推理 API 与管理面**不同端口** | 公网只到 8790；管理面仍在 3425 |
| 管理面板**只能本机访问** | `/v1/magpie/**`、`/api/**` 在代理处直接 404，永不出本机 |
| 公网请求**必须带 API Key** | 代理强制校验，不依赖 Magpie 的 loopback 豁免 |

Magpie 的管理面板是 WebView2 窗口（虚拟源 `wails.localhost`，不占 TCP 端口），
`magpie web`（3430）保持不启动——所以管理面依旧只能在本机点开 GUI。

---

## 2. API Key

**不额外生成**，直接复用 Magpie 自己随机生成的 `lanKey`：

```
C:\Users\YOUR_USERNAME\.config\magpie\settings.json  →  "lanKey": "sk-magpie-key-..."
```

（把 `YOUR_USERNAME` 换成你的 Windows 用户名；`config.json` 的 `settingsPath` 要同步改。）

代理直接读取该文件中的 `lanKey` 做校验（最多每 5 秒重读一次，`lanKeyCacheMs`），
`proxy.js` 本身**不写任何密钥到磁盘**（`API-KEY.txt` 是另一个脚本为方便人查看而生成的，
见下）。Magpie 若轮换 Key，客户端需同步换成新 Key；
代理会在 `logs/proxy.log` 打 `WARN lanKey changed`。

支持三种鉴权头，**任一即可**，值都必须是 `lanKey`：

| 头 | 典型客户端 |
|---|---|
| `Authorization: Bearer <key>` | OpenAI SDK / curl |
| `x-api-key: <key>` | Anthropic SDK |
| `x-goog-api-key: <key>` | Google GenAI SDK（Gemini） |

> 不支持把 Key 放进查询串（`?key=...`）：那会出现在 URL 与边缘日志里，实测返回 401。

另有一个供人查看的 `API-KEY.txt`，由 `sync-key.ps1` 自动同步（见下）。
**该文件含明文 Key，建议把 ACL 收紧到仅当前用户 / SYSTEM / Administrators（见 DEPLOY 4.6）。**

查看当前 Key：

- **最快方式**：直接打开 `D:\magpie-public\API-KEY.txt`
  （由看门狗每轮循环（约 15 秒）同步，key 变化时自动更新，删掉也会自动重建）
- 命令行：`(Get-Content "$env:USERPROFILE\.config\magpie\settings.json" -Raw | ConvertFrom-Json).lanKey`

> Magpie 的 GUI 里看不到 `lanKey`（界面上的 gateway key 是另一套机制）。
> 它只存在于 `settings.json` 的 `lanKey` 字段（同文件的 `lanKeyId` 只是标识符，不是密钥）。

### 客户端用法

```bash
curl https://apimagpie.example.com/v1/models \
  -H "Authorization: Bearer sk-magpie-key-..."
```

```python
# OpenAI 兼容：base_url 要带 /v1
from openai import OpenAI
client = OpenAI(
    base_url="https://apimagpie.example.com/v1",
    api_key="sk-magpie-key-...",
)
```

```python
# Anthropic 兼容：base_url 不带 /v1（SDK 自己拼 /v1/messages，并自动发 x-api-key）
from anthropic import Anthropic
client = Anthropic(
    base_url="https://apimagpie.example.com",
    api_key="sk-magpie-key-...",
)
```

```bash
# Gemini 兼容（原生 REST；Google SDK 也发这个头，把 base URL 指到本域名即可）
curl "https://apimagpie.example.com/v1beta/models/vendor-b/vision-model:generateContent" \
  -H "x-goog-api-key: sk-magpie-key-..." \
  -H "content-type: application/json" \
  -d '{"contents":[{"parts":[{"text":"hi"}]}]}'
```

模型名用 `GET /v1/models` 返回的 `id`，例如 `vendor-a/reasoning-model`、
`vendor-b/vision-model`。Gemini 路由用 `GET /v1beta/models` 返回的 `name`。

#### base URL 与路径前缀

三种协议对 base URL 的前缀要求不同，写错会在代理层直接得到 **404**（日志里是
`DENY path not allowed`），请求根本不会转发给 Magpie，也不消耗模型额度：

| 客户端 | base URL 应该写成 | SDK 之后自己拼的路径 |
|---|---|---|
| OpenAI 兼容 | `https://apimagpie.example.com/v1` | `/chat/completions`、`/responses`、`/models` |
| Anthropic | `https://apimagpie.example.com` | `/v1/messages`、`/v1/messages/count_tokens` |
| Gemini | `https://apimagpie.example.com` | `/v1beta/models/…` |

用 `curl` 时把前缀写全，例如 `POST /v1/chat/completions`、`POST /v1/responses`。
白名单是**精确匹配**的：`/responses`、`/chat/completions` 这类缺 `/v1` 的路径一律
404——这也是实际测试里最容易踩的一条（表现为客户端报 404，但服务本身完全正常）。

> **推理型模型注意**：`vendor-a/*` 会先把 token 花在思考上，`max_tokens` 太小时
> 输出会被思考吃掉——实测 `vendor-a/reasoning-model` 在 `max_tokens:16` 时 `content` 为空、
> `max_tokens:64` 返回 `PONG`；同一家族的另一个变体在 16 时返回被截断的特殊 token 串。
> 这类模型的思考文本在 `reasoning_content` 字段。建议 `max_tokens ≥ 64`。
> 思考量可用 `reasoning_effort`（OpenAI 风格）/ `thinking.budget_tokens`（Anthropic）/
> `thinkingConfig.thinkingBudget`（Gemini）调整——参数会被透传，但模型是否严格按档位
> 改变思考量取决于上游，实测 low/high 差异很小。

---

## 3. 放行的路由

`config.json` 的 `allowedPaths`：

```
/v1/models            /v1/models/*
/v1/chat/completions  /v1/responses
/v1/messages          /v1/messages/count_tokens
/v1beta/models        /v1beta/models/*        （Gemini 兼容）
```

其余一律 `404`，包括 `/v1/magpie/**`、`/api/**`、`/healthz`。

> `/v1/completions` 不在列表里：Magpie 本身没有这个端点（直连 3425 实测 GET/POST 都 404），
> 放行只会让客户端以为可用。

> **Gemini 兼容**：`GET /v1beta/models` 与
> `POST /v1beta/models/<model>:generateContent` 均实测可用（返回标准 Gemini 结构），
> 鉴权用上表的三种头之一。只有查询串 `?key=` 形式不被接受。

### 协议透明性

本代理**不定义自己的协议**，也不实现任何「中转格式」：它只说标准 HTTP/1.1，
请求体与响应体（含 SSE）**原样透传**——不解析、不改写、不重新序列化 JSON。
OpenAI / Anthropic / Gemini 的字段、状态码、自定义字段（如 `reasoning_content`）
都保持上游原样，SDK 不需要适配层。

代理只做两类必要改动，**都不涉及消息体**：

1. 转发前规范化请求头：`Host` 改为上游地址；`Authorization` 换成调用方标识
   （公网 Key 不上行）；删掉 `x-api-key` / `x-goog-api-key` / `cf-*` / `x-forwarded-*`
   和逐跳头（`connection` / `keep-alive` / `transfer-encoding` / `content-length`）。
2. 对 SSE 响应设置 `cache-control: no-cache, no-transform` 与 `x-accel-buffering: no`
   （上游本身也带这两个头；**Cloudflare 回程会过滤掉 `x-accel-buffering`**，
   实际起作用的是 `cache-control` 与流式传输本身）；其余响应头保持上游原样。

代理自己产生的响应只有：标准状态码（`400` / `401` / `403` / `404` / `413` / `429` / `502` / `503` / `504`）
+ OpenAI 风格的最小错误 JSON（`{"error":{"message":…,"type":…}}`），
并按 HTTP 规范带 `www-authenticate` / `retry-after`。不加自定义头、不注入字段、不做内容转换。
（`400` 用于畸形请求，`403` 用于非 loopback 来源；正常推理请求不会触发这两类。）

---

## 4. 文件

| 文件 | 作用 |
|---|---|
| `proxy.js` | 零依赖 Node 鉴权反向代理 |
| `config.json` | 端口 8790、上游、白名单、限流 |
| `config.yml` | cloudflared 隧道配置（隧道 ID + 凭据 + ingress） |
| `API-KEY.txt` | **自动同步的当前 Key**，方便查看（由 `sync-key.ps1` 维护，非手写副本） |
| `sync-key.ps1` | 从 `settings.json` 读取 `lanKey` 写入 `API-KEY.txt`，仅变化时写盘 |
| `bin/cloudflared.exe` | 官方 cloudflared 的本地副本（2026.11.0，SHA-256 `d5c1d820…`） |
| `secrets/cert.pem` | **Cloudflare 登录凭据**（`ARGO TUNNEL TOKEN`，内含账户级 `apiToken`，等同密码，只读） |
| `secrets/<tunnel-id>.json` | 隧道凭据，**保密** |
| `start.cmd` | 启动 / 停止 / 查看状态（唯一入口） |
| `stop.cmd` | **只停公网这一侧**（代理 + 隧道 + 看门狗），独立可用；比 `start.cmd stop` 更完整（校验 8790 + 20242、幂等、失败退出 1） |
| `run.ps1` / `launch.vbs` | 看门狗 + 隐藏启动 |
| `logs/` | 运行日志 |
| `LICENSE` | MIT 许可证 |
| `package.json` | Node 元数据（`npm start` 只启动代理，不含看门狗） |

隧道名：**`magpie-public`**（隧道 ID 与凭据文件按 `config.yml` / `secrets/` 配置）

### 版本控制

本目录是一个独立 git 仓库（分支 `main`）。开源副本的 `.git` 是**重新初始化**的，
历史里没有包含真实域名、隧道 ID、本机用户名或凭据的提交。

**入库**：`proxy.js`、`config.json`、`config.yml`、`run.ps1`、`launch.vbs`、
`start.cmd`、`stop.cmd`、`sync-key.ps1`、文档、`LICENSE`、`package.json`、
`.gitignore`、`.gitattributes`、`bin/README.md`。

**不入库**（`.gitignore`）：

| 路径 | 原因 |
|---|---|
| `secrets/` | 账户级 `cert.pem`（含 apiToken）与隧道凭据 |
| `API-KEY.txt` | 明文 `lanKey`（会自动重建） |
| `logs/`、`run/` | 日志、pid、单实例锁 |
| `bin/*.exe` | 第三方二进制（约 55 MB），版本与 SHA-256 记在 `bin/README.md` |

克隆/恢复后还需要补：按 `bin/README.md` 放回 `cloudflared.exe`；按 `config.yml`
填入隧道 ID、凭据文件与域名；准备 `secrets/cert.pem` 和隧道凭据；让 Magpie 生成
`lanKey`（见第 2 节）。完整步骤见 `DEPLOY-OTHER-MACHINE.md` 第 2–6 节。
提交身份与远程仓库按需用 `git config user.name/user.email` 和
`git remote add origin …` 设置。

---

## 5. 运维

### 启动 / 停止 / 状态（纯手动）

**不设置任何开机自启**。启动与查状态用 `start.cmd`；停止推荐直接双击独立的
`stop.cmd`。两者都会停代理/隧道/看门狗且绝不动 Magpie，但 `stop.cmd` 更完整：
它核对 8790 与 20242、没在运行时明确提示、失败退出 1；`start.cmd stop` 只核对 8790，失败也返回 0。

> 目录名需保持 `magpie-public`：`start.cmd` / `stop.cmd` 用 `*magpie-public*` 匹配本项目进程，改名后停止脚本会匹配不到。

| 操作 | 命令 |
|---|---|
| 启动 | 双击 `start.cmd`，或 `cmd /c start.cmd` |
| 停止 | 双击 `stop.cmd`，或 `cmd /c stop.cmd` / `cmd /c start.cmd stop` |
| 查看状态 | `cmd /c start.cmd status` |

`stop.cmd` 是幂等的：没在运行时会打印 `[i] Nothing was running.` 并以 0 退出；
它会核对 8790 / 20242 是否真的释放，并明确告诉你 Magpie 仍在 3425 上运行（未被触碰）。

`start.cmd` 启动后会打印代理端口、metrics 端口、公网地址与 Magpie 是否在线。

`start.cmd status` 还会显示 `Watchdog`（看门狗进程）是否在跑。若出现「端口在监听但
`Watchdog: STOPPED`」——这是手工杀进程留下的孤儿状态，隧道若挂掉就没有人重启它——
先 `start.cmd stop` 再 `start.cmd`。

> `stop` 会中断**正在传输中**的请求（客户端收到 502）；重启后新请求立即恢复。
> 代理不做请求重放，所以长推理请求请等服务空闲时再停。

**启动顺序无所谓**：
- 先启动 Magpie 再运行 `start.cmd` → 立刻可用
- 先运行 `start.cmd` 再启动 Magpie → 代理每次请求都新建到 3425 的连接，
  Magpie 一上线即自动可用，**不需要重启代理或隧道**

> 代理刻意**不使用连接池**（`upstreamAgent = false`）。否则 Magpie 重启后
> 池中残留的死连接会让下一次请求报 502，即使 Magpie 已经正常。

### 日志

| 文件 | 内容 |
|---|---|
| `logs/proxy.log` | 每个请求一行（放行/拒绝原因、状态码、耗时）；超过 8 MB 轮转为 `.1` |
| `logs/proxy.out.log` / `proxy.err.log` | 代理的 stdout/stderr（正常时为空——代理只写 `proxy.log`） |
| `logs/cloudflared.err.log` | 隧道日志（cloudflared 把 INFO 日志写到 **stderr**，所以内容在这里；`.out.log` 通常为空） |
| `logs/supervisor.log` | 看门狗启停、重启、Magpie 可达性变化；超过 4 MB 轮转为 `.1` |

### 检查存活

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:8790/v1/models
# 期望 401（说明代理活着，且在拒绝无 Key 请求）
```

### 轮换 Key

`lanKey` 由 Magpie 自动生成，**GUI 里没有直接修改它的入口**。实际可行的轮换方式是
编辑 `settings.json` 的 `lanKey` 字段（先退出 Magpie，改完再启动，避免被覆盖），
或删除该字段让 Magpie 重新生成。

改完后：

- 代理在 **≤5 秒**内读到新值，无需重启；
- 若 `settings.json` 一时读不到（Magpie 正在重写），代理会**继续沿用旧 Key**
  直到能读到为止——这是刻意的容错，不是立即失效；
- `API-KEY.txt` 会在下一轮同步时更新。

验证：旧 Key 返回 401、新 Key 返回 200。

### 重建隧道

若隧道被删除：

```powershell
cd "D:\magpie-public"
.\bin\cloudflared.exe tunnel --origincert "secrets\cert.pem" create magpie-public
.\bin\cloudflared.exe tunnel --origincert "secrets\cert.pem" route dns magpie-public apimagpie.example.com
# 然后按新隧道 ID 更新 config.yml 的 tunnel / credentials-file
```

> `tunnel create` 会打印新凭据文件名，记得同步 `config.yml`。

### 回滚

```powershell
# 1. 停服务
cmd /c stop.cmd          # 推荐；start.cmd stop 是简化版，校验较少

# 2. 确认没有遗留计划任务（纯手动模式本就没有）
Unregister-ScheduledTask -TaskName 'MagpiePublicAPI' -Confirm:$false -ErrorAction SilentlyContinue
```

再删除 DNS 记录与隧道：

```powershell
cd "D:\magpie-public"
.\bin\cloudflared.exe tunnel --origincert "secrets\cert.pem" delete magpie-public
```

最后删除 `D:\magpie-public\`。全程不需要改动 Magpie 或机器上的其他项目。

---

## 6. 与同机其他 cloudflared 项目共存

如果这台机器上已经有别的项目在跑 cloudflared（很常见），按下面几项隔离开即可。
两条隧道是彼此独立的进程，一条重启不影响另一条：

| 项 | 要求 | 本项目示例 |
|---|---|---|
| 目录 | 各自独立 | `D:\magpie-public` |
| 隧道 | 各自创建，不共用 | `magpie-public` |
| 凭据 | 各自的 `<tunnel-id>.json` | `secrets\<tunnel-id>.json` |
| 登录凭据 | 各自的 `cert.pem` 副本，或复用同一账户的登录凭据 | `secrets\cert.pem` |
| metrics 端口 | 各用不同端口（如 20241 / 20242 / 20243） | `127.0.0.1:20242` |
| 代理端口 | 各用不同端口 | `127.0.0.1:8790` |

`cloudflared.exe` 可以是同一个二进制文件的副本，互不影响；只要**配置、凭据、
metrics 端口**不共享即可。

> 如果另一个项目也把上游指向 `127.0.0.1:3425`（同一个 Magpie），本项目不改变这一点；
> 两条链路各自鉴权、各自限流。

### 关于 `~/.cloudflared/cert.pem`

`cloudflared tunnel login` 只能写入 `~/.cloudflared/cert.pem`，且拒绝在已有文件时覆盖。
如果机器上已有别的项目登录过，登录时把原文件临时移走（备份在**项目外的临时路径**），
取得新证书后**原样还原**；备份用完即删——它是账户级凭据（含 `apiToken`），
不该长期留在项目里。本隧道运行时只用 `secrets/cert.pem` 这份独立副本，
`~/.cloudflared` 与本项目无运行时依赖。

---

## 7. 安全验证记录

见 `VERIFY.md`。

---

## 8. License

MIT，见 `LICENSE`。
