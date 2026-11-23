# 在另一台 Windows 电脑上部署 Magpie 公网推理 API

本文按当前仓库实现，从零复现“Cloudflare Tunnel → 本机鉴权代理 → 本机 Magpie”。示例目录仍为 `D:\magpie-public`，命令统一使用 **Windows PowerShell**。

## 0. 不可改变的安全原则

Magpie 对 loopback 请求免 gateway key，而 cloudflared 也从 loopback 连上游，因此：

> 不允许把 Tunnel 直接指向 Magpie 3425；必须先经过 127.0.0.1:8790 的鉴权代理。

目标结构：

```text
公网 https://<子域名>.<你的域名>/v1
  → Cloudflare Tunnel
  → 127.0.0.1:8790  proxy.js（Key + 方法/路径白名单）
  → 127.0.0.1:3425  Magpie（不由本项目启停）
```

本机明文 Key 是可接受的；公网推理必须鉴权；管理 GUI、`magpie web`、密钥文件和控制面板均不发布。控制面板使用 WinForms，不监听端口。

## 1. 前置条件

- Magpie 已安装并能正常提供推理；记录实际 gateway 地址。
- Node.js ≥18（当前实测 v24），`node.exe --version` 可用。
- Cloudflare 中已托管一个 Active 域名。
- Windows PowerShell 5+；无需 npm 包、Python、Web 框架或数据库。
- 不开启 Magpie 的局域网共享，不启动 `magpie web`。

先确认本机免鉴权这一事实（Magpie 运行时）：

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:3425/v1/models
# 200 说明 loopback 免鉴权，鉴权代理不可省略。
```

如果 Magpie 不是 3425，后续修改 `config.json.upstream`，不要再手动修改 start/stop。

## 2. 准备项目目录

将仓库 tracked 文件复制或克隆到目标目录，再创建运行目录：

```powershell
$dir = 'D:\magpie-public'
New-Item -ItemType Directory -Force -Path `
  $dir, "$dir\bin", "$dir\secrets", "$dir\logs", "$dir\run" | Out-Null
Set-Location $dir
```

目录可以含空格，也可以改名或移动：当前控制脚本按实际完整路径识别进程，不再要求目录名必须是 `magpie-public`。

`.gitignore` 不会带入真实 Key、日志、PID、Tunnel 凭据和 cloudflared.exe。

## 3. 放置并验证 cloudflared

从 Cloudflare 官方 release 获取 Windows amd64 二进制，命名为 `bin\cloudflared.exe`；也可复制本机受信任项目中的同一二进制。

```powershell
.\bin\cloudflared.exe --version
Get-FileHash .\bin\cloudflared.exe -Algorithm SHA256
```

把实际版本和 SHA-256 写入 `bin/README.md`。看门狗每次启动 Tunnel 前都会重新计算并与该记录比较；缺少二进制或哈希不匹配时，代理仍可由看门狗拉起用于本机诊断，但 Tunnel 不会启动，公网状态保持 degraded。官方升级时必须同时更新二进制和记录；同目录哈希不是独立签名，部署/升级仍需核验官方来源。

## 4. 配置代理

复制当前 `proxy.js`、`common.ps1`、`control.ps1`、`run.ps1` 等全部脚本，不要只复制 `proxy.js`。

编辑 `config.json`：

```json
{
  "listenHost": "127.0.0.1",
  "listenPort": 8790,
  "upstream": "http://127.0.0.1:3425",
  "settingsPath": "C:\\Users\\<用户名>\\.config\\magpie\\settings.json",
  "lanKeyCacheMs": 5000,
  "lanKeyMaxStaleMs": 300000,
  "lanKeyRetryMs": 2000,
  "callerAgent": "magpie-public",
  "allowedRoutes": [
    { "path": "/v1/models", "methods": ["GET", "HEAD"] },
    { "path": "/v1/models/*", "methods": ["GET", "HEAD"] },
    { "path": "/v1/chat/completions", "methods": ["POST"] },
    { "path": "/v1/responses", "methods": ["POST"] },
    { "path": "/v1/messages", "methods": ["POST"] },
    { "path": "/v1/messages/count_tokens", "methods": ["POST"] },
    { "path": "/v1beta/models", "methods": ["GET", "HEAD"] },
    { "path": "/v1beta/models/*", "methods": ["GET", "HEAD"] },
    { "path": "/v1beta/models/*:generateContent", "methods": ["POST"] },
    { "path": "/v1beta/models/*:streamGenerateContent", "methods": ["POST"] },
    { "path": "/v1beta/models/*:countTokens", "methods": ["POST"] }
  ],
  "rateLimit": {
    "windowMs": 60000,
    "maxRequests": 600,
    "globalMaxRequests": 1800,
    "authFailMax": 20
  },
  "maxBodyBytes": 57671680,
  "upstreamTimeoutMs": 600000,
  "maxLogBytes": 8388608
}
```

要点：

- `settingsPath` 是代理和 `sync-key.ps1` 的共同 Key 来源；使用 `%USERPROFILE%` 环境变量形式也可以，脚本会展开。
- `lanKeyCacheMs` 是正常重读周期，`lanKeyMaxStaleMs` 是读取失败或没有有效 `lanKey` 后允许沿用旧 Key 的最长时间，`lanKeyRetryMs` 是失败负缓存；超过最大陈旧时间仍不可用会返回 503。
- `maxBodyBytes` 固定为 55 MiB（57,671,680 字节）；`proxy.js` 未配置该项时也使用相同的 55 MiB 回退值。
- 所有数值字段必须是正数：`listenPort` 必须是 1–65535 的整数，`lanKey*`、`maxBodyBytes`、`upstreamTimeoutMs`、`maxLogBytes`、`rateLimit.*` 必须是正数；`0`、负值、非整数端口或非数字会被 `proxy.js` 和 `common.ps1` 在启动前拒绝，避免看门狗反复重启一个必然失败的配置。
- 限流分三层：每个 `CF-Connecting-IP` 的窗口配额、已鉴权请求的全局 `globalMaxRequests` 配额、未鉴权拒绝类响应的独立 `10 × globalMaxRequests` 上限；匿名流量不占用已鉴权配额。
- 鉴权失败节流只统计携带了错误 Key 的请求；未携带 Key 的 401 不计入，成功鉴权会清零该来源的计数。
- 省略 `logPath` 时固定使用项目内 `logs\proxy.log`，不需要按机器修改。
- 监听和上游必须是显式 `127.0.0.1` 或 `::1`；upstream 还必须是根 URL，不带路径、查询串、userinfo 或 hash。
- `allowedRoutes` 同时限制方法和路径。不要为“兼容”重新放开所有方法或 `/v1/magpie/**`、`/api/**`。
- `run.ps1` 依次通过 PATH、标准 `%ProgramFiles%\nodejs\node.exe`、旧机器的 `D:\Program Files\nodejs\node.exe` 查找 Node；目标机仍需满足 Node ≥18。

## 5. 登录 Cloudflare，并分离两类凭据

两类文件用途不同：

| 凭据 | 用途 | 保存位置 |
|---|---|---|
| `<tunnel-id>.json` | 日常 `tunnel run` | 项目 `secrets\` |
| `cert.pem` | 创建、删除、重建 Tunnel 及写 DNS 路由，含账户级 apiToken | 项目外 `%USERPROFILE%\.config\magpie-public\cert.pem` |

按 UUID 运行 Tunnel 不需要 `cert.pem`。

### 5.1 保留原有登录证书

`cloudflared tunnel login` 只能写默认位置，且不会覆盖已有文件。如果已有 `%USERPROFILE%\.cloudflared\cert.pem`，先备份到项目外并记录哈希：

```powershell
$defaultCert = "$env:USERPROFILE\.cloudflared\cert.pem"
$backup = Join-Path $env:TEMP ("magpie-cloudflared-cert-backup-" + [guid]::NewGuid().ToString('N') + '.pem')
$backupMoved = $false
if (Test-Path -LiteralPath $defaultCert) {
    Get-FileHash $defaultCert -Algorithm SHA256
    Move-Item -LiteralPath $defaultCert -Destination $backup -ErrorAction Stop
    $backupMoved = $true
}
```

### 5.2 登录并保存独立管理证书

```powershell
$cf = 'D:\magpie-public\bin\cloudflared.exe'
$adminDir = "$env:USERPROFILE\.config\magpie-public"
$adminCert = "$adminDir\cert.pem"
try {
    & $cf tunnel login
    New-Item -ItemType Directory -Force -Path $adminDir | Out-Null
    Move-Item -LiteralPath $defaultCert -Destination $adminCert -ErrorAction Stop
} finally {
    # 只恢复本次成功移动的备份；失败时也先恢复原证书，绝不覆盖旧备份。
    if ($backupMoved -and (Test-Path -LiteralPath $backup)) {
        Move-Item -LiteralPath $backup -Destination $defaultCert -ErrorAction Stop
        $backupMoved = $false
        Get-FileHash $defaultCert -Algorithm SHA256
    }
}
```

如登录或移动失败，先恢复备份再继续。不要把账户证书长期留在 `%TEMP%` 或项目运行目录。

## 6. 创建 Tunnel、DNS 和运行凭据

```powershell
Set-Location 'D:\magpie-public'
& $cf tunnel --origincert $adminCert create magpie-public
```

记录输出的 Tunnel UUID 和生成的 JSON 路径，把 JSON 复制到项目 `secrets\<tunnel-id>.json`，再配置 DNS：

```powershell
& $cf tunnel --origincert $adminCert route dns magpie-public <子域名>.<你的域名>
```

编辑 `config.yml`：

```yaml
tunnel: <tunnel-id>
credentials-file: 'D:\magpie-public\secrets\<tunnel-id>.json'
no-autoupdate: true
metrics: 127.0.0.1:20242
ingress:
  - hostname: '<子域名>.<你的域名>'
    service: http://127.0.0.1:8790
    originRequest:
      connectTimeout: 30s
      noHappyEyeballs: true
      disableChunkedEncoding: false
      noTLSVerify: false
  - service: http_status:404
```

安装目录、端口或域名变化时，只需修改这里和 `config.json`；`control.ps1`（以及调用它的 `start.cmd`、`stop.cmd`、`panel.ps1`）和 `sync-key.ps1` 会自动读取，无需改脚本。除末尾 `http_status:404` 外，每条 forwarding service 都必须精确等于代理 listener；追加第二条指向 3425 的规则也会被拒绝。为避免轻量解析器漏读规则，每条规则必须恰好有一个未加引号的 block-style `service`，带引号键、flow collection、anchor/alias/merge key 等形式会直接拒绝。

验证 ingress（只读）：

```powershell
& $cf tunnel --config .\config.yml ingress validate
```

## 7. 收紧 ACL

项目目录包含可执行脚本、明文 Key 副本和 Tunnel 凭据，应只允许当前用户、SYSTEM、Administrators：

```powershell
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls $dir /inheritance:r /grant:r "${me}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' /T
icacls $adminDir /inheritance:r /grant:r "${me}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' /T
attrib +R $adminCert

icacls $dir
icacls "$dir\API-KEY.txt"   # 首次启动同步后检查
icacls "$dir\secrets\<tunnel-id>.json"
icacls $adminCert
```

编辑、重写、克隆或恢复文件后重新核对 ACL，不要假设所有编辑器都会保留原 DACL。

## 8. 启动、状态和控制面板

```cmd
start.cmd
start.cmd status
stop.cmd
start.cmd restart
```

`start.cmd stop` 与 `stop.cmd` 完全等价。公网组件正常而仅 Magpie 未运行时不会被视为启动失败，状态为 `waiting-upstream`；Magpie 上线后无需重启公网侧。停止不依赖配置是否仍可启动；配置损坏时也会按精确归属清理本目录公网组件，并报告 `configError`。

退出码：

- 0：`ready` 或 `waiting-upstream`；`stop` 成功清理本目录组件时也是 0；
- 1：`status`、`start` 或 `restart` 结束时为 `stopped`（例如启动没有留下组件），或 `status`/`start` 发生配置、执行错误；
- 2：`status`/`start`/`restart` 为 `degraded`，或 `stop`/`restart` 执行错误、所属进程未能完全停止。

`stop` 的退出码只反映本目录所属进程是否清理完毕；端口被其他程序占用只给出警告，不把“停止其他程序”当作成功条件。

双击 `panel.cmd` 可使用桌面面板。它不监听网络、不自动启停；停止只影响公网组件，绝不停 Magpie。

默认没有开机自启。确有需要时，可注册登录触发的任务调用 `launch.vbs`，并将任务的多实例策略设为 IgnoreNew、执行时限设为 unlimited；这是可选行为，不是默认安装步骤。

## 9. 验收清单

以下均通过后再发布客户端 Key：

### 网络与鉴权

```powershell
# 代理无 Key：401；503 表示 Key 文件不可读，需要修复而不是绕过。
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:8790/v1/models

$key = (Get-Content "$env:USERPROFILE\.config\magpie\settings.json" -Raw | ConvertFrom-Json).lanKey
curl.exe -s -o NUL -w "%{http_code}`n" https://<子域名>.<你的域名>/v1/models -H "Authorization: Bearer $key"
```

- 公网无 Key/坏 Key 为 401；正确 Bearer、`x-api-key`、`x-goog-api-key` 均可用。
- `/v1/magpie/**`、`/api/**`、`/secrets/**`、`/API-KEY.txt`、`/`、`/healthz` 即使带正确 Key 也为 404。
- DELETE/PUT/PATCH 以及未登记的 Gemini 动作不会转发。
- 8790、20242、3425 只监听 loopback；面板启动前后没有新增监听端口。

### 功能

- OpenAI chat/responses、Anthropic messages/count_tokens、Gemini generate/stream/countTokens 按实际模型验证。
- SSE 分块到达，不被一次性缓冲；未知模型和坏 JSON 的上游错误原样透传。
- 55 MiB（57,671,680 字节）请求体上限、超时、伪造来源头、动态 `Connection` 逐跳头清理通过 mock 验证。
- 带伪造 `supervisor-healthcheck` UA 的坏 Key，第 21 次仍为 429。

### 启停和故障

- 启动顺序无关；Magpie 后启动无需重启代理。
- Key 不可读时错误 Key 探针得到 503，代理 PID 保持稳定，面板显示 degraded。
- 连续停止两次都安全；两个入口行为一致；只停止当前目录所属进程。
- 看门狗被强杀后可由启动流程清理本目录孤儿，非所属占用进程不会被杀。
- 停止会中断在途请求，这是明确语义；客户端应自行决定是否重试。

## 10. 日常运维

- 状态：`start.cmd status` 或面板。
- 日志：优先 `logs\supervisor.log`、`logs\proxy.log`、`logs\cloudflared.err.log`。
- Key：代理正常 ≤5 秒读到轮换值；设置文件不可读或没有 `lanKey` 时旧 Key 最多沿用 5 分钟，随后返回 503，失败重试负缓存为 2 秒。
- 端口：只改 `config.json` 和 `config.yml`，控制脚本自动读取。
- cloudflared 更新：替换二进制后重新记录版本/SHA-256 并重启；看门狗会在每次 Tunnel 启动前核对。
- 停止会中断在途请求；长时间推理应等服务空闲。
- 任一 cloudflared 输出日志超过 4 MiB 时也会通过强制重启轮转，中断该 Tunnel 的全部在途请求，包括 SSE；代理日志轮转无此影响。所有本项目日志时间戳使用 UTC。
- 日志轮转均为尽力而为：移动失败时不保证生成 `.1` 备份；代理和 supervisor 日志在轮转失败时可能继续增长。

## 11. 与其他 cloudflared 项目共存

不同项目使用不同目录、Tunnel ID、凭据、hostname 和 metrics 端口。当前进程控制按完整路径，不会仅凭 `cloudflared.exe` 名称或 `magpie-public` 子串停止其他项目。

其他 Tunnel 项目使用 20241，本示例使用 20242；如果还有别的 Tunnel，应同样分配独立 metrics 端口。

## 12. 回滚与卸载

```powershell
Set-Location 'D:\magpie-public'
.\stop.cmd

# 可选：删除曾手工注册的自启任务。
Unregister-ScheduledTask -TaskName 'MagpiePublicAPI' -Confirm:$false -ErrorAction SilentlyContinue

# 删除云端 Tunnel；对应的 DNS 记录需在 Cloudflare 另行删除。此步骤需要项目外的管理证书。
& $cf tunnel --origincert $adminCert delete magpie-public
```

确认不再需要后，再删除项目目录和 `%USERPROFILE%\.config\magpie-public\cert.pem`。整个过程不需要修改或卸载 Magpie，也不应停止其他 Tunnel 项目。

## 13. 常见问题

**公网 401**：Key 错误或 base URL/请求头不符合客户端协议；只认三种请求头，不认 `?key=`。只有查询 Key 时为 401，有效请求头同时带 `key` 查询参数时为 400，且不会转发到 Magpie。Cloudflare 边缘已看到原始 URL，所以任何情况下都不要把秘密放进查询串。

**公网 404**：通常是 base URL 少了 `/v1`，或方法/路径不在白名单；管理面和文件路径即使带 Key 也同样是 404。

**公网 502**：代理已鉴权但 Magpie 上游不可达；检查 `start.cmd status` 的 Magpie 行。

**本机代理一直 503**：`settingsPath` 错误或当前没有可用/缓存 `lanKey`。看门狗不会通过重启掩盖这个配置问题。

**429**：通用限流或鉴权失败节流；未携带 Key 的 401 不计入失败节流；探针 UA 不提供豁免，等待当前窗口结束。

**degraded**：检查 Key、Tunnel `/ready`、看门狗、孤儿组件以及端口是否被非本项目进程占用；degraded 不等于“可以无 Key 使用”。

**修改配置不生效**：`config.json` 代理由看门狗在异常时重启，主动修改后建议 `start.cmd restart`；`config.yml` 修改后必须重启 cloudflared，同样可用 restart。
