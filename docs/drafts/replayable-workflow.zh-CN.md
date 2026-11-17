# 可回放的工作流：把 IRIS 消息链路和 Agent 推理链放进同一条时间线

**PaymentGuard 的仪表盘如何逐跳还原一次 AI 决策，以及如何把同样的视图加到另一个 IRIS 生产里。**

在线演示：[http://43.139.159.100:8082/paymentguard/](http://43.139.159.100:8082/paymentguard/)　源码：[github.com/Dylan5237/payment-guard-ai](https://github.com/Dylan5237/payment-guard-ai)　上一篇：[PaymentGuard AI：让 AI Hub Agent 在 IRIS 互操作生产里管支付风控](https://cn.community.intersystems.com/post/paymentguard-ai%EF%BC%9A%E8%AE%A9-ai-hub-agent-%E5%9C%A8-iris-%E4%BA%92%E6%93%8D%E4%BD%9C%E7%94%9F%E4%BA%A7%E9%87%8C%E7%AE%A1%E6%94%AF%E4%BB%98%E9%A3%8E%E6%8E%A7)

**以下是正文：**

---

## 问题：决策很快，过程是黑盒

Agent 两秒内就能给出支付决策。真正难回答的是这两秒里发生了什么。

生产里走了哪些消息？Agent 看到了什么上下文？调了哪些工具、拿回了什么？最后一步是谁批的？模型花了多少 token？

对于一笔可能拦掉客户支付、也可能放过欺诈的决策，"模型说可以"不构成审计记录。PaymentGuard 的仪表盘用一个回放面板回答这些问题：选中一笔决策，真实的生产链路按毫秒逐跳播放；下方再展开 Agent 的推理链，一条消息一条消息地看。

面板里没有编造的内容。每一跳都是 `Ens.MessageHeader` 的一行，每一步推理都来自持久化的 `%AI.Agent.Session`。仪表盘只是把 IRIS 已经记录的数据拼成一个视图。

这篇文章讲它是怎么实现的，包括最花时间的几个细节，最后给一份可以套用到其他 IRIS 生产上的清单。

![PaymentGuard AI 的 Flow 回放面板：任务队列、按生产拓扑逐跳回放的真实 Ens.MessageHeader 链路（含 Human Review 工作流节点），以及 Agent 推理链](docs/flow-panel.png)

## 回放需要三层证据

要把一次决策讲清楚，需要三份互相独立的记录：

| 回答的问题 | 数据来源 | 接口 |
|---|---|---|
| 走了哪些消息？ | `Ens.MessageHeader` | `GET /api/trace` |
| Agent 看了什么、做了什么？ | `%AI.Agent.Session` | `GET /api/reasoning` |
| 这笔决策花了多少？ | 决策审计表 | `GET /api/decisions` |
| 某个节点上到底流过了什么？ | 消息体类名 + id | `GET /api/messages` |

完整的消息链路仍然以管理门户的 Message Viewer 为准。仪表盘只负责把这几份数据拼到同一条时间线上，再通过深链接回到 Message Viewer 看原始记录。

## 整体结构

整个栈分三部分：

- **静态仪表盘**（HTML/CSS/JS），由 Apache 直接从仓库的 `web/` 目录提供。没有构建步骤，不用 npm，也不用打包器。
- **IRIS REST 应用**（`/api`），实现为一个 `%CSP.REST` 调度类。
- **Web Gateway Sidecar 容器**，因为 2026.3 AI Hub 早期访问构建是 NoPWS：52773 的私有 Web 服务器被关闭了。

仪表盘定期轮询 REST API，取统计数据、决策、案例和待审任务；回放面板在需要时调用链路接口。页面是纯静态文件，评审不需要任何工具链就能打开；真正的产品仍然是 API。

## 第一层：消息跳转

每一条互操作消息都是 `Ens.MessageHeader` 里的一行。链路接口是一个很窄的查询：

```objectscript
ClassMethod Trace() As %Status
{
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare(
        "SELECT TOP ? ID, SessionId, SourceConfigName, TargetConfigName, "_
        "TimeCreated, MessageBodyClassName "_
        "FROM Ens.MessageHeader ORDER BY ID DESC")
    If $$$ISERR(tSC) Quit ..WriteError(500, $System.Status.GetErrorText(tSC))

    Set tRS = tStmt.%Execute(200)
    Set arr = []
    While tRS.%Next() {
        Set row = {}
        Do row.%Set("id",      tRS.%Get("ID"))
        Do row.%Set("session", tRS.%Get("SessionId"))
        Do row.%Set("source",  tRS.%Get("SourceConfigName"))
        Do row.%Set("target",  tRS.%Get("TargetConfigName"))
        Do row.%Set("time",    tRS.%Get("TimeCreated"))
        Do row.%Set("body",    tRS.%Get("MessageBodyClassName"))
        Do arr.%Push(row)
    }

    Quit ..WriteJSON({"now": ($ZDATETIME($HOROLOG, 3, 1)), "hops": (arr)})
}
```

有两个细节要注意。

第一，这个构建里的列名是 **`TimeCreated`**，不是 `TimeEntered`。从旧文档抄来的查询会失败，或者按错误的顺序返回。

第二，返回值里带上了**服务端当前时间**。浏览器和容器的时钟很少一致——容器通常跑在 UTC——前端用这个 `now` 把所有时间戳换算到同一根轴上。没有它，浏览器里点击请求的时间和 IRIS 里记录的消息时间可能差好几分钟。

## 第二层：Agent 的推理链

Agent 操作组件在返回之前会把 AI Hub 会话持久化。就是这一次保存，让回放成为可能：

```objectscript
Set agent   = ##class(PaymentGuard.Agent.RiskAgent).%New()
Set tSC     = agent.%Init()
Set session = agent.CreateSession({"max_iterations": 3})
Set llmResponse = agent.Chat(session, chatMsg)

// 保存会话，之后任何一笔决策都可以回放
Try { Do session.%Save() } Catch ex { }

Set stats = session.GetStats()
Set pResponse.RawContent       = llmResponse.Content
Set pResponse.Model            = agent.Model
Set pResponse.SessionId        = session.%Id()
Set pResponse.PromptTokens     = stats."total_prompt_tokens"
Set pResponse.CompletionTokens = stats."total_completion_tokens"
Set pResponse.ToolCalls        = stats."total_tool_calls"
```

推理链接口打开这个会话，读取 `ContextData`。它是一个流，里面是 Agent 工作时完整的消息链：

```objectscript
Set sess = ##class(%AI.Agent.Session).%OpenId(sid)
If '$IsObject(sess) Quit ..WriteError(404, "session not found: "_sid)

Set st = sess.ContextData
Do st.Rewind()
Set txt = ""
While 'st.AtEnd { Set txt = txt_st.Read(60000) }

Set o     = ##class(%DynamicObject).%FromJSON(txt)
Set raw   = o.%Get("messages")
For i = 0:1:raw.%Size() - 1 {
    Set m = raw.%Get(i)
    Do msgs.%Push({"role": (m.%Get("role")), "content": (m.%Get("content"))})
}
```

拿到的就是真实顺序：带着风险上下文的用户消息、每一次 assistant 工具调用、每一个工具结果、最后的 JSON 回答。仪表盘把这条链渲染在回放下方，跳过 system 提示词，过长的消息先折叠，点击再展开。

这里有一个容易混的命名问题：**有两个不同的 session id**。

- `/api/trace` 和 `/api/messages` 用的是 `Ens.MessageHeader.SessionId`，也就是生产会话。
- `/api/reasoning` 用的是 `%AI.Agent.Session` 的 id。

两者没有关系，不能互相替代。仪表盘的任务对象同时保存了两者：生产会话取自第一跳，AI 会话取自决策响应。

## 第三层：消息体

要回答"这个节点上到底流过了什么"，消息体接口按类名和 id 打开每一跳的消息：

```objectscript
Set body = $CLASSMETHOD(cls, "%OpenId", bodyId)
Set bodyJSON = ""
If $IsObject(body) {
    // 这个构建里 %IsA("%JSON.Adaptor") 对 Adaptor 子类也返回假
    // 所以直接导出，用 Catch 兜住
    Set bodySC = body.%JSONExportToString(.bodyJSON)
    If $$$ISERR(bodySC) Set bodyJSON = "{""note"":""body not serializable""}"
} Else {
    Set bodyJSON = "{""note"":""body no longer available (purged)""}"
}
```

三点需要注意：

- 这个构建里，对这些消息类调用 `body.%ToJSON()` 会返回空串，真正可用的是 `body.%JSONExportToString(.json)`。
- `%IsA("%JSON.Adaptor")` 对继承 `%JSON.Adaptor` 的类也返回假，不能拿它判断能力；放进 `Try/Catch` 里直接导出，失败时给出说明。
- 消息体可能被清理。取不到时返回一条说明，不要让整个回放因为一个 500 中断。

![AI Risk Agent 节点的消息体：发给 Agent 的风险上下文 JSON，与带 token、延迟、会话 id 返回的决策 JSON](docs/agent-messages.png)

## 怎么捕获刚刚发生的那一次请求

浏览器在请求返回之前并不知道生产会话。它也无法直接查询"这次请求的链路"，因为请求和链路是在不同时间写入的。

仪表盘用时间窗口来对齐：

```javascript
const r   = await (await fetch(API + "/trace?limit=300")).json();
const off = srvMs(r.now) - Date.now();          // 服务端时钟 - 浏览器时钟
const hops = r.hops.slice().reverse();
const win  = hops.filter(h => {
  const m = srvMs(h.time);
  return m >= t.t0 + off - 400 && m <= t.t0 + off + 4500;
});
const starts = win.filter(h =>
  h.source === "PaymentGuard REST" && h.target === "PaymentGuard Decision");
const sid = starts[starts.length - 1].session;
t.hops = hops.filter(h => h.session === sid);
```

步骤是：

1. 取最近 300 条消息头。
2. 计算服务端与浏览器的时钟差。
3. 保留从点击前 400 毫秒到点击后 4.5 秒之间的跳（批量演示放宽到 9 秒）。
4. 找到从 `PaymentGuard REST` 发往 `PaymentGuard Decision` 的第一跳，用它确定这次请求的会话。
5. 只保留属于这些会话的跳。

决策详情弹窗走的是另一个接口 `/api/trace/txn`，因为它从交易 id 出发，而不是从一次点击出发。它扫描一个很窄的时间窗（决策时间前 15 分钟到后 2 分钟），打开候选消息体，收集 `TxnId` 匹配的会话。

## 前端怎么回放

前端把生产配置名映射到界面节点，只做一次：

```javascript
const NODE_OF = {
  "PaymentGuard REST":          "rest",
  "PaymentGuard Decision":      "bp",
  "PaymentGuard AI Risk Agent": "agent",
  "PaymentGuard Settlement":    "settle",
  "PaymentGuard Review Queue":  "review",
  "PaymentGuard Human Review":  "human",
  "PaymentGuard Fraud Alerts":  "alert"
};
const EDGE_FROM = {
  "bp-rest": "rest", "agent-bp": "bp", "bp-rules": "bp",
  "bp-settle": "bp", "bp-review": "bp", "bp-human": "bp", "alert-bp": "bp"
};
```

边的 key 是两个节点名排序后拼起来的，所以 `bp-rest` 和 `rest-bp` 是同一条边；`EDGE_FROM` 告诉动画哪一端是自然起点。

回放不用固定的动画时长，而是使用跳与跳之间的真实间隔，并限制在 90–380 毫秒：

```javascript
let acc = 40, prev = times[0];
t.hops.forEach((h, i) => {
  const real = Math.max(0, times[i] - prev); prev = times[i];
  acc += Math.min(Math.max(real, 90), 380);
  setTimeout(() => playHop(h, real), acc);
});
```

这个限制是有意的：3 毫秒的规则决策也能看清，2 秒的模型调用也不会让人盯着静止的图。边上显示的数字是真实耗时，压缩的只是播放速度。

每一跳用三次缓出的方式，让一个光点沿着 SVG 路径移动：

```javascript
const len = path.getTotalLength(), st = performance.now(), dur = 300;
const fr = t => {
  const p = Math.min(1, (t - st) / dur);
  const e = 1 - Math.pow(1 - p, 3);
  const pt = path.getPointAtLength((reverse ? 1 - e : e) * len);
  dot.setAttribute("cx", pt.x);
  dot.setAttribute("cy", pt.y);
  if (p < 1) requestAnimationFrame(fr);
};
requestAnimationFrame(fr);
```

消息方向与边的自然方向相反时，光点反向移动；起点和终点节点会亮起，边的中间淡出一个毫秒数。最后一跳落地后，结果节点按判定染色——APPROVE 绿色、REVIEW 琥珀色、BLOCK 红色——摘要行给出总跳数、总耗时，以及其中 Agent 推理占了多久。

点击节点会从时间线切换到内容。仪表盘最多取 8 个会话的 `/api/messages`，把所有跳拉平，过滤出源或目标是该节点的消息，再逐条渲染成卡片。Rule Engine 单独处理：它在 Decision BP 进程内运行，没有独立的消息跳，面板会直接说明，而不是显示一个空列表。

回放面板最后深链到管理门户：

```
EnsPortal.MessageViewer.zen?SESSIONID=<生产会话>
```

这个链接是有意留的。仪表盘是摘要，Message Viewer 才是完整记录。

![决策详情弹窗：上方是这笔交易的真实消息链路回放，下方是向量相似交易表](docs/decision-detail.png)

## 人工终审也在同一条链上

REVIEW 判定会创建一条原生 Workflow 引擎任务。对回放来说，真正有意思的是分析师裁决之后发生的事。

接口先用 `AssignTask` 领取任务，用 `CompleteTask` 完成，然后显式保存：

```objectscript
Set tSC = t.AssignTask(reviewer, .cnt)
Set tSC = t.CompleteTask(action)

// 这个构建的 Workflow 引擎只改内存里的状态，靠延迟响应投递来落库；
// CSP 工作进程里不会发生这一步。不保存的话任务一直挂在工作列表里，
// 还可能被裁决两次。
Set tSC = t.%Save()
```

这个显式 `%Save()` 是必须的。少了它，任务会一直显示未完成，并且可以被重复裁决。

之后，接口向生产的终审业务流程推一条 `ReviewFinalization` 消息。这是一个有意的设计。这个构建里 Workflow 引擎不会回调裸的 `OnRequest` 业务流程，所谓"自动唤醒"在链路里根本看不到。改成显式消息之后，终审就是真实的两跳：REST → Finalizer → 结算或欺诈告警。人的决定出现在同一条回放里，审计记录里带着审核人姓名。

## NoPWS 构建里的接入细节

2026.3 AI Hub 早期访问镜像把私有 Web 服务器整个关掉了。所以栈里跑一个标准的 Web Gateway Sidecar 容器。三个细节决定了它能不能用：

- **凭据写在 `CSP.ini` 里。** 这个网关构建不认常见的 `ISC_CSP_IRIS_*` 环境变量。`[LOCAL]` 段需要 `Username=CSPSystem` / `Password=SYS`；EAP 镜像又不再创建 `CSPSystem` 用户，所以安装脚本负责建用户并启用 `%Service_WebGateway`。
- **Apache 按扩展名派发。** `CSPFileTypes` 必须包含你要提供的扩展名，不带扩展名的 REST URL 根本到不了 IRIS。栈内把这些地址重写到一一对应的 `.csp` 路由（mod_rewrite 加双份 `UrlMap`），`POST /payments` 这样的地址才能原样使用。
- **匿名演示需要授权。** 把 Web 应用的角色授给 `UnknownUser`，否则每个请求还没到调度类就以 `<PROTECT>`/403 失败。

仪表盘本身是静态文件，由 Apache 从挂载的 `web/` 目录提供，不经过 IRIS 的 Web 服务器。

## 复用清单

如果要在另一个 IRIS 生产上做同样的回放：

1. 在 `Ens.MessageHeader` 上做一个很薄的 `/trace` 接口（ID、会话、源、目标、时间、消息体类名），并返回服务端时间。
2. 每笔决策落库时保存 AI 会话 id、模型、token 数、工具调用数和延迟。
3. 加 `/reasoning`，打开 `%AI.Agent.Session`，返回 `ContextData` 里的消息。
4. 加 `/messages`，按类名和 id 打开消息体，导出时做好失败处理。
5. 消息体类要能被 JSON 导出；把导出当成尽力而为，不要假设一定成功。
6. 配置名到界面节点的映射只做一次，不要在每个渲染路径里重复。
7. 原始记录优先深链到 Message Viewer。
8. 按生产实际的消息保留窗口做测试。

## 结语

这套回放不是演示效果。它改变的是工作流的调试和评审方式：

- 一次错误决策，可以直接追到 Agent 看到的上下文，以及误导它的那个工具结果。
- 延迟能按跳归因，而不只是一个端到端数字。
- token 成本挂在决策上，而不是月底的一张账单。
- 人工批准是链路上可见的一环，有姓名，有时间。

一个会动钱的 Agent，应该能把自己的工作过程摊开。在 IRIS 里，大部分证据本来就已经存在；要做的是把它拼到同一条时间线上。

---

在线上演示里试回放：[43.139.159.100:8082/paymentguard](http://43.139.159.100:8082/paymentguard/)　源码：[github.com/Dylan5237/payment-guard-ai](https://github.com/Dylan5237/payment-guard-ai)

如果这个思路对你有用，欢迎在 [Open Exchange 上给 PaymentGuard AI 投一票](https://openexchange.intersystems.com/contest/49)——在列表里找到 **PaymentGuard AI** 点 Vote 即可。谢谢。
