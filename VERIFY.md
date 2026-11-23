# 当前版本验证记录

日期：2026-11-23

对象：`D:\magpie-public` 当前工作树

环境：Windows、Node.js v24.18.0、Magpie 0.1.4479、cloudflared 2026.11.0、Windows PowerShell 5.1 / PowerShell 7。

## 1. 结论与测试方法

本轮先完成两轮独立子代理代码复审并修复其发现的问题，再执行故障注入、真实公网和真实进程生命周期测试。

| 测试层 | 通过 | 说明 |
|---|---:|---|
| 仓库外 Node mock 代理测试 | 12 组 | 鉴权、路由、请求头、body、SSE、Key、限流、日志、上游停复 |
| 仓库外 PowerShell 控制故障注入 | 6 组 | 503、日志不可写、外部端口、孤儿、归属、ingress 防绕过 |
| 真实公网在线矩阵 | 32 项 | 四模型、三协议、多模态、思考、错误、长上下文、并发 |
| 生命周期与环境 | 9 项 | 真实启停、在途中断、面板、同步、ACL、哈希、自启/二进制 |
| 收官桌面快捷方式与 GUI 点击 | 8 项 | 启动、刷新、复制、日志、取消/确认停止、关闭 |
| **去重合计** | **67 项** | 全部通过 |

脱敏后的开源副本还重新执行了同一套 12 组代理 mock 回归（追加 Gemini 错误方法用例），全部通过；IPv6 状态地址也在 Windows PowerShell 5.1 与 PowerShell 7 下分别验证为 `[::1]:3425`。这些复跑不重复计入 67 项。

此外：

- `proxy.js` 通过 `node --check`；所有 PowerShell 脚本在 Windows PowerShell 5.1 和 PowerShell 7 下均为 0 解析错误。
- `cloudflared tunnel --config config.yml ingress validate` 返回 `OK`。
- `git diff --check` 通过。
- 测试脚本、mock、图片和 JSON 结果均保存在仓库外，发布版使用 `C:\magpie-public-verification\work` 作为脱敏占位路径，不属于运行依赖；按本轮要求未把 `VERIFY.md` 转成仓库内自动化测试文件。

> 测试本身也经过纠错：SSE 必须按 `data:` 事件解析增量文本，不能直接在协议原文里搜索连续 PONG；停止时收到完整的 Cloudflare 502 错误页属于“请求被中断”，不属于“推理完成”。最终记录均来自修正后的完整实测，而非把首次断言错误算作产品缺陷或掩盖重跑。

## 2. 核心安全边界

### 2.1 鉴权与协议透明性

| 检查 | 实测 |
|---|---|
| `127.0.0.1:3425/v1/models` 无 Key | 200，证实本机 loopback 豁免 |
| `127.0.0.1:8790/v1/models` 无 Key | 401 |
| 公网无 Key / 错误 Key | 401 / 401 |
| 公网正确 Bearer / `x-api-key` / `x-goog-api-key` | 200 / 200 / 200 |
| 查询串 `?key=` 而无有效请求头 | 401 |
| 无缓存且 settings 不存在 | 503，绝不转发 |
| 模型列表在 3425 / 8790 / 公网三处的响应体 SHA-256 | 完全相同：`c02e751cc1c5482b26de13f31476d4c704e21ebaf7674e6d6c3fd512211747f3` |

公网转发时，三种公网 Key、`cf-*`、`x-forwarded-*`、`x-real-ip`、`proxy-authorization`、`Connection` 动态指定的自定义头均不会到达 mock；`Host` 改为上游，`Authorization` 改为固定 `Bearer magpie-public`，请求体逐字节一致。响应侧同样删除动态逐跳头。

### 2.2 管理面、密钥和方法白名单

以下真实公网请求即使带正确 Key 也全部为 404：

```text
/v1/magpie/limit  /v1/magpie/admin/  /v1/magpie/quotas
/api/settings     /healthz            /
/admin            /v1/magpie          /secrets/cert.pem
/API-KEY.txt
```

`DELETE /v1/models/x`、`POST /v1/models`、`PUT /v1/chat/completions`、`POST /v1beta/models/x:delete`，以及 `GET /v1beta/models/x:generateContent` 均为 404，mock 确认没有到达上游。允许的 Gemini `countTokens` 实测 200。

编码点/斜杠、裸 `..`、`//`、反斜杠和 NUL 等路径形状在代理层拒绝。Tunnel ingress 必须精确等于当前代理 listener；在临时配置中把 service 改指 3425 会在启动任何子进程之前被拒绝。

### 2.3 监听与密钥存储

真实运行时：

```text
127.0.0.1:3425   Magpie
127.0.0.1:8790   proxy.js
127.0.0.1:20242  cloudflared metrics
```

未监听 `0.0.0.0:3425/8790/20242`。WinForms 面板启动前后系统监听地址集合完全相同，面板 PID 没有任何 listening socket。

`API-KEY.txt` 继续按设计明文保存在本机。12 个检查过的代码/配置/Key 文件，以及 `%USERPROFILE%\.config\magpie-public\cert.pem`，ACL 均只包含当前用户、SYSTEM、Administrators。运行目录不再保存账户级 `cert.pem`，只保留 Tunnel 自身 JSON。

## 3. 仓库外 mock 故障注入（12 组）

| 测试 | 结果 |
|---|---|
| 三种鉴权头、无/错 Key、查询 Key | 全部符合预期 |
| 方法 + 路径白名单、Gemini countTokens | 未登记方法/动作 404（含 GET generateContent），countTokens 200 |
| 管理、密钥和编码穿越路径 | 全部 404，上游请求数不增加 |
| 请求/响应逐跳头和凭据净化 | 全部正确，body 不变 |
| Content-Length 与 chunked 超限 | 均 413；180,055 字节正常请求完整到达 |
| SSE 与上游超时 | 至少两次间隔到达；停滞上游 504 |
| Key 轮换与缓存容错 | 新 Key 生效、旧 Key 401；文件暂缺时缓存 Key 按设计可用 |
| 上游停止/恢复 | 502 → 200，代理 PID 不变 |
| 25 个并发鉴权请求 | 全部 200 |
| 无 Key 文件 | 503，失败关闭 |
| 伪造探针 UA、XFF 和全局限流 | 小窗口下第 4 次坏 Key 429；XFF 不能换桶；全局第 5 次 429 |
| 日志轮转 | 超过测试阈值后生成 `proxy.log.1` |

限流故障注入使用 300 ms 小窗口和阈值 3/4，避免无意义地对真实服务发送数百次请求；生产阈值仍为 600/1800/20、60 秒。

## 4. 控制层故障注入（6 组）

| 测试 | 结果 |
|---|---|
| Key 缺失 + `supervisor.log` 被独占 35 秒 | 代理持续 503，PID 连续 35 秒不变；看门狗不退出、不重启代理 |
| degraded JSON 与精确 fixture stop | 状态和退出码正确，只清理 fixture |
| 外部进程占用代理端口 | start 返回冲突，外部进程存活，看门狗未启动 |
| 无看门狗孤儿代理 | 状态 degraded，精确清理后外部进程仍存活 |
| cloudflared 同 exe、不同 config | 不属于本项目，不会被停止 |
| ingress service 改指 3425 | 启动前校验失败，不能绕过鉴权代理 |

## 5. 真实公网协议矩阵（32 项）

### 5.1 OpenAI / Anthropic / Gemini

| 调用 | 实测 |
|---|---|
| OpenAI chat：四个模型 | 全部 200 且返回 PONG |
| `kimi-code-cn/k3.1-pro` | 15.502 s |
| `kimi-code-cn/k3.1-pro-highspeed` | 7.095 s |
| `workbuddy/deepseek-v4.1-flash` | 2.998 s |
| `trae-cn/deepseek-v4.1-flash-max` | 1.839 s |
| OpenAI `/v1/responses` | 200，PONG |
| Anthropic `/v1/messages` | 200，PONG |
| Anthropic SSE | 200，正确解析 message_start / content_block_delta |
| Anthropic `count_tokens` | 200，`input_tokens: 6` |
| Anthropic `?beta=true` | 200，查询串透传 |
| Gemini `generateContent` | 200，PONG |
| Gemini `streamGenerateContent?alt=sse` | 200，SSE 正常 |
| Gemini `countTokens` | 200，`totalTokens: 6` |
| 公网 OpenAI SSE | 3 个网络块，最大间隔 112 ms，非一次性缓冲 |

模型耗时是本次上游真实延迟，不作为性能 SLA。首次矩阵曾观察到 highspeed 119.659 s 才返回，因此测试超时设为 240 秒，最终完整矩阵中的该调用为 7.095 s。

### 5.2 思考参数

| 参数 | 结果 |
|---|---|
| OpenAI `reasoning_effort: low / high` | 均 200、答案 391；reasoning tokens 18 / 19 |
| Anthropic `thinking.budget_tokens: 1024` | 200、答案 391；thinking tokens 35 |
| Gemini `thinkingBudget: 0 / 1024` | 均 200、答案 391；thoughtsTokenCount 22 / 19 |

这些数字证明参数被上游接受和透传，不证明较高档位一定消耗更多思考 token；实际效果取决于上游和模型。

### 5.3 多模态

测试图片为真实的 64×64 PNG，左半红、右半蓝：

| 协议 | 实测 |
|---|---|
| OpenAI `image_url` data URL | “Red is on the left and blue is on the right.” |
| Anthropic base64 image | 正确识别左红右蓝 |
| Gemini `inlineData` | 正确识别左红右蓝 |

### 5.4 错误透传

- 未知模型：404，保留 Magpie 的 `magpie knows no model "no/such-model"` 错误结构。
- 坏 JSON：400，保留 `invalid request: expected a JSON object`。
- 代理没有把上游错误改成自己的成功响应或通用空错误。

## 6. 长上下文与并发

固定载荷为 **180,229 字符**，中央放置 `MAGPIE-NEEDLE-7F3A`。本轮实际分词约 40k，而不是旧记录的约 32k，文档按本次真实 usage 记录：

| 组合 | 实际输入 token | 结果 |
|---|---:|---|
| OpenAI chat，workbuddy，reasoning high | 40,101 | 200，返回 7F3A |
| Anthropic，k3.1-pro，thinking 1024 | 40,147 | 200，返回 7F3A |
| Gemini，trae，thinkingBudget 0 | 40,095 | 200，返回 7F3A |
| OpenAI，k3.1-pro-highspeed + 8×8 绿色 PNG | 40,163 | 200，同时识别暗号和绿色 |

随后执行 11 路混合并发：四模型 chat、responses、两个 messages、两个 Gemini、两个模型列表，**11/11 为 200，总耗时 7.408 s**。

## 7. 真实生命周期（9 项中的启停/面板部分）

| 场景 | 实测 |
|---|---|
| 人为结束所属代理，随后 `start.cmd` | 看门狗恢复，代理 PID 已更换；Tunnel 和 Magpie 不变；start 等待真实 ready |
| Magpie 网关停止 | 公网带正确 Key 为 502 |
| Magpie 再次启动 | 公网恢复 200，代理 PID 始终不变 |
| 公网 `stop.cmd` | 所属看门狗/代理/Tunnel 全停，Magpie 继续运行；公网为 Cloudflare 502 |
| 公网重新 `start.cmd` | ready，鉴权请求恢复 200 |
| 停止正在进行的流式请求 | 客户端收到 502（6,455 字节错误体），没有误判为完整推理；下一次启动恢复 200 |
| 真实 WinForms 面板 | 窗口标题正确，打开/关闭正常；零新增监听，服务状态不变 |

Magpie 0.1.4479 的 `magpie.exe tray` 可能由 launcher 派生实际 gateway 子进程。首次仅结束 launcher 后 3425 仍由已核实的子进程监听，因此测试随后按进程树和实际监听 PID 关闭该**本次测试拥有的** gateway，再完成 502/200 验证。项目自己的 start/stop 从不尝试结束 Magpie，不受这一应用生命周期细节影响。

其余 3 项：custom `settingsPath` 同步、ACL、Magpie 配置与其他 Tunnel 二进制哈希与无自启/固定二进制检查全部通过。

## 8. 完整性与兼容性

- Magpie `settings.json`、`providers.json` 的 SHA-256 与测试前一致。
- 另一本地 Tunnel 项目的 `cloudflared.exe` SHA-256 与测试前一致，其凭据目录文件清单未变；本项目未修改相邻项目。
- 项目 cloudflared SHA-256 仍为 `d5c1d82031da6253dcdcff64c944cd0fe063016edeb2e4fd088075fc9bd52d0a`。
- 没有 `MagpiePublicAPI` 计划任务，仍为纯手动启动 + 后台看门狗模式。
- `panel.ps1` 使用 UTF-8 BOM，Windows PowerShell 5.1 能正确解析中文；真实窗口及全部按钮已完成 UI Automation 点击验证。
- `proxy.js` 能读取带或不带 UTF-8 BOM 的 `config.json` / `settings.json`，覆盖 Windows PowerShell 写文件习惯。

## 9. 桌面快捷方式与 GUI 收官测试

桌面快捷方式：`%USERPROFILE%\Desktop\Magpie 公网 API 控制面板.lnk`。其目标为 Windows PowerShell，参数指向当前项目的 `panel.ps1`，工作目录和 Magpie 图标均已核对。

收官测试通过该快捷方式打开真实窗口，使用 Windows UI Automation 调用实际按钮，而非只检查进程或窗口标题：

1. 初始状态正确显示已停止；
2. 点击启动后看门狗、代理、Tunnel 真实启动，UI 显示公网侧就绪、等待 Magpie；
3. 点击刷新后状态仍准确；
4. 点击复制公网地址，剪贴板精确为 `https://apimagpie.example.com/v1`；
5. 点击日志，Explorer 打开 `D:\magpie-public\logs`，测试新建窗口已关闭；
6. 停止确认框点击“否”，三个后台组件保持运行；
7. 再次停止并点击“是”，后台组件归零且 UI 显示已停止；
8. 通过 WindowPattern 关闭面板，进程正常退出且不改变停止状态。

本轮 GUI 测试发现了一个此前仅验证窗口/端口时未覆盖的问题：Windows PowerShell 5.1 的 BackgroundWorker 回调未可靠完成，界面停留在“正在刷新…”。面板已改为直接在 UI 线程启动控制子进程，并用 WinForms Timer 非阻塞轮询 `HasExited`；不在后台线程运行 PowerShell ScriptBlock，也不在 UI 线程调用 `WaitForExit()`。修复后上述 8 项全部通过。

## 10. 测试证据位置

仓库外工作目录中的主要文件：

```text
verify_proxy.js                    proxy-test-results.json
verify_control.ps1                 control-test-results.json
verify_e2e.js                      e2e-test-results.json
lifecycle_common.ps1               *-lifecycle-results.json
panel-test-results.json
sync-test-results.json
acl-test-results.json
integrity-test-results.json
runtime-integrity-results.json
gui_click_test.ps1                 gui-click-test-results.json
verification-summary.json          去重后的 67 项通过汇总
```

测试工作目录（脱敏占位）：`C:\magpie-public-verification\work`。

最终状态已恢复到本轮开始前：公网侧连续执行两次 `stop.cmd` 均成功，`status` 为 `stopped`、退出码 1；本次测试启动的 Magpie launcher/gateway/plugin 进程树也已停止。最终 3425、8790、20242 均无监听。

测试过程本身不以“脚本退出 0”代替上述真实 HTTP、PID、端口、响应体和哈希断言。
