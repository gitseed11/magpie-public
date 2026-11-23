# Magpie 公网推理 API

把本机 Magpie 的推理接口经 Cloudflare Tunnel 发布为一个**必须携带 API Key** 的公网服务，同时让 Magpie 管理面、密钥文件和本机控制面板保持不可从公网访问。

- 公网 OpenAI base URL：`https://apimagpie.example.com/v1`
- 认证代理：`http://127.0.0.1:8790`
- 独立上游：`http://127.0.0.1:3425`
- 默认纯手动启停，不注册开机自启；启停公网侧绝不停止 Magpie 或其他 Tunnel 项目。

当前版本：**v2.0.0**。实测记录见 `VERIFY.md`，标签发布说明见 `RELEASE.md`。

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
             ├─ 请求体上限、限流、上游超时、SSE 流式透传
             └─ 删除公网 Key，再向 127.0.0.1:3425 转发
```

`proxy.js` 和 `common.ps1` 都拒绝非显式 loopback 的监听/上游配置；`config.yml` 的 ingress service 和 metrics 也只允许 loopback。管理路径 `/v1/magpie/**`、`/api/**`，以及 `/secrets/**`、`/API-KEY.txt` 等文件路径不在白名单中，带正确 Key 也不会被转发。

Magpie GUI 使用本机 WebView2；本项目的控制面板是普通 WinForms 窗口，**不监听 TCP 端口，不经过 cloudflared，也不并入 8790**。

## 2. API Key

直接复用 Magpie 自动生成的 `lanKey`：

```text
%USERPROFILE%\.config\magpie\settings.json → lanKey
```

`proxy.js` 最多每 5 秒重读一次。设置文件短暂不可读时沿用已缓存 Key；如果新进程尚无缓存，则返回 503 并拒绝转发。看门狗把 503 视为“进程存活、Key 不可用”，**不会因此重启代理**。

支持三种请求头，任一有效值即可：

| 请求头 | 客户端 |
|---|---|
| `Authorization: Bearer <key>` | OpenAI / curl |
| `x-api-key: <key>` | Anthropic |
| `x-goog-api-key: <key>` | Google GenAI |

不接受查询串 `?key=`。转发前会删除三种公网鉴权头，并把 `Authorization` 替换为固定调用方标识，避免公网 Key 进入 Magpie 使用日志。

`API-KEY.txt` 是方便本机查看的明文副本，由 `sync-key.ps1` 自动同步。代理和同步脚本共同使用 `config.json.settingsPath`；未配置时才回退到 `%USERPROFILE%\.config\magpie\settings.json`。本机明文是刻意设计，ACL 应只允许当前用户、SYSTEM、Administrators。

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

`config.json.allowedRoutes` 同时约束方法和路径；`*` 只允许非空模型 ID，模型 ID 内可以含 `/`。

| 方法 | 路径/动作 |
|---|---|
| GET、HEAD | `/v1/models`、`/v1/models/*` |
| POST | `/v1/chat/completions`、`/v1/responses` |
| POST | `/v1/messages`、`/v1/messages/count_tokens` |
| GET、HEAD | `/v1beta/models`、`/v1beta/models/*` |
| POST | `/v1beta/models/*:generateContent` |
| POST | `/v1beta/models/*:streamGenerateContent` |
| POST | `/v1beta/models/*:countTokens` |

其余方法和路径统一 404。请求路径中的 `..`、编码点/斜杠、NUL、反斜杠和 `//` 也会在代理层拒绝。

代理不解析或重写 JSON 消息体；请求与响应体（含 SSE）原样透传。它会：

1. 规范化 `Host` 和调用方标识，删除公网 Key、CF/XFF 来源头；
2. 删除标准逐跳头以及 `Connection` 动态列出的所有头；请求重新生成 framing；
3. 为 SSE 设置 `cache-control: no-cache, no-transform` 和 `x-accel-buffering: no`（Cloudflare 回程可能过滤后者）。

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

**账户级 `cert.pem` 不属于运行目录**。它仅用于创建、删除或重建 Tunnel，保存在：

```text
%USERPROFILE%\.config\magpie-public\cert.pem
```

按 UUID 执行 `cloudflared tunnel run` 只需要 `secrets/<tunnel-id>.json`，不需要账户级证书。若无需保留管理凭据，也可以删除该证书，以后重新 login。

`.gitignore` 排除 `secrets/`、`API-KEY.txt`、`logs/`、`run/`、`bin/*.exe`。克隆后需重新放置二进制和 Tunnel 凭据，并按目标机修改 `settingsPath`、Tunnel ID、hostname 与 credentials-file；不要提交真实 Key 或账户凭据。

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

所有入口都调用 `control.ps1`。进程归属由 **PID 文件 + 完整路径复核 + 精确路径孤儿枚举**确定，不再按目录名子串批量杀进程。

状态语义：

| 状态 | 含义 | `status` 退出码 |
|---|---|---:|
| `ready` | 看门狗、代理鉴权、Tunnel ready、Magpie 均可达 | 0 |
| `waiting-upstream` | 公网侧正常，仅 Magpie 3425 不可达 | 0 |
| `degraded` | 组件缺失、Key 不可用、Tunnel 未就绪、端口冲突或孤儿状态 | 2 |
| `stopped` | 没有属于本目录的公网组件 | 1 |

启动会先清理**属于本目录**的孤儿；非本目录进程占用 8790/20242 时报告冲突，不会将其杀死。停止先看门狗，再停代理和 Tunnel；重复停止返回 0。若其他程序仍占用端口，会显示警告，但不会把“停止其他程序”当作成功条件。

### 桌面控制面板

双击 `panel.cmd`。面板提供启动、停止、刷新、复制公网地址和打开日志目录，每 15 秒刷新一次。

- 打开面板不会自动启动服务；关闭面板不会停止服务。
- 停止仅影响公网代理、Tunnel、看门狗；Magpie 只显示可达性。
- 面板不显示或复制 Key，不创建 HTTP 服务，也不需要管理员权限。
- 启停与 CLI 使用同一个 `control.ps1`，不会出现两套状态判断。

### 启动顺序

先启动 Magpie 或先启动公网侧均可。代理每次请求新建 loopback 上游连接，Magpie 后启动时无需重启代理/Tunnel。停止会中断正在传输的请求，代理不会自动重放。

## 6. 看门狗与日志

- 单实例：`run/supervisor.lock` 独占句柄。
- 代理：错误 Key 探针返回 401/429 为正常；503 为 Key 不可用但进程存活；其他异常才重启。
- 探针约 4 次/分钟，正常计入鉴权失败节流；UA 只影响日志标签，公网伪造 UA 不会获得豁免。
- Tunnel：连续 3 次 `/ready` 失败才重启，给 cloudflared 自身重连留出时间。
- 日志写失败不会终止看门狗。

| 日志 | 上限/轮转 |
|---|---|
| `logs/proxy.log` | 8 MB，保留 `.1` |
| `logs/supervisor.log` | 4 MB，保留 `.1` |
| `logs/cloudflared.out.log` / `.err.log` | 任一超过 4 MB 时由看门狗通过受控重启轮转，保留 `.1` |
| `logs/proxy.out.log` / `.err.log` | 每次代理重启前保留为 `.1` |

cloudflared 的 INFO 日志写 stderr，因此主要查看 `cloudflared.err.log`。

## 7. 运维

### 本机存活检查

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:8790/v1/models
# 401：代理和鉴权正常；503：进程存活但 Key 不可用。
```

### 轮换 Key

退出 Magpie 后修改 `settings.json.lanKey`，或删除该字段让 Magpie 重新生成，再启动 Magpie。正常情况下代理 ≤5 秒读到新值，`API-KEY.txt` 在看门狗下一轮同步。设置文件不可读时会按上述缓存规则暂时沿用旧 Key，不能把它理解为强制即时吊销机制。

### 重建或删除 Tunnel

以下命令使用独立的管理证书，不影响运行中的 Tunnel：

```powershell
$cert = "$env:USERPROFILE\.config\magpie-public\cert.pem"
.\bin\cloudflared.exe tunnel --origincert $cert create magpie-public
.\bin\cloudflared.exe tunnel --origincert $cert route dns magpie-public apimagpie.example.com
# 将新 Tunnel ID 和 credentials-file 更新到 config.yml。

# 完全回滚时，先 stop.cmd，再删除 DNS/Tunnel：
.\bin\cloudflared.exe tunnel --origincert $cert delete magpie-public
```

## 8. 与其他 Tunnel 项目的隔离

每个项目应使用独立目录、Tunnel、凭据和 metrics 端口（例如分别为 20241 和 20242）。停止逻辑只接受当前项目完整路径，不匹配其他 Tunnel。多个项目可以共用同一个本机 Magpie 上游，但本项目绝不管理 Magpie 或其他项目的生命周期。

## 9. 验证

`VERIFY.md` 记录当前版本的自动化实测命令、结果和公网端到端矩阵。验证脚本及临时 mock 文件保存在仓库外，不作为运行依赖。

## 10. 许可证

MIT，详见 `LICENSE`。
