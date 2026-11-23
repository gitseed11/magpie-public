# 当前版本验证记录

日期：2026-11-24

对象：`D:\magpie-public` 当前工作树

环境：Windows、Node.js v24.18.0、Magpie 0.1.4720、cloudflared 2026.11.0、Windows PowerShell 5.1 / PowerShell 7。

> 本文只记录本轮实际执行的检查。2026-11-23 旧版本文档中的 67 项结果及其已丢失的外部测试资产没有被继承为本轮结论。

## 1. 总结

| 验证层 | 最终结果 | 说明 |
|---|---:|---|
| 仓库内 Node 隔离回归 | 16/16 | 临时目录、临时端口、mock 上游；含 55 MiB 精确边界，不接触真实服务 |
| 控制回归（Windows PowerShell 5.1） | 13/13 | 配置、ingress、生命周期 fixture、同步、IPv6 等 |
| 控制回归（PowerShell 7） | 13/13 | 同一套测试独立再跑 |
| 真实公网协议矩阵 | 30/30 组 | 四模型、三协议、多模态、思考、错误、长上下文、并发 |
| 55 MiB 更新后的公网复选 | 12/12 组 | 原 30 组的 40%，覆盖鉴权、三协议、SSE、多模态、错误、长上下文和并发 |
| 真实生命周期 | 5/5 组 | 代理恢复、Magpie 停复、公网停启、在途中断、restart JSON |
| IPv6 补充实测 | 2/2 | 两种 PowerShell 均完成真实 `[::1]` 配置、探针和鉴权请求 |
| 桌面 GUI 场景 | 8/8 | 6 个 Computer Use 场景 + 用户手动点击“否/是”，均核实结果 |
| 完整性与恢复 | 0 失败 | ACL、哈希、监听、同步、无自启、其他 Tunnel 项目隔离 |

以上数字按测试组计数，不把同一组内的每个 HTTP 请求或每条断言重复累计。独立子代理已分别复审代理、控制层和全部问题清单；其发现的问题修复后再次复审通过。

## 2. 原问题清单逐项处置

### 2.1 高/中优先级

| 原条目 | 处置 |
|---|---|
| 1. 缓存 Key 无失效上限 | 已修复：`lanKeyMaxStaleMs=300000`，过期 fail-closed；测试覆盖暂缺、到期、恢复和轮换。 |
| 2. 只校验第一条 ingress | 已修复：逐规则校验全部 forwarding service；额外封堵带引号键、flow mapping 等解析绕过。 |
| 3. stop 被配置校验阻断 | 已修复：stop 尽力读取配置，但无效配置不妨碍精确归属停止；返回 `configError`。 |
| 4. 路径拒绝在限流前刷日志 | 已修复：限流前移且不重复计数；日志字段截断、429 采样、抑制提示均有测试。 |
| 5. 意外 HTTP 状态反复重启 | 已修复：任何 HTTP 响应均为 Alive；只有不可达才重启，其他状态保持不就绪。 |
| 6. PID 写失败留下未受管子进程 | 已修复：写失败只警告，保留并继续监督内存中的 Process 对象。 |
| 7. cloudflared 重启式日志轮转 | 保留现有架构，文档明确会中断该 Tunnel 全部在途请求，包括 SSE；未伪称无损轮转。 |
| 8. Key 读取同步等待且无负缓存 | 已修复：移除 `Atomics.wait`，增加 2 秒失败负缓存和自动恢复。 |
| 9. 来源/路由头清理不全 | 已修复：补齐原列出的来源、URL/method 覆盖头和 `api-key` 清理；完整公网协议矩阵通过。 |
| 10. upstream path/query 被忽略 | 已修复：Node 与 PowerShell 均拒绝非根 path/query/userinfo/hash。 |
| 11. `?key=` 被转发 | 已修复：仅查询 Key 为 401，有效请求头附带 `key` 为 400；不转发、不写代理日志。 |
| 12. 单 Key 架构限制 | 保留设计并明确文档：无按客户端独立吊销/配额；loopback 免鉴权客户端不受轮换影响。 |

### 2.2 低优先级与工程完整性

- 413 竞态：增加迟到上游响应 guard；测试先发合法小块，再超限，并确认上游确实尝试迟到响应，代理 PID 不变。
- 编码冒号/分号路径：代理直接拒绝 `%3a`、`%3b`、字面分号和 `..;`；合法 Gemini 字面 action 仍通过。
- `::1` 前缀：改为精确匹配，不再把 `::10` 等当作 loopback。
- 超时 `unpipe`：已显式调用，并补慢速 chunked 上传超时测试。
- `restart -Json`：成功与失败路径均只输出一个 JSON；真实 restart 还验证 PID 变化和 `stopped` 字段。
- 外部端口冲突：无本目录组件但端口被外部占用时为 `degraded`，与 README 一致。
- 面板：补超时、异步输出完成检查、异常后按钮恢复、资源清理及关闭时 helper 结束。
- Node 路径：按 PATH、标准 Program Files、旧 D 盘路径回退。
- 手工相对路径归属：保留完整路径安全边界，文档明确不支持，未用 basename 放宽匹配以避免误杀。
- `sync-key.ps1`：清理陈旧副本，比较 Key/Endpoint/Source，原子替换；完全不变时保留 mtime。
- PEM/EOL：`.gitignore` 增加 `*.pem` 和 Key 临时文件；`panel.cmd` 统一 LF。
- 时间戳：supervisor 和 Key 同步改为 UTC ISO `Z`，与代理/cloudflared 一致。
- 探针：仅精确本机/no-CF/固定错误 Key/路径/UA 的探针不写逐次日志；第 21 次失败仍为 429，伪造公网 UA 无豁免。
- `Get-ExitCode`：当前代码原本已有空值兜底，未重复修改；新增 0、非零、空值、异常测试。
- cloudflared 哈希：每次 Tunnel 启动前自动核对 `bin/README.md` 的 SHA-256；文档未把它夸大为独立签名。
- 仓库测试：已加入 `tests/proxy.test.js` 和 `tests/control.test.ps1`。未为了形式新增 CI；真实公网、GUI 和破坏性生命周期证据仍放在仓库外。
- 文档：Tunnel delete 已单列为破坏性操作；证书备份使用 GUID 路径和 `finally`；查询 Key、缓存和轮转语义均已同步。

## 3. 本轮复查中新发现并修复的问题

1. **合法 YAML 形式绕过 ingress 校验**：带引号 `"service"` 和 flow mapping 曾被轻量解析器漏读。现改为每条规则必须恰好一个可识别 block-style service；flow collection、anchor/alias/merge key 等一律 fail-closed。子代理复测两种 PowerShell 均拒绝原绕过 fixture。
2. **`allowedRoutes` 顶层及字段校验弱于 Node**：现要求顶层为非空数组、path 以 `/` 开头、methods 为非空数组且每项全大写字符串，防止看门狗反复启动必然失败的配置。
3. **同步致命日志未经过轮转**：`logSync()` 现也调用大小轮转；通过真实 `EADDRINUSE` 子进程验证 FATAL 进入备份。
4. **Windows PowerShell 5.1 的 IPv6 TCP 探测失败**：`TcpClient` 对 `::1` 显式使用 `InterNetworkV6`；双运行时真实 IPv6 请求均恢复通过。

## 4. 静态检查与隔离回归

- `node --check proxy.js`、`node --check tests/proxy.test.js`：通过。
- 所有项目及测试 PowerShell 脚本在 5.1/7.7 下均为 0 解析错误。
- `cloudflared tunnel --config config.yml ingress validate`：`OK`。
- `git diff --check`：通过；全部 tracked 文件为 `w/lf`，不再有 mixed EOL。
- Node 16 组覆盖：鉴权、路由、请求/响应头、查询 Key、Key 陈旧/恢复、upstream 配置、限流/日志、编码路径、413、55 MiB 精确通过与 +1 拒绝、SSE、慢上传超时、上游停复、探针节流、普通及 FATAL 日志轮转。
- PowerShell 13 组覆盖：全部 ingress 规则与不支持 YAML、upstream/route 校验、Node 查找、HTTP 健康语义、IPv6、外部端口、无效配置 stop、单 JSON restart、PID 写失败、哈希、Key 同步、退出码。

复现命令：

```cmd
node --test tests/proxy.test.js
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/control.test.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File tests/control.test.ps1
```

## 5. 55 MiB 请求体更新复验

- `config.json.maxBodyBytes=57671680`，与 `proxy.js` 缺省回退表达式 `55 * 1024 * 1024` 一致；README 和部署样例均为同一数值。
- 隔离 mock 实测恰好 55 MiB 的请求完整到达上游并返回 200；声明长度为 55 MiB + 1 时返回 413，上游请求数不增加。原有小阈值 chunked/迟到响应测试继续保留，用于确定性覆盖流式分支。
- 真实公网复选原 30 组中的 12 组（40%），覆盖 loopback/鉴权、管理面、OpenAI、Anthropic、Gemini、SSE、多模态、错误透传、长上下文和 11 路并发，最终 12/12 通过；并发复测耗时 4.780 秒。
- 管理面复选首次出现一次 `ECONNRESET`，原始失败保存在 `body-selected-04-initial-failure.json`；该组及后续组重跑成功，未将首次异常改写成成功。
- 未新增并发数限制，也未把现有每窗口速率限制误当成并发上限。

## 6. 真实公网矩阵（30 组）

| 分组 | 实测 |
|---|---|
| 本机 loopback 与鉴权 | 3425 无 Key 200；代理/公网无 Key、错 Key、仅查询 Key 均 401；有效头附查询 Key 为 400。 |
| 三种鉴权头 | Bearer、`x-api-key`、`x-goog-api-key` 均 200。 |
| 模型列表一致性 | 3425、8790、公网及三种头的响应体 SHA-256 均为 `c02e751cc1c5482b26de13f31476d4c704e21ebaf7674e6d6c3fd512211747f3`。 |
| 管理面/文件/方法 | 10 个管理或敏感路径及 5 个不允许的方法/action 全部 404。 |
| OpenAI | 四模型 chat、responses 均 200/PONG；SSE 分块到达。 |
| Anthropic | messages、`?beta=true`、SSE、count_tokens 全部通过。 |
| Gemini | generateContent、streamGenerateContent SSE、countTokens 全部通过。 |
| 思考参数 | OpenAI low/high、Anthropic budget 1024、Gemini budget 0/1024 均返回 391。 |
| 多模态 | 三协议均正确识别 64×64 PNG 的左红右蓝。 |
| 错误透传 | 未知模型 404；截断 JSON 与非对象 JSON 分别为 400，保留上游错误结构。 |
| 长上下文 | 四组 180,229 字符载荷均返回完整标记；绿色图片同时识别正确。 |
| 并发 | 11 路混合调用逐路全部 200，最终通过耗时 5.312 秒。 |

长上下文实际 usage（当前 Magpie/模型分词结果，不沿用旧版本 token 数）：

| 调用 | 输入 token | 结果 |
|---|---:|---|
| OpenAI workbuddy，reasoning high | 22,595 | 200，完整标记 |
| Anthropic kimi，thinking 1024 | 22,643 | 200，完整标记 |
| Gemini trae，thinkingBudget 0 | 22,589 | 200，完整标记 |
| OpenAI highspeed + 绿色图片 | 22,645 | 200，标记和绿色均正确 |

## 7. 真实生命周期（5 组）

| 场景 | 实测 |
|---|---|
| 结束所属代理 | 看门狗拉起新代理；看门狗和 Tunnel PID 不变，Magpie 不受影响。 |
| 停止/恢复 Magpie | 公网带正确 Key 为 502；恢复后 200，代理 PID 不变。 |
| 公网停止/启动 | 所属三组件全停，Magpie 继续运行；公网停止时 Cloudflare 502，重启后 200。 |
| 在途 SSE 停止 | 已收到首块后停止，客户端未完成推理；下一次启动恢复 200。 |
| 真实 restart JSON | 单个 JSON、`success=true`、`state=ready`、3 个所属进程被停止后重起，代理 PID 改变。 |

生命周期脚本最后总是进入恢复逻辑。restart 第一次测试的失败来自验证脚本误读 `data.proxy` 而非 `data.status.proxy`；修正后单独重跑通过，原始与重跑 JSON 均保留。

## 8. IPv6 补充实测

Windows PowerShell 5.1 与 PowerShell 7 分别完成：

- `listenHost='::1'`、upstream `http://[::1]:<port>`、ingress service `[::1]` 的解析和精确绑定；
- 状态地址显示为 `[::1]:<port>`；
- 错误 Key 健康探针为 401/ready；
- 正确 Key 经真实 `[::1]` 代理请求返回 200。

PowerShell 5.1 初次因默认 IPv4 `TcpClient` 失败，修复后两种运行时均通过；证据为 `ipv6-ps5-results.json`、`ipv6-ps7-results.json`。

## 9. 桌面 GUI（8 个场景）

1. 临时从现有快捷方式恢复到旧 Desktop 路径，打开面板初始为 stopped，未自动启动服务。
2. 点击启动后三组件真实运行，UI 显示已就绪。
3. 点击刷新后按钮恢复且状态保持已就绪。
4. 点击复制公网地址，剪贴板精确为 `https://apimagpie.example.com/v1`；随后恢复原剪贴板。
5. 点击日志打开项目 logs 的新 Explorer 窗口；只关闭该测试窗口。
6. 停止确认点击“否”后，看门狗、代理、Tunnel、Magpie 全部保持运行。
7. 再停止并点击“是”后，仅公网三组件停止，Magpie 3425 保持监听。
8. 关闭面板后进程退出，无控制 helper 残留，8790/20242 无监听，服务保持 stopped。

启动、刷新、复制、日志和关闭按钮使用 Computer Use accessibility 操作。确认框弹出时 Computer Use 权限代理反复失去连接，因此“否/是”由用户手动点击；随后均通过 `control.ps1`、进程、HTTP 和监听独立核实，未把它们宣称为自动化点击。临时 Desktop 快捷方式已删除，原位置的快捷方式保留。

## 10. 完整性、纠错和最终状态

- 11 个代码/配置/Key/凭据文件的 ACL 仅含当前用户、SYSTEM、Administrators。
- Magpie `settings.json`、`providers.json` 的 SHA-256 与基线一致；本项目与其他 Tunnel 项目的 cloudflared 哈希均为 `d5c1d82031da6253dcdcff64c944cd0fe063016edeb2e4fd088075fc9bd52d0a`。
- 其他 Tunnel 项目 `data\tunnel` 两个原文件的哈希未变；没有 `MagpiePublicAPI` 计划任务。
- 初次公网冒烟曾出现一次 30 秒网络超时；随后 direct/proxy/public 均 200。完整矩阵中的并发初次 `ECONNRESET` 和一次连接超时也保留原始证据，逐路重跑 11/11 通过，未改写首次日志。
- 错误透传测试已区分“截断 JSON”与“非对象 JSON”；长上下文标记已与填充字母分隔。以上是测试载荷纠错，不是隐藏产品失败。
- 最终恢复为基线状态：**Magpie 运行、公网侧停止**。只有 `127.0.0.1:3425` 监听，8790/20242 无监听，项目所属进程为 0；Magpie PID 可因生命周期测试而变化。
- 原剪贴板、临时快捷方式、临时 fixture 和测试子进程均已恢复或清理。

## 11. 证据位置

仓库内：`tests/proxy.test.js`、`tests/control.test.ps1`。

本轮仓库外工作目录：

```text
C:\magpie-public-verification\work
```

主要证据：

```text
verification-summary.json       baseline.json
restored-state.json             e2e-results.json
e2e-final-results.json           body-limit-public-results.json
body-selected-04-initial-failure.json
e2e-error-retry.json            e2e-long-retry.json
e2e-concurrency-detailed.json   lifecycle-results.json
lifecycle-restart-retry.json    stream-result.json
integrity-restored-results.json gui-results.json
ipv6-ps5-results.json           ipv6-ps7-results.json
```

`verify-e2e.js`、`verify-lifecycle.ps1`、`verify-integrity.ps1`、`verify-ipv6.ps1` 及 GUI 辅助脚本也保存在该目录。结果不包含 API Key、Tunnel JSON 或证书内容；原始失败与定向重跑文件均保留，便于复核。
