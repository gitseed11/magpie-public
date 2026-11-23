# Magpie 公网推理 API

把本机 Magpie 的推理接口经 Cloudflare Tunnel 发布为一个**必须携带 API Key** 的公网服务，同时让 Magpie 管理面、密钥文件和本机控制面板保持不可从公网访问。

- 公网 OpenAI base URL：`https://apimagpie.example.com/v1`
- 认证代理：`http://127.0.0.1:8790`
- 独立上游：`http://127.0.0.1:3425`
- 默认纯手动启停，不注册开机自启；启停公网侧绝不停止 Magpie 或其他 Tunnel 项目。

当前版本：**v2.2.0**。实测记录见 `VERIFY.md`，标签发布说明见 `RELEASE.md`。

本仓库是脱敏后的开源版本：域名、Tunnel ID、本机路径与密钥均使用占位符或本机环境变量；按 `DEPLOY-OTHER-MACHINE.md` 替换为自己的配置即可。

---

## 1. 安全边界

Magpie 对 loopback 请求故意免 gateway key。cloudflared 也是从 loopback 连接上游，所以**不能让 Tunnel 直接指向 3425**，否则公网会继承本机免鉴权。

实际链路固定为：

```text
公网 → Cloudflare(apimagpie.example.com)
     → cloudflared（metrics 127.0.0.1:20242）
     → 127.0.0.1:8790  proxy.js
             ├─ 每个被放行的请求都必须通过 lanKey 鉴权
             ├─ 方法 + 路径白名单，其余 404
             ├─ 55 MiB 请求体上限、限流、上游超时、SSE 流式透传
             └─ 删除公网 Key，再向 127.0.0.1:3425 转发
```

`proxy.js` 和 `common.ps1` 都拒绝非显式 loopback 的监听/上游配置；upstream 还必须是根 URL，不能带路径、查询串、userinfo 或 hash。`config.yml` 的 metrics 只允许 loopback，ingress 中除末尾 `http_status:404` fallback 外的**每一条** service 都必须精确等于代理 listener，不能靠保留第一条合法规则追加旁路。每条规则必须恰好有一个未加引号的 block-style `service`；带引号键、flow collection、anchor/alias/merge key 等未支持 YAML 形式直接拒绝，绝不静默跳过。管理路径 `/v1/magpie/**`、`/api/**`，以及 `/secrets/**`、`/API-KEY.txt` 等文件路径不在白名单中，带正确 Key 也不会被转发。

Magpie GUI 使用本机 WebView2；本项目的控制面板是普通 WinForms 窗口，**不监听 TCP 端口，不经过 cloudflared，也不并入 8790**。

## 2. API Key

直接复用 Magpie 自动生成的 `lanKey`：

```text
%USERPROFILE%\.config\magpie\settings.json → lanKey
```

`proxy.js` 正常每 5 秒重读一次（`lanKeyCacheMs=5000`）。设置文件不可读或其中没有有效 `lanKey` 时，缓存 Key 最多沿用 5 分钟（`lanKeyMaxStaleMs=300000`）；失败读取由 2 秒负缓存节流（`lanKeyRetryMs=2000`），不会在每个请求上同步等待。超过最大陈旧时间仍读不到有效 Key 就返回 503 并拒绝转发；文件恢复后自动恢复，新进程没有缓存时始终 fail-closed。看门狗把 503 视为“进程存活、Key 不可用”，**不会因此重启代理**。

支持三种请求头，任一有效值即可：

| 请求头 | 客户端 |
|---|---|
| `Authorization: Bearer <key>` | OpenAI / curl |
| `x-api-key: <key>` | Anthropic |
| `x-goog-api-key: <key>` | Google GenAI |

不接受查询串 `?key=`：只有查询 Key 而无有效请求头时返回 401；带有效请求头但仍包含 `key` 查询参数时返回 400，绝不转发到 Magpie。转发前会删除三种公网鉴权头，并把 `Authorization` 替换为固定调用方标识，避免公网 Key 进入 Magpie 使用日志。Cloudflare 边缘在请求到达本机前已经看到完整 URL，因此客户端仍**绝不能**把秘密放入查询串。

鉴权失败节流只统计**携带了错误 Key** 的请求：未携带 Key 的 401 不计入（否则任意网页可用跨站 no-cors 请求锁死某个出口 IP），成功鉴权会清零该来源的计数。同一来源在一个窗口内累计 20 次错误 Key 后，连正确 Key 也会收到 429，直到窗口结束。

`API-KEY.txt` 是方便本机查看的明文副本，由 `sync-key.ps1` 自动同步。代理和同步脚本共同使用 `config.json.settingsPath`；未配置时才回退到 `%USERPROFILE%\.config\magpie\settings.json`。Key 不可用或为空时会删除陈旧副本；Key、Endpoint、Source 任一变化都会原子更新。本机明文是刻意设计，ACL 应只允许当前用户、SYSTEM、Administrators。

已知架构限制：所有公网客户端共享同一个 Magpie `lanKey`，没有按客户端独立吊销、独立配额或 Key 所有者识别。轮换会影响所有显式使用该 Key 的公网客户端；依赖 Magpie loopback 免鉴权的本机客户端不受影响。缓存语义也不等于即时吊销。

### 客户端示例

```powershell
$key = (Get-Content "$env:USERPROFILE\.config\magpie\settings.json" -Raw | ConvertFrom-Json).lanKey
curl.exe https://apimagpie.example.com/v1/models -H "Authorization: Bearer $key"
```

```python
from openai import OpenAI
client = OpenAI(base_url="https://apimagpie.example.com/v1", api_key="<lanKey>")
```

```python
from anthropic import Anthropic
# SDK 自己拼 /v1/messages，所以 base_url 不带 /v1。
client = Anthropic(base_url="https://apimagpie.example.com", api_key="<lanKey>")
```

```powershell
curl.exe "https://apimagpie.example.com/v1beta/models/<model>:generateContent" `
  -H "x-goog-api-key: $key" -H "content-type: application/json" `
  -d '{"contents":[{"parts":[{"text":"hi"}]}]}'
```

路径前缀写错会在代理层得到 404，不会到达 Magpie：

| 协议 | base URL |
|---|---|
| OpenAI | `https://apimagpie.example.com/v1` |
| Anthropic | `https://apimagpie.example.com` |
| Gemini | `https://apimagpie.example.com` |

## 3. 方法与路由白名单

`config.json.allowedRoutes` 同时约束方法和路径；`*` 只允许非空模型 ID，模型 ID 内可以含 `/`。`config.json.maxBodyBytes` 与 `proxy.js` 的缺省回退值统一为 **55 MiB（57,671,680 字节）**，同时覆盖声明长度和 chunked 实际流量（上游提前结束响应时直接关闭连接，见本节第 4 条）。

限流分为三层：每个调用方（`CF-Connecting-IP`）一个 `maxRequests` 窗口配额；通过鉴权的请求另受 `globalMaxRequests` 全局配额约束；未鉴权的拒绝类响应（未知路径、缺失/错误 Key、超限声明、`lanKey` 不可用的 503）使用独立的 `globalMaxRequests × 10` 上限，只用于限制探测与日志洪泛，**不占用已鉴权配额**。数值配置项必须是正数（`listenPort` 还必须是 1–65535 的整数），`0`、负值或非数字会被 `proxy.js` 和 `common.ps1` 双方在启动前拒绝，避免看门狗反复重启一个必然失败的配置。

| 方法 | 路径/动作 |
|---|---|
| GET、HEAD | `/v1/models`、`/v1/models/*` |
| POST | `/v1/chat/completions`、`/v1/responses` |
| POST | `/v1/messages`、`/v1/messages/count_tokens` |
| GET、HEAD | `/v1beta/models`、`/v1beta/models/*` |
| POST | `/v1beta/models/*:generateContent` |
| POST | `/v1beta/models/*:streamGenerateContent` |
| POST | `/v1beta/models/*:countTokens` |

其余方法和路径统一 404。请求路径中的 `..`、`..;`、编码点/斜杠/冒号/分号、NUL、反斜杠、分号和 `//` 也会在代理层拒绝。

代理不解析或重写 JSON 消息体；请求与响应体（含 SSE）原样透传。它会：

1. 规范化 `Host` 和调用方标识，删除公网 Key、CF/XFF、`Forwarded`、常见 client-ip 来源头以及 URL/method 覆盖头；
2. 删除标准逐跳头以及 `Connection` 动态列出的所有头；请求重新生成 framing；
3. 为 SSE 设置 `cache-control: no-cache, no-transform` 和 `x-accel-buffering: no`（Cloudflare 回程可能过滤后者）；
4. 若上游在请求体接收完成前就返回并结束响应（例如快速拒绝），关闭该连接而不是继续读取剩余请求体；客户端可能看到连接提前结束，属于预期行为。

## 4. 文件与版本控制

| 文件 | 作用 |
|---|---|
| `proxy.js` | 零依赖 Node 鉴权反向代理 |
| `config.json` | 端口、上游、Key 来源、方法/路由、资源限制 |
| `config.yml` | cloudflared Tunnel、DNS hostname、ingress、metrics |
| `common.ps1` | 配置校验、精确进程归属、健康检查共享函数 |
| `control.ps1` | 唯一起停/状态实现，支持文本和 JSON |
| `run.ps1` | 单实例看门狗、异常重启、Key 同步、日志维护 |
| `start.cmd` / `stop.cmd` | `control.ps1` 的兼容命令行包装 |
| `launch.vbs` | 隐藏启动看门狗 |
| `panel.ps1` / `panel.cmd` | 本机 WinForms 控制面板及双击启动器 |
| `sync-key.ps1` | 同步当前 Key 到 `API-KEY.txt` |
| `bin/cloudflared.exe` | 固定版本第三方二进制，版本和 SHA-256 见 `bin/README.md` |
| `secrets/<tunnel-id>.json` | 仅当前 Tunnel 的运行凭据 |
| `API-KEY.txt` | 本机明文 Key，自动同步 |
| `logs/`、`run/` | 日志、PID、单实例锁 |

**账户级 `cert.pem` 不属于运行目录**。它仅用于创建、删除、重建 Tunnel 以及写入 DNS 路由，保存在：

```text
%USERPROFILE%\.config\magpie-public\cert.pem
```

按 UUID 执行 `cloudflared tunnel run` 只需要 `secrets/<tunnel-id>.json`，不需要账户级证书。若无需保留管理凭据，也可以删除该证书，以后重新 login。

`.gitignore` 排除 `secrets/`、`API-KEY.txt`（含原子写临时文件）、日志/PID、证书与私钥（`*.pem`、`*.key`、`*.crt`、`*.pfx`、`*.p12`）、`.env*` 和 `bin/*.exe`。克隆后需重新放置二进制和 Tunnel 凭据，并按目标机修改 `settingsPath`、Tunnel ID、hostname 与 credentials-file；不要提交真实 Key 或账户凭据。

## 5. 启停与控制面板

### 命令行

在项目目录执行：

```cmd
start.cmd            rem 启动
start.cmd status     rem 状态
stop.cmd             rem 停止；推荐
start.cmd stop       rem 与 stop.cmd 完全等价
start.cmd restart    rem 重启公网侧
```

所有入口都调用 `control.ps1`。进程归属由 **PID 文件 + 完整路径复核 + 精确路径孤儿枚举**确定，不再按目录名子串批量杀进程。手工以 `node proxy.js`、`-File .\run.ps1` 等相对路径启动的实例因无法可靠验证工作目录而不受管理；请只使用上述标准入口，不能为了识别它们而放宽匹配。`stop` 即使遇到配置语法错误或 ingress 绑定错误，也仍按本目录精确归属停止；`start` 和纯 `status` 继续严格校验配置。

状态语义：

| 状态 | 含义 | `status` 退出码 |
|---|---|---:|
| `ready` | 看门狗、代理鉴权、Tunnel ready、Magpie 均可达 | 0 |
| `waiting-upstream` | 公网侧正常，仅 Magpie 3425 不可达 | 0 |
| `degraded` | 组件缺失、Key 不可用、Tunnel 未就绪、端口冲突或孤儿状态 | 2 |
| `stopped` | 没有属于本目录的公网组件，且代理/metrics 端口无外部监听冲突 | 1 |

无看门狗时，启动会先清理**属于本目录**的孤儿；已有看门狗时则由其继续管理。非本目录进程占用 8790/20242 时报告冲突，不会将其杀死。停止先看门狗，再停代理和 Tunnel；重复停止返回 0。若其他程序仍占用端口，会显示警告，但不会把“停止其他程序”当作成功条件。

### 桌面控制面板

双击 `panel.cmd`。面板提供启动、停止、刷新、复制公网地址和打开日志目录，每 15 秒刷新一次。

- 打开面板不会自动启动服务；关闭面板不会主动停止服务。若在启停或刷新进行中关闭，面板会结束其控制 helper，不能将该次操作视为已完成，需重新刷新核实状态。
- 自动刷新读取状态失败时（例如配置损坏），面板在界面内显示原因，不弹模态框；启动/停止等主动操作失败仍会弹出错误框。
- 停止仅影响公网代理、Tunnel、看门狗；Magpie 只显示可达性。
- 面板不显示或复制 Key，不创建 HTTP 服务，也不需要管理员权限。
- 启停与 CLI 使用同一个 `control.ps1`，不会出现两套状态判断。

### 启动顺序

先启动 Magpie 或先启动公网侧均可。代理每次请求新建 loopback 上游连接，Magpie 后启动时无需重启代理/Tunnel。停止会中断正在传输的请求，代理不会自动重放。

## 6. 看门狗与日志

- 单实例：`run/supervisor.lock` 独占句柄。
- 代理：错误 Key 探针返回 401/429 为正常；503、404、500 等任何 HTTP 响应都证明进程存活但不一定就绪，只有连接失败/超时才重启。
- 探针约 4 次/分钟，正常计入鉴权失败节流。只有方法/路径、固定错误 Key、精确 UA 和直接本机/no-CF 来源全部匹配的探针不写逐次代理日志；公网伪造 UA 不会获得日志或限流豁免。
- Tunnel：连续 3 次 `/ready` 失败才重启，给 cloudflared 自身重连留出时间。启动 Tunnel 前还会核对 `bin/README.md` 记录的 cloudflared SHA-256。
- 日志写失败不会终止看门狗。

| 日志 | 上限/轮转 |
|---|---|
| `logs/proxy.log` | 超过 8 MiB 后尽力轮转，保留 `.1`；失败时可能继续增长 |
| `logs/supervisor.log` | 超过 4 MiB 后尽力轮转，保留 `.1`；失败时可能继续增长 |
| `logs/cloudflared.out.log` / `.err.log` | 任一超过 4 MiB 时通过受控重启尽力轮转，保留 `.1`；会中断在途请求 |
| `logs/proxy.out.log` / `.err.log` | 每次代理重启前尽力保留为 `.1` |

代理、supervisor、cloudflared 和 Key 同步时间戳统一使用 UTC（ISO `Z`）。cloudflared 的 INFO 日志写 stderr，因此主要查看 `cloudflared.err.log`。

任一 cloudflared 输出日志超过 4 MiB 时，看门狗会强制重启 cloudflared 完成轮转；这会中断该 Tunnel 上全部在途请求，包括长推理和 SSE。代理自身日志轮转不重启代理。

## 7. 运维

### 本机存活检查

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:8790/v1/models
# 401：代理和鉴权正常；503：进程存活但 Key 不可用。
```

### 轮换 Key

退出 Magpie 后修改 `settings.json.lanKey`，或删除该字段让 Magpie 重新生成，再启动 Magpie。正常情况下代理 ≤5 秒读到新值，`API-KEY.txt` 在看门狗下一轮同步。设置文件不可读或没有 `lanKey` 时旧 Key 最多按上述规则沿用 5 分钟，随后请求返回 503；即使在这个有界窗口内，也不能把它理解为强制即时吊销机制。

### 重建或删除 Tunnel

以下是**有中断的维护示例**，不是无损重建。`create` 对已经存在的同名 Tunnel 会失败，因此必须使用唯一的新名称。创建新 Tunnel 本身不停止旧进程，但更新配置并重启会中断在途请求，`route dns` 还会改变公网解析并可能立即切换流量；应在维护窗口操作：

```powershell
$cert = "$env:USERPROFILE\.config\magpie-public\cert.pem"
$newName = 'magpie-public-new' # 换成确认不存在的新名称
.\bin\cloudflared.exe tunnel --origincert $cert create $newName
# 将新 Tunnel ID 和 credentials-file 更新到 config.yml。
# 执行 start.cmd restart，确认新 Tunnel ready 后，再切换 DNS：
.\bin\cloudflared.exe tunnel --origincert $cert route dns $newName apimagpie.example.com
```

完全回滚时，先执行 `stop.cmd` 并确认不再需要公网服务，再删除 Tunnel 及对应的 DNS 记录。**`tunnel delete` 是破坏性回滚操作，会使公网服务不可用，不属于“不影响运行中的 Tunnel”的命令。以下仅删除旧 Tunnel，执行前必须核对实际名称，勿误删新 Tunnel：**

```powershell
.\bin\cloudflared.exe tunnel --origincert $cert delete magpie-public
```

## 8. 与其他 Tunnel 项目的隔离

本项目使用独立目录、Tunnel、凭据和 metrics 端口（例如其他 Tunnel 项目使用 20241，本项目使用 20242）。停止逻辑只接受当前项目完整路径，不匹配其他 Tunnel 项目。两者可以共用同一个本机 Magpie 上游，但本项目绝不管理 Magpie 或其他 Tunnel 项目的生命周期。

## 9. 验证

`VERIFY.md` 记录当前版本的测试方法、结果和公网端到端矩阵。`tests/` 包含可重复执行的零依赖 mock/控制回归；真实公网、生命周期和 GUI 的复现脚本与原始证据保存在仓库外，不作为运行依赖。

```cmd
node --test tests/proxy.test.js
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/control.test.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File tests/control.test.ps1
```

## 10. 许可证

MIT，详见 `LICENSE`。
