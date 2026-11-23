# v2.0.0 - 安全加固与本机控制面板 / Security hardening and local control panel

发布日期 / Release date：**2026-11-23 10:00:00 +08:00**

Tag：**v2.0.0**

[中文](#中文) · [English](#english)

---

## 中文

**magpie-public v2.0.0** 把本机 Magpie 的推理接口通过 Cloudflare Tunnel 发布为必须鉴权的公网 API，同时确保管理面、密钥存储和控制面板不暴露到公网。

本公开仓库从脱敏快照重建，不包含私有部署的 Git 历史、真实域名、Tunnel ID、密钥、日志或本机运行状态。

### 主要特性

- **公网推理强制 API Key。** 复用 Magpie `lanKey`，支持 `Authorization: Bearer`、`x-api-key`、`x-goog-api-key`；Key 不可用时失败关闭，不放行请求。
- **方法与路径双重白名单。** 支持 OpenAI Chat/Responses、Anthropic Messages/count_tokens、Gemini generate/stream/countTokens；未登记的方法、动作、管理路径和文件路径均返回 404。
- **协议透明。** 请求体和响应体（包括 SSE）原样透传，不解析或重写 JSON；错误结构保持上游原样。
- **请求头净化。** 删除公网 Key、伪造身份头、标准逐跳头以及 `Connection` 动态指定的头，上游只看到固定调用方标识。
- **滥用防护。** 按调用方和全局限流、鉴权失败节流、32 MB 请求体上限、上游超时和日志轮转。伪造 supervisor User-Agent 不再获得失败节流豁免。
- **可靠看门狗。** Key 不可用时把 503 视为“进程存活但降级”，不再反复重启；cloudflared 连续三次 readiness 失败才重启；日志写失败不会终止看门狗。
- **统一启停。** `start.cmd`、`stop.cmd` 和面板共用 `control.ps1`，通过 PID 文件、完整路径复核和精确孤儿枚举识别所属进程，避免误杀其他目录或其他 Tunnel。
- **本机桌面控制面板。** `panel.cmd` 提供启动、停止、刷新、复制公网地址和打开日志；不监听 HTTP 端口，打开或关闭面板不会自动改变服务状态。
- **本机明文、公开隔离。** `API-KEY.txt` 可以继续明文保存在受限 ACL 的本机目录；账户级 `cert.pem` 与日常 Tunnel 运行凭据分离，运行目录只需 `<tunnel-id>.json`。

### 安全模型

Cloudflare Tunnel 从 loopback 连接 Magpie，而 Magpie 对 loopback 请求故意免 gateway key。直接把 Tunnel 指向 `127.0.0.1:3425` 会把无鉴权推理接口发布到公网，因此必须保留中间代理：

```text
Internet
  → Cloudflare
  → cloudflared
  → 127.0.0.1:8790（本代理：Key + 方法/路径白名单）
  → 127.0.0.1:3425（Magpie）
```

代理与 Tunnel ingress 必须精确指向同一个 loopback listener，防止配置漂移绕过鉴权。桌面控制面板不经过 Cloudflare，也不创建监听端口。

### 与 v1.x 不兼容的变化

1. `config.json` 中的 `allowedPaths` 已替换为 `allowedRoutes`，每项必须同时声明 `path` 和 `methods`。
2. `config.yml` 的 ingress `service` 必须与 `config.json` 的代理 listener 完全一致，不允许额外路径、query 或 user info。
3. 启停和状态统一由 `control.ps1` 实现；`status` 在停止时退出 1、降级时退出 2，`ready` 和 `waiting-upstream` 退出 0。
4. 停止逻辑不再按目录名子串匹配进程；新增 `common.ps1`、`control.ps1`、`panel.ps1`、`panel.cmd`，升级时必须一起复制。
5. 账户级 `cert.pem` 不再放在运行目录。默认管理位置为 `%USERPROFILE%\.config\magpie-public\cert.pem`；日常运行只使用 Tunnel JSON。
6. `start.cmd stop` 与 `stop.cmd` 现在完全等价，重复停止为幂等操作。

### 从 v1.x 升级

1. 备份自己的 `config.json`、`config.yml` 和本机凭据，不要在旧目录中直接覆盖掉真实配置。
2. 复制全部 v2.0.0 脚本，按新 `config.json` 示例把旧白名单迁移为 `allowedRoutes`。
3. 保留自己的域名、Tunnel ID、端口与 `settingsPath`，确认 ingress 精确指向新代理 listener。
4. 将账户级 `cert.pem` 移到项目外的管理目录；运行目录只保留 `<tunnel-id>.json`。
5. 运行 `start.cmd status` 和 `start.cmd`，确认状态为 `ready` 或 `waiting-upstream`，再验证无 Key 为 401、正确 Key 为 200。

### 环境要求

- Windows 10/11，Windows PowerShell 5.1+；
- Node.js 18 或更高版本；
- 本机 Magpie gateway；
- Cloudflare 托管域名与 `cloudflared.exe`（版本和 SHA-256 见 `bin/README.md`）。

### 快速开始

1. 克隆仓库，把 `cloudflared.exe` 放进 `bin/`。
2. 按 `DEPLOY-OTHER-MACHINE.md` 创建 Tunnel、DNS 和本机凭据。
3. 在 `config.yml` 中填入自己的 Tunnel ID、凭据路径和 hostname；在 `config.json` 中确认 `settingsPath`、端口和 `allowedRoutes`。
4. 运行 `start.cmd`，或双击 `panel.cmd` 使用本机面板。
5. 使用 `API-KEY.txt` 中的本机 Key 调用 `https://<your-host>/v1/models`。

### 验证

`VERIFY.md` 记录了 **67 项去重通过的检查**，包括：

- 鉴权、管理面/密钥隔离、方法与路径白名单、动态逐跳头；
- 请求体限制、SSE、Key 轮换、限流、日志轮转和上游停复；
- OpenAI、Anthropic、Gemini 的真实协议、多模态、思考参数、长上下文与并发矩阵；
- 看门狗恢复、真实 Magpie/公网启停、在途请求中断、ACL 和相邻项目完整性；
- 桌面快捷方式及启动、刷新、复制、日志、取消/确认停止、关闭等 8 项真实 GUI 点击测试。

### 已知限制

- 停止服务会中断在途请求，代理不会自动重放。
- 很长的非流式请求可能先触发 Cloudflare 边缘超时；长请求建议使用流式响应。
- 已在 Magpie v0.1.4479 验证，其他版本的路由或鉴权行为可能不同。
- 看门狗、启停和面板是 Windows 专用实现。

### 发布说明

- 所有域名、Tunnel ID、路径和密钥均为示例值或本机环境变量。
- `secrets/`、`API-KEY.txt`、`logs/`、`run/`、证书、私钥和 `bin/*.exe` 均被 Git 忽略。
- `main` 的历史从一个脱敏后的初始提交重新开始；Tag 与提交时间统一为 2026-11-23 10:00:00 +08:00。
- License：MIT。

---

## English

**magpie-public v2.0.0** publishes a local Magpie inference gateway through Cloudflare Tunnel with mandatory API-key authentication, while keeping management interfaces, secret storage, and the control panel off the public network.

This public repository was rebuilt from a sanitized snapshot. It contains no private deployment history, real endpoint, tunnel ID, key, log, or local runtime state.

### Highlights

- **Mandatory API-key gate.** Reuses Magpie `lanKey` and accepts `Authorization: Bearer`, `x-api-key`, or `x-goog-api-key`; requests fail closed when no key is available.
- **Method + path allowlist.** OpenAI Chat/Responses, Anthropic Messages/count_tokens, and Gemini generate/stream/countTokens are supported. Unregistered methods, actions, management paths, and file paths return 404.
- **Protocol transparency.** Request and response bodies, including SSE and upstream errors, pass through without JSON rewriting.
- **Header hygiene.** Public credentials, spoofed identity headers, standard hop-by-hop headers, and headers nominated by `Connection` are removed before forwarding.
- **Abuse controls.** Per-caller/global limits, auth-failure throttling, a 32 MB body cap, upstream timeout, and log rotation. A forged supervisor User-Agent no longer bypasses auth-failure accounting.
- **Reliable supervisor.** A key-related 503 is treated as alive-but-degraded rather than crashing the proxy; cloudflared is restarted only after three failed readiness checks; logging failures cannot kill the supervisor.
- **Unified lifecycle.** CLI and GUI share `control.ps1`, with PID files, full-path verification, and exact orphan detection to avoid killing unrelated processes.
- **Local desktop panel.** `panel.cmd` provides start, stop, refresh, endpoint copy, and log access without opening an HTTP listener.
- **Local plaintext, public isolation.** The local key file remains plaintext by design under a restricted ACL. Account-level `cert.pem` is separated from the tunnel JSON needed at runtime.

### Security model

Cloudflare Tunnel connects from loopback, where Magpie deliberately allows requests without a gateway key. Pointing the tunnel directly at `127.0.0.1:3425` would therefore expose unauthenticated inference. Keep the authenticating proxy in between:

```text
Internet
  → Cloudflare
  → cloudflared
  → 127.0.0.1:8790 (this gateway)
  → 127.0.0.1:3425 (Magpie)
```

Tunnel ingress must exactly match the proxy listener so configuration drift cannot bypass authentication. The desktop panel creates no listening socket.

### Breaking changes from v1.x

- `allowedPaths` is replaced by `allowedRoutes`, with explicit `path` and `methods` per entry.
- Ingress must exactly match the configured proxy listener.
- Status uses documented exit codes: 0 for ready/waiting-upstream, 1 for stopped, and 2 for degraded.
- Lifecycle commands share one implementation and no longer match processes by folder-name substring.
- Account-level `cert.pem` belongs outside the runtime directory; only the tunnel JSON is required at runtime.
- Copy all new scripts during upgrade, including `common.ps1`, `control.ps1`, and the panel files.

### Requirements

- Windows 10/11 with Windows PowerShell 5.1+
- Node.js 18 or newer
- A local Magpie gateway
- A Cloudflare-managed domain and `cloudflared.exe`

### Getting started

1. Clone and place `cloudflared.exe` in `bin/`.
2. Follow `DEPLOY-OTHER-MACHINE.md` to provision the tunnel, DNS, and local credentials.
3. Fill in your own hostname, tunnel ID, paths, and `allowedRoutes`.
4. Run `start.cmd` or open `panel.cmd`.
5. Call `https://<your-host>/v1/models` using the key from `API-KEY.txt`.

### Verification

`VERIFY.md` records **67 deduplicated passing checks** across proxy fault injection, lifecycle failures, real public API calls, long context, multimodal input, concurrency, ACL/integrity checks, and eight real UI Automation actions through the desktop shortcut.

### Known limitations

- Stopping the service interrupts in-flight requests; the gateway does not replay them.
- Cloudflare's own timeout may affect long non-streaming generations; streaming is recommended.
- Verified with Magpie v0.1.4479; behavior may differ on other versions.
- Supervisor, lifecycle commands, and the panel are Windows-only.

### Notes

- Every endpoint, tunnel ID, path, and key is a placeholder or a local environment variable.
- Runtime secrets, logs, PID files, private keys, certificates, and `bin/*.exe` are git-ignored.
- The `main` branch starts a fresh history from one sanitized initial commit. Commit and tag timestamps are both 2026-11-23 10:00:00 +08:00.
- License: MIT.
