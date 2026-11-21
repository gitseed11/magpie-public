# 在另一台已装 Magpie 的电脑上复现：公网推理 API

本教程从零开始，在**另一台已经装好并运行 Magpie** 的 Windows 电脑上，把 Magpie 的推理接口
发布成一个带 API Key 的公网服务。

目标形态（以本机参考实现为例）：

```
公网 https://<子域名>.<你的域名>/v1
  → Cloudflare（隧道）
  → cloudflared（本机进程）
  → 127.0.0.1:8790  鉴权反向代理（本项目）
  → 127.0.0.1:3425  Magpie（不动）
```

初始部署全程 **不改 Magpie 任何配置、不重启 Magpie**（Key 轮换是例外，见第 9 节）。

---

## 0. 先理解为什么必须加一层代理

这一步不能跳过，否则会做出一个**公网无鉴权**的服务。

Magpie 只监听 `127.0.0.1:3425`，并且**对来自 loopback 的请求故意不校验 Key**
（本机 Codex / Claude Code / ZCode 就是靠这个免密直连的）。

而 Cloudflare 隧道**正是从 loopback 连进 Magpie** 的。所以：

> 隧道直接指向 `127.0.0.1:3425` = 公网任何人无需 Key 即可消耗你的模型额度。

自检方法（在目标机上执行）：

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3425/v1/models
```

若返回 `200`，说明确实免鉴权，**必须**用本教程的代理方案。

同时 Magpie 的推理路由（`/v1/*`）和管理路由（`/v1/magpie/admin/`、`/api/*`）
**在同一个端口上**，所以还需要代理做路径白名单，才能把管理面留在本机。

---

## 1. 前置条件清单

| 项 | 要求 | 检查命令 |
|---|---|---|
| Magpie | 已运行，网关在 3425 | `cat "$USERPROFILE/.config/magpie/gateway.json"` |
| Node.js | ≥ 18（本机实测 v24） | `node -v` |
| curl | 任意较新版本 | `curl --version` |
| 域名 | 已托管在 Cloudflare（NS 生效、状态 Active） | 控制台查看 |
| cloudflared | 任意较新版本（本项目用 `bin\cloudflared.exe` 这份副本） | `"bin/cloudflared.exe" --version` |

Magpie 网关地址以 `gateway.json` 的 `addr` 为准；若不是 `127.0.0.1:3425`，
后续所有 `3425` 都要替换成实际端口。

**不要**开启 Magpie 的 `Settings → Network and sharing → Share on local network`：
它会把 3425 绑到局域网地址，扩大暴露面。本方案不需要它。

---

## 2. 准备目录

以下用 `D:\magpie-public` 作为安装目录（换成你自己的路径也可以）。
**路径含空格没问题**（脚本里已对路径加引号），但请保持一致，后面要替换时注意。
目录名请保持 `magpie-public`：`start.cmd` / `stop.cmd` 用 `*magpie-public*`
匹配本项目进程，改名后停止脚本会匹配不到。

```bash
mkdir -p "D:/magpie-public/bin" \
         "D:/magpie-public/secrets" \
         "D:/magpie-public/logs"
```

### 2.1 放置 cloudflared.exe

放到 `bin\cloudflared.exe`。获取方式任选：

- 从 cloudflare 官方 releases 下载 `cloudflared-windows-amd64.exe` 后改名；
- 或从本机已有的其他项目里**复制**一份（只读复制，不影响原项目）。

验证：

```bash
"D:/magpie-public/bin/cloudflared.exe" --version
```

记下 SHA-256，便于以后核对：

```bash
sha256sum "D:/magpie-public/bin/cloudflared.exe"
```

> 本目录是一个 git 仓库，`.gitignore` 排除了 `secrets/`、`API-KEY.txt`、`logs/`、
> `run/` 和 `bin/*.exe`。从仓库恢复时，二进制要另放（版本与哈希见 `bin/README.md`），
> Key 由 Magpie 重新生成。

---

## 3. 创建鉴权代理

### 3.1 `proxy.js`

把参考实现中的 `proxy.js` 原样复制过来。它是**零依赖**的 Node 脚本（只用 `http`/`https`/`fs`/`path`/`url`），
核心行为：

1. 只监听 `127.0.0.1`，并拒绝非 loopback 来源；
2. `/v1/magpie*`、`/api*` 直接 404（管理面永不出本机）；
3. 只放行 `config.json` 里 `allowedPaths` 列出的推理路由；
4. 校验 `Authorization: Bearer <key>`、`x-api-key: <key>` 或 `x-goog-api-key: <key>`，
   与 Magpie 的 `lanKey` 比对（恒定时间比较）；不接受 `?key=` 查询串；
5. 限流：按调用方 600 次/分，另有全局 1800 次/分兜底；身份只取 `CF-Connecting-IP`
   （**不信任** `X-Forwarded-For`，否则可被伪造绕过）；同一调用方鉴权失败 20 次后转为 429；
6. 请求体上限 32 MB（超限 413，含 chunked）、上游超时 600 s（超时 504）；
7. 拒绝路径穿越形状（`..`、`%2e`、`%2f`、`%5c`、`%00`、反斜杠、`//`）；
   `..;` 这类不含拒绝形状的路径会被转发，由上游决定是否返回 404；
8. 转发时把 `Host` 改写为上游、把 `Authorization` 换成固定调用方标识，
   避免公网 Key 落进 Magpie 的 `usage.jsonl`；
9. SSE 流式透传，不缓冲；
10. **不定义自己的协议**：请求/响应体（含 SSE）原样透传，不解析、不改写 JSON；
    只做两处必要改动——转发前规范化请求头（`Host` / `Authorization` / 去掉公网 Key 与
    `cf-*`、逐跳头），以及给 SSE 响应确保 `cache-control: no-cache, no-transform` 与
    `x-accel-buffering: no`（Cloudflare 回程会过滤后者）；代理自己只产生标准状态码 +
    OpenAI 风格的最小错误 JSON（`{"error":{"message":…,"type":…}}`），不注入字段。

### 3.2 `config.json`

**必须修改的地方**：`settingsPath` 换成目标机实际的 Magpie 设置路径
（把 `YOUR_USERNAME` 换成你的 Windows 用户名；Magpie 默认在
`%USERPROFILE%\.config\magpie\settings.json`）。

```json
{
  "listenHost": "127.0.0.1",
  "listenPort": 8790,
  "upstream": "http://127.0.0.1:3425",
  "settingsPath": "C:\\Users\\YOUR_USERNAME\\.config\\magpie\\settings.json",
  "lanKeyCacheMs": 5000,
  "callerAgent": "magpie-public",
  "allowedPaths": [
    "/v1/models",
    "/v1/models/*",
    "/v1/chat/completions",
    "/v1/responses",
    "/v1/messages",
    "/v1/messages/count_tokens",
    "/v1beta/models",
    "/v1beta/models/*"
  ],
  "rateLimit": { "windowMs": 60000, "maxRequests": 600, "globalMaxRequests": 1800, "authFailMax": 20 },
  "maxBodyBytes": 33554432,
  "upstreamTimeoutMs": 600000,
  "maxLogBytes": 8388608
}
```

要点：

- `listenPort` 选一个**未被占用**的端口。先查：`netstat -an | grep ":8790"`。
- `upstream` 与 Magpie 实际端口一致。
- 不写 `logPath` 时，日志默认写到脚本旁边的 `logs\proxy.log`；要用别的位置再加
  绝对路径（JSON 里反斜杠写成 `\\`）。
- 若目标机 Magpie 的设置目录不是 XDG 风格，按实际位置改（见第 1 节的 `gateway.json` 同级目录）。
- 不写 `rateLimit` 等可选字段时代码有同样的默认值（600/1800/20、32MB、600s、8MB），
  写上只是为了显式可查。
- `/v1/completions` **不要**加：Magpie 没有该端点（直连 3425 也返回 404）。

### 3.3 单独验证代理（此时还没有隧道）

```bash
cd "D:/magpie-public"
node proxy.js &

# 无 Key → 期望 401
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8790/v1/models

# 管理路径 → 期望 404
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8790/v1/magpie/admin/

# 正确 Key → 期望 200
KEY=$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).lanKey)" \
      "$USERPROFILE/.config/magpie/settings.json")
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $KEY" http://127.0.0.1:8790/v1/models
```

三项都对再继续。验证完先停掉：`kill %1` 或关闭该终端。

---

## 4. 登录 Cloudflare 并创建隧道

### 4.1 关于 `~/.cloudflared/cert.pem` 的坑

`cloudflared tunnel login` **只会**写 `~/.cloudflared/cert.pem`，并且**若该文件已存在就拒绝执行**。

> 已实测：`TUNNEL_ORIGIN_CERT` 环境变量对 `tunnel login` **无效**（该变量只被
> `tunnel create` / `route` / `run` 等子命令识别）。所以登录这一步绕不开默认路径。

如果这台机器上已有别的项目用过 cloudflared（比如已有另一条隧道），`cert.pem` 可能已存在。
处理办法（**不要删除别人的凭据**，先备份到**项目之外**）：

```bash
# 备份 + 记录哈希，便于事后核对还原；路径放在项目外，避免账户凭据留在交付目录里
cp "$USERPROFILE/.cloudflared/cert.pem" "$USERPROFILE/cloudflared-cert.backup.pem"
sha256sum "$USERPROFILE/cloudflared-cert.backup.pem"
rm "$USERPROFILE/.cloudflared/cert.pem"
```

> ⚠️ 这个 `cert.pem` 是**账户级登录凭据**（`ARGO TUNNEL TOKEN`，内含 `apiToken`），
> 等同密码，能建/删隧道、改 DNS。**不要**把它复制进项目目录长期保存；
> 4.3 节还原后立刻把备份删掉。`secrets\` 目录必须收紧 ACL（见 4.6 节）。

### 4.2 登录

```bash
cd "D:/magpie-public"
./bin/cloudflared.exe tunnel login
```

浏览器会打开授权页 → 登录 → **选择要授权的域名** → 点「授权」。
授权成功后 CLI 会打印证书保存路径（就是 `~/.cloudflared/cert.pem`），
可用 `ls -l "$USERPROFILE/.cloudflared/cert.pem"` 确认时间戳已更新。

### 4.3 立刻把证书复制到本项目，并还原原文件

```bash
cp "$USERPROFILE/.cloudflared/cert.pem" \
   "D:/magpie-public/secrets/cert.pem"

# 还原原来的证书（若第 4.1 步备份过），核对哈希后删除备份
cp "$USERPROFILE/cloudflared-cert.backup.pem" "$USERPROFILE/.cloudflared/cert.pem"
sha256sum "$USERPROFILE/.cloudflared/cert.pem"     # 应与备份哈希一致
rm -f "$USERPROFILE/cloudflared-cert.backup.pem"   # 账户级凭据不留副本
```

> 为什么要还原：避免影响机器上其他使用 `~/.cloudflared` 的项目。
> 本项目的隧道运行时只用 `secrets\cert.pem` 这份独立副本，与 `~/.cloudflared` 无运行时依赖。

### 4.4 创建隧道

注意 `--origincert` 要写在 `tunnel` **和** `create` **之间**（这是该版本的实际用法）：

```bash
cd "D:/magpie-public"
./bin/cloudflared.exe tunnel --origincert "D:/magpie-public/secrets/cert.pem" \
    create magpie-public
```

输出类似：

```
Tunnel credentials written to D:\...\secrets\<TUNNEL-ID>.json
Created tunnel magpie-public with id <TUNNEL-ID>
```

**记下 `<TUNNEL-ID>`** 和凭据文件名。

### 4.5 添加 DNS 记录

```bash
./bin/cloudflared.exe tunnel --origincert "D:/magpie-public/secrets/cert.pem" \
    route dns magpie-public apimagpie.example.com
```

把 `apimagpie.example.com` 换成你自己的子域名。成功会打印
`Added CNAME ... which will route to this tunnel`。

### 4.6 收紧目录权限（**必做**）

`secrets\` 里有隧道凭据和账户级 `cert.pem`，`API-KEY.txt` 里有明文 Key。
默认继承的 ACL 通常允许 `Authenticated Users` 修改，等于本机任何账户都能接管隧道、
甚至篡改 `proxy.js` 在下次启动时以你的身份执行。

在 PowerShell 里执行（把路径换成你的实际安装目录）：

```powershell
$dir = 'D:\magpie-public'
# 用当前登录用户的 SID 名，避免域/机器名前缀写错
$me  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

icacls $dir /inheritance:r /grant:r "${me}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' /T

attrib +R "$dir\secrets\cert.pem"
```

验证（应只剩上述三个主体，不再有 `Authenticated Users` / `Users`）：

```powershell
icacls "$dir\secrets\cert.pem"
icacls "$dir\API-KEY.txt"
```

> **以后每次编辑或替换这些文件，建议重跑一遍上面的 `icacls`**：某些编辑器/工具
> 是"写临时文件再改名"，新文件会带进一个登录会话 SID 的 ACE（形如
> `NT AUTHORITY\LogonSessionId_0_…` / `S-1-5-5-0-…`）。它通常无害，但会让
> ACL 与本文不符，也会丢掉 `Administrators`。清理方法：
>
> ```powershell
> icacls "$dir\proxy.js" /remove *S-1-5-5-0-<你的登录会话 ID>
> ```

---

## 5. 写隧道配置并启动

### 5.1 `config.yml`

```yaml
tunnel: <TUNNEL-ID>
credentials-file: 'D:\magpie-public\secrets\<TUNNEL-ID>.json'
no-autoupdate: true
metrics: 127.0.0.1:20242
ingress:
  - hostname: 'apimagpie.example.com'
    service: http://127.0.0.1:8790
    originRequest:
      connectTimeout: 30s
      noHappyEyeballs: true
      disableChunkedEncoding: false
      noTLSVerify: false
  - service: http_status:404
```

要点：

- `tunnel` 与 `credentials-file` 必须匹配第 4.4 步实际生成的。
- `service` 指向**代理端口**（8790），**不是** 3425。
- `metrics` 换一个没被占用的端口（若已有别的 cloudflared 在用 20241/20242，就换 20243）。
- 最后那条 `http_status:404` 是兜底规则，不要删。

### 5.2 手工启动验证

```bash
cd "D:/magpie-public"
node proxy.js > logs/proxy.out.log 2>&1 &

./bin/cloudflared.exe tunnel --config "D:/magpie-public/config.yml" \
    --no-autoupdate --metrics 127.0.0.1:20242 run > logs/cloudflared.out.log 2>&1 &

sleep 12
tail -20 logs/cloudflared.out.log     # 应看到 Registered tunnel connection
```

然后跑第 7 节的验证清单。

---

## 6. 启动方式：纯手动（推荐）

本方案**不注册任何开机自启**。服务由 `start.cmd` 手动控制，避免在你不想它跑的时候
偷偷占用资源或消耗额度。

### 6.1 文件

- `start.cmd`：启动 / 停止 / 查看状态（唯一入口）。
- `stop.cmd`：**只停公网这一侧**（代理 + 隧道 + 看门狗），独立可用、幂等；
  比 `start.cmd stop` 更完整（校验 8790 + 20242、失败退出 1），
  即使 `start.cmd` 被改坏也能用它收尾。
- `run.ps1`：看门狗，负责拉起代理与隧道、异常重启、写日志。
- `launch.vbs`：用隐藏窗口调用 `run.ps1`（`start.cmd` 会调用它）。
- `sync-key.ps1`：把 `settings.json` 的 `lanKey` 同步到 `API-KEY.txt`，方便随时查看。
  看门狗每轮循环都会调用它；只有 key 真正变化时才写盘。

复制到目标机后，除了 `config.json` 的 `settingsPath`（见 3.2），还要：
按第 4 节创建隧道并把隧道 ID、凭据文件与域名写进 `config.yml`；准备
`secrets/cert.pem` 与隧道凭据；按 4.6 收紧目录 ACL。完整顺序见第 2–6 节。
日志路径默认是脚本旁边的 `logs\proxy.log`，不需要配置。

- `run.ps1` 的 Node 路径：先试 `C:\Program Files\nodejs\node.exe`，不存在则自动
  `Get-Command node.exe` 查找，一般无需修改；想固定就改顶部的 `$NodeExe`。
- `sync-key.ps1` 的 `$SettingsPath` 默认取 `$env:USERPROFILE\.config\magpie\settings.json`，
  不用按用户名改；`API-KEY.txt` 里的 Endpoint 从 `config.yml` 的 `hostname:` 读取。

`$Here` 会自动取脚本所在目录，无需改。`config.yml`、`proxy.js` 也按相对位置查找。

> 脚本已对含空格的路径加引号（`-ArgumentList ('"{0}"' -f $ProxyJs)`）。
> 如果你的安装目录含空格，**不要**把这层引号去掉。

### 6.2 用法

| 操作 | 命令 |
|---|---|
| 启动 | 双击 `start.cmd` |
| 停止 | 双击 `stop.cmd`（推荐；`start.cmd stop` 是简化版） |
| 查看状态 | `start.cmd status` |

`start.cmd` 会等到代理真正开始监听才返回，并同时报告 Magpie 是否在线。
`stop.cmd` 会核对 8790 / 20242 是否释放，并明确打印 Magpie 仍在 3425 运行（未被触碰）；
没在运行时它只打印 `[i] Nothing was running.` 且以 0 退出。

### 6.3 启动顺序无关

这是设计上的重点，务必理解：

- **先 Magpie 后 start.cmd**：立刻可用。
- **先 start.cmd 后 Magpie**：`start.cmd` 会提示「Magpie 未运行」，
  隧道和代理照常待命；等你启动 Magpie 后，**公网立即恢复，不需要重跑 start.cmd**。

之所以能做到，是因为 `proxy.js` **不使用上游连接池**（`upstreamAgent = false`），
每个请求都新建到 `127.0.0.1:3425` 的连接。

> 如果改成 keep-alive 连接池，Magpie 重启后池里残留的死连接会让下一次请求报 502，
> 即使 Magpie 已经正常。所以这里刻意关掉了它。

### 6.4 如果你确实想要开机自启

纯手动是默认选择。若某天想改成自动，注册一个登录触发的计划任务即可：

```powershell
$action = New-ScheduledTaskAction -Execute 'wscript.exe' `
    -Argument '"D:\magpie-public\launch.vbs"'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName 'MagpiePublicAPI' -Action $action `
    -Trigger $trigger -Settings $settings -Force
```

取消自启：

```powershell
Unregister-ScheduledTask -TaskName 'MagpiePublicAPI' -Confirm:$false
```

`-ExecutionTimeLimit ([TimeSpan]::Zero)` 表示不限运行时长，这对常驻看门狗是必需的。

### 6.5 实测

```powershell
cmd /c start.cmd status
```

应显示 Watchdog / Proxy / Tunnel 均 running，Magpie 视其是否启动而定。

若 Watchdog 为 STOPPED 但 Proxy 在监听，说明是手工杀进程留下的孤儿状态
（隧道若挂掉就没有人重启它）：先 `start.cmd stop` 再 `start.cmd`。

---

## 7. 验收清单（全部必须通过）

把 `example.com` 换成你的域名。

| # | 命令 | 期望 |
|---|---|---|
| 1 | `curl http://127.0.0.1:3425/v1/models`（无 Key，直连 Magpie） | `200`（证明代理必要） |
| 2 | `curl https://apimagpie.example.com/v1/models`（无 Key） | `401` |
| 3 | 带错误 Key | `401` |
| 4 | 带正确 Key | `200` |
| 5 | `curl -N` 流式 `chat/completions` | 逐块到达，非一次性 |
| 6 | 带正确 Key 访问 `/v1/magpie/admin/`、`/api/settings` | `404` |
| 7 | 访问 `/healthz`、`/` | `404` |
| 8 | `netstat -an` | 3425/8790/20242 均 `127.0.0.1`，无 `0.0.0.0:3425` |
| 9 | Magpie 进程 | 仍在运行，PID 未变 |
| 10 | 真实推理 | 返回正常内容 |
| 11 | `GET /v1beta/models` 与 `POST /v1beta/models/<model>:generateContent`（`x-goog-api-key`） | `200`，Gemini 结构 |

一次跑完 1–7 的脚本：

```bash
KEY=$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).lanKey)" \
      "$USERPROFILE/.config/magpie/settings.json")
H=https://apimagpie.example.com

printf "1 direct-no-key : "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 15 http://127.0.0.1:3425/v1/models
printf "2 public-no-key : "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 25 $H/v1/models
printf "3 public-bad-key: "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 25 -H "Authorization: Bearer nope" $H/v1/models
printf "4 public-ok-key : "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 25 -H "Authorization: Bearer $KEY" $H/v1/models
printf "6 admin-path    : "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 25 -H "Authorization: Bearer $KEY" $H/v1/magpie/admin/
printf "7 healthz       : "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 25 -H "Authorization: Bearer $KEY" $H/healthz
printf "11 gemini-models: "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 25 -H "x-goog-api-key: $KEY" $H/v1beta/models
```

期望依次为 `200 401 401 200 404 404 200`。

---

## 8. 客户端怎么用

三种形态都实测可用，**Key 就是 `settings.json` 里的 `lanKey`**：

```python
# OpenAI 兼容：base_url 带 /v1
from openai import OpenAI
client = OpenAI(
    base_url="https://apimagpie.example.com/v1",
    api_key="sk-magpie-key-...",
)
resp = client.chat.completions.create(
    model="vendor-b/vision-model",   # 用 /v1/models 返回的 id
    messages=[{"role": "user", "content": "hi"}],
)
```

```python
# Anthropic 兼容：base_url 不带 /v1（SDK 拼 /v1/messages，并自动发 x-api-key）
from anthropic import Anthropic
client = Anthropic(base_url="https://apimagpie.example.com", api_key="sk-magpie-key-...")
```

```bash
# Gemini 兼容：Google SDK 默认就发 x-goog-api-key，把 base URL 指到本域名即可
curl "https://apimagpie.example.com/v1beta/models/vendor-b/vision-model:generateContent" \
  -H "x-goog-api-key: sk-magpie-key-..." \
  -H "content-type: application/json" \
  -d '{"contents":[{"parts":[{"text":"hi"}]}]}'
```

查可用模型与当前 Key：

```bash
curl -s -H "Authorization: Bearer $KEY" https://apimagpie.example.com/v1/models
curl -s -H "x-goog-api-key: $KEY" https://apimagpie.example.com/v1beta/models
node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).lanKey)" \
     "$USERPROFILE/.config/magpie/settings.json"
```

本机还提供了一个自动同步的可读文件 `API-KEY.txt`（见第 6 节），随时打开即可看到当前 Key。

---

## 9. 日常运维

### 日志

| 文件 | 内容 |
|---|---|
| `logs/proxy.log` | 每请求一行（放行/拒绝原因、状态码、耗时）；超过 8 MB 轮转为 `.1` |
| `logs/proxy.out.log` / `proxy.err.log` | 代理的 stdout/stderr（正常时为空） |
| `logs/cloudflared.err.log` | 隧道日志（cloudflared 把 INFO 日志写到 **stderr**；`.out.log` 通常为空） |
| `logs/supervisor.log` | 看门狗启停、Magpie 可达性变化；超过 4 MB 轮转为 `.1` |

### 存活检查

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8790/v1/models   # 期望 401
```

返回 401 说明代理活着且在正确拒绝无 Key 请求；返回 000/超时说明代理挂了。

### Key 轮换

`lanKey` 在 Magpie GUI 里没有直接编辑入口，改法是编辑 `settings.json` 的 `lanKey`
字段（先退出 Magpie，改完再启动，避免被覆盖），或删掉该字段让 Magpie 重新生成。

改完后代理**自动跟随**（每 5 秒重读），无需重启。Key 在 **≤5 秒**内生效；
若 `settings.json` 暂时读不到，代理会继续沿用旧 Key 直到恢复可读。
客户端换成新 Key 即可。

### 端口冲突排查

若 8790 / 20242 被占：

```bash
netstat -ano | findstr ":8790"
```

需要同步修改的地方：

- `config.json` 的 `listenPort` / `upstream`
- `config.yml` 的 `service`（指向代理端口）与 `metrics`
- `start.cmd` / `stop.cmd` 顶部的 `PORT` / `METRICS` / `UPSTREAM`（只用于状态展示与端口探测）
- 本文件第 7 节验收清单里的端口

`run.ps1` **不需要**改：代理端口与上游取自 `config.json`，metrics 地址取自
`config.yml` 的 `metrics:` 行。

### 停止

```cmd
stop.cmd
```

`start.cmd stop` 也可用，但它是简化版：只校验 8790、失败也退出 0。
`stop.cmd` 校验 8790 + 20242、幂等、失败退出 1，推荐使用。

> `stop` 会中断**正在传输中**的请求（客户端收到 502）；重启后新请求立即恢复。
> 代理不做请求重放，长推理请求请等空闲时再停。

等价的手工方式（若 `start.cmd` 不可用）。下面这段会排除自身与祖先进程，
否则执行它的终端本身也会命中命令行匹配而被杀掉：

```powershell
$self = $PID
$ancestors = @()
$p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $self)
while ($p) {
    $ancestors += $p.ProcessId
    $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $p.ParentProcessId) -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -in @('node.exe','cloudflared.exe','powershell.exe') -and
                 $_.CommandLine -like '*magpie-public*' -and
                 $ancestors -notcontains $_.ProcessId } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
```

> 必须按 `Name` 精确匹配。只匹配命令行会误杀你自己正在用的终端（它的命令行里也含这个路径）。

### 完全卸载 / 回滚

```bash
# 1. 停服务（纯手动模式没有计划任务需要删）
stop.cmd              # Windows cmd 里执行；推荐；start.cmd stop 是简化版

# 2. 删隧道
cd "D:/magpie-public"
./bin/cloudflared.exe tunnel --origincert "secrets/cert.pem" delete magpie-public

# 3. 删目录
rm -rf "D:/magpie-public"
```

> 若你曾按 6.4 节启用过开机自启，先执行
> `Unregister-ScheduledTask -TaskName 'MagpiePublicAPI' -Confirm:$false`。

再在 Cloudflare 控制台删除该子域名的 DNS 记录。

---

## 10. 与机器上其他 cloudflared 项目共存

若这台机器还有别的项目在用 cloudflared，按以下原则保证互不干扰：

| 维度 | 必须不同 |
|---|---|
| 隧道 | 各自独立创建，不共用 |
| 凭据文件 | 各自独立 `.json` |
| 配置 | 各自独立 `config.yml`（不用同一个） |
| metrics 端口 | 各用不同端口（如 20241 / 20242 / 20243） |
| 代理端口 | 各用不同端口 |
| 证书 | 各自的 `secrets/cert.pem` 副本 |

只要这些都不共享，两条隧道就是完全独立的两个进程，一条重启不影响另一条。

核对当前所有隧道：

```bash
./bin/cloudflared.exe tunnel --origincert "secrets/cert.pem" list
```

---

## 11. 常见问题

**Q：公网访问返回 502 / 530**
A：隧道没连上，或上游代理没起来。检查 `logs/cloudflared.err.log` 有无
`Registered tunnel connection`（cloudflared 把日志写到 stderr，`.out.log` 通常是空的），
以及 `curl 127.0.0.1:8790/v1/models` 是否 401。

**Q：返回 401，但我带了正确的 Key**
A：Key 与 `settings.json` 里的 `lanKey` 不一致（可能 Magpie 刚轮换）。重新读取 Key。
若 `settingsPath` 写错，代理读不到 Key，会返回 `503`（不是 401）。

**Q：Gemini SDK 报 401**
A：Key 只认三种**请求头**：`Authorization: Bearer`、`x-api-key`、`x-goog-api-key`。
Google SDK 用的是 `x-goog-api-key`，已被支持；但**查询串 `?key=` 形式不支持**
（会出现在 URL 与边缘日志里），请改用请求头。

**Q：带正确 Key 返回 200，但 `content` 是空字符串**
A：推理型模型（如 `vendor-a/reasoning-model`）会先把 token 用在思考上。`max_tokens` 太小时
思考就把预算用完了，`content` 为空、真正的思考内容在 `reasoning_content` 字段。
把 `max_tokens` 提到 64 以上即可。这类模型还可以用 `reasoning_effort`
（OpenAI 风格）/ `thinking.budget_tokens`（Anthropic）/ `thinkingConfig.thinkingBudget`
（Gemini）调节思考量，参数会被原样透传。

**Q：返回 404，日志里是 `DENY path not allowed … POST /responses`（或 `/chat/completions`）**
A：客户端的 base URL 少了 `/v1`。OpenAI 兼容客户端要写成
`https://<域名>/v1`（SDK 再拼 `/chat/completions`）；Anthropic 客户端是
`https://<域名>`（SDK 自己拼 `/v1/messages`）；用 `curl` 时路径要写全 `/v1/...`。
代理的白名单是精确匹配的，缺 `/v1` 一律 404，不会转发给 Magpie。

**Q：返回 429**
A：两种可能，看响应体：`rate limit exceeded` 是调用方超过 600 次/分（或全站超过
1800 次/分）；`too many failed attempts` 是该调用方 60 秒内鉴权失败 ≥20 次。
响应带 `Retry-After`，等一个窗口（60 秒）即可恢复。**注意节流在鉴权之前**，
所以被节流期间即使带正确的 Key 也会拿到 429。

**Q：隧道起来了但域名打不开**
A：DNS 记录没生效。检查 `route dns` 是否成功、控制台里该子域名是否有 CNAME 指向
`<TUNNEL-ID>.cfargotunnel.com`。

**Q：改了 `config.yml` 不生效**
A：需要重启 cloudflared 进程。`start.cmd stop` 后再 `start.cmd`。

**Q：能不能不加代理，直接把隧道指向 3425？**
A：不能。那样等于把无鉴权的推理接口暴露到公网（见第 0 节）。管理面也会一起暴露。
