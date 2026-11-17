# Building a replayable workflow: IRIS message traces and AI agent sessions on one timeline

**How PaymentGuard's dashboard reconstructs an AI decision hop by hop — and how to add the same view to another IRIS production.**

Live demo: [http://43.139.159.100:8082/paymentguard/](http://43.139.159.100:8082/paymentguard/) · Source: [github.com/Dylan5237/payment-guard-ai](https://github.com/Dylan5237/payment-guard-ai) · Previous article: [PaymentGuard AI: an AI Hub Agent as the Fraud Decision-Maker Inside an IRIS Interoperability Production](https://community.intersystems.com/post/paymentguard-ai-ai-hub-agent-fraud-decision-maker-inside-iris-interoperability-production)

## The black-box problem

An AI agent can return a payment decision in under two seconds. The hard question is what happened inside those two seconds.

Which messages moved through the production? What context did the agent see? Which tools did it call, and what came back? Who approved the final step, and how much did the model cost?

For a workflow that can block a payment or let fraud through, "the model said so" is not an audit trail. PaymentGuard's dashboard answers those questions with a replay panel: pick a decision, and the real production path plays back hop by hop with real millisecond timings. Underneath, the agent's reasoning chain unfolds message by message.

Nothing in that panel is synthesized. Each hop is an `Ens.MessageHeader` row. Each reasoning step is a persisted `%AI.Agent.Session`. The dashboard is a presentation layer over data IRIS already records.

This article describes how it works, including the parts that took the longest to get right, and ends with a checklist for adding replay to any interoperability production.

![PaymentGuard AI Flow panel: task queue, the real Ens.MessageHeader trace replayed hop by hop over the production topology — including the Human Review workflow node — and the agent reasoning chain](docs/flow-panel.png)

## Three layers of evidence

Replay needs three independent records:

| Question | Source | Endpoint |
|---|---|---|
| Which messages moved? | `Ens.MessageHeader` | `GET /api/trace` |
| What did the agent see and do? | `%AI.Agent.Session` | `GET /api/reasoning` |
| What did the decision cost? | decision audit table | `GET /api/decisions` |
| What exactly flowed through a node? | message body class + id | `GET /api/messages` |

The Management Portal's Message Viewer remains the source of truth for the full message trace. The dashboard is a convenience layer that joins these sources into one timeline and deep-links to the viewer for the raw record.

## The shape of the stack

There are three pieces:

- A static dashboard (HTML/CSS/JS) served by Apache from the repository's `web/` directory. No build step, no npm, no bundler.
- An IRIS REST application (`/api`) implemented as a `%CSP.REST` dispatch class.
- A Web Gateway sidecar, because the 2026.3 AI Hub early-access build is NoPWS: the private web server on port 52773 is disabled.

The dashboard polls the REST API for stats, decisions, cases and reviews. The replay panel calls the trace endpoints on demand. Because the page is plain static files, a reviewer can open it with no toolchain — and the API remains the real product.

## Layer 1: the hops

Every interoperability message is a row in `Ens.MessageHeader`. The trace endpoint is a narrow query:

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

Two details matter.

First, this build's column is **`TimeCreated`**, not `TimeEntered`. A query copied from older documentation will fail or silently return the wrong ordering.

Second, the response includes the **server's current time**. The browser and the container rarely share a clock — the container usually runs in UTC — so the front end uses that `now` to convert all timestamps onto the same axis. Without it, a request triggered in the browser and a hop recorded in IRIS can appear minutes apart.

## Layer 2: the agent's reasoning

The agent operation persists its AI Hub session before returning. That single save is what makes replay possible:

```objectscript
Set agent   = ##class(PaymentGuard.Agent.RiskAgent).%New()
Set tSC     = agent.%Init()
Set session = agent.CreateSession({"max_iterations": 3})
Set llmResponse = agent.Chat(session, chatMsg)

// Persist the session so any decision can be replayed later
Try { Do session.%Save() } Catch ex { }

Set stats = session.GetStats()
Set pResponse.RawContent       = llmResponse.Content
Set pResponse.Model            = agent.Model
Set pResponse.SessionId        = session.%Id()
Set pResponse.PromptTokens     = stats."total_prompt_tokens"
Set pResponse.CompletionTokens = stats."total_completion_tokens"
Set pResponse.ToolCalls        = stats."total_tool_calls"
```

The reasoning endpoint opens that session and reads `ContextData`, a stream containing the full message chain the agent worked with:

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

The result is the real sequence: the user message carrying the risk context, each assistant tool call, each tool result, and the final JSON answer. The dashboard renders that chain under the replay, skips the system prompt, and collapses long messages until clicked.

One naming trap: there are **two different "session" identifiers**.

- `/api/trace` and `/api/messages` use `Ens.MessageHeader.SessionId`, the production session.
- `/api/reasoning` uses the `%AI.Agent.Session` id.

They are unrelated numbers and cannot be substituted for each other. The dashboard's task object carries both: the production session comes from the first hop, the AI session comes from the decision response.

## Layer 3: the message bodies

For "what exactly flowed through this node", the messages endpoint opens each body by class name and id:

```objectscript
Set body = $CLASSMETHOD(cls, "%OpenId", bodyId)
Set bodyJSON = ""
If $IsObject(body) {
    // %IsA("%JSON.Adaptor") is false in this build even for Adaptor
    // subclasses — export and let the Catch handle the rest
    Set bodySC = body.%JSONExportToString(.bodyJSON)
    If $$$ISERR(bodySC) Set bodyJSON = "{""note"":""body not serializable""}"
} Else {
    Set bodyJSON = "{""note"":""body no longer available (purged)""}"
}
```

Three things to know:

- `body.%ToJSON()` returns an empty string in this build for these message classes. `body.%JSONExportToString(.json)` is what works.
- `%IsA("%JSON.Adaptor")` returns false even for classes that inherit `%JSON.Adaptor`. Do not use it as a capability test; export inside `Try/Catch` and let the error path produce a note.
- Message bodies can be purged. A missing body should produce a note, not a 500 that breaks the whole replay.

![Message bodies at the AI Risk Agent node: the risk context JSON shipped to the agent, and the decision JSON coming back with tokens, latency and session id](docs/agent-messages.png)

## Capturing the request that just happened

The browser does not know the production session until the request returns. It also cannot ask for "the trace of this request" directly, because the request and the trace are written at different times.

The dashboard handles this by timestamp windowing:

```javascript
const r   = await (await fetch(API + "/trace?limit=300")).json();
const off = srvMs(r.now) - Date.now();          // server clock - browser clock
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

The steps:

1. Fetch the most recent 300 headers.
2. Compute the offset between server time and browser time.
3. Keep hops inside a window from 400 ms before the click to 4.5 s after it (9 s for a burst).
4. Find the hops that start at `PaymentGuard REST -> PaymentGuard Decision`, which identify the sessions for this request.
5. Keep only the hops belonging to those sessions.

The decision detail modal uses a different route, `/api/trace/txn`, because it starts from a transaction id rather than a click. It scans a narrow time window (15 minutes before to 2 minutes after the decision timestamp), opens the candidate bodies, and collects the sessions whose `TxnId` matches.

## Playing it back

The front end maps production config names to UI nodes once:

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

An edge key is the two node names sorted, so `bp-rest` and `rest-bp` are the same edge. `EDGE_FROM` tells the animation which end is the natural start.

The replay does not use a fixed animation duration. It uses the real gaps between hops, clamped to 90–380 ms:

```javascript
let acc = 40, prev = times[0];
t.hops.forEach((h, i) => {
  const real = Math.max(0, times[i] - prev); prev = times[i];
  acc += Math.min(Math.max(real, 90), 380);
  setTimeout(() => playHop(h, real), acc);
});
```

That clamp is a deliberate compromise: a rule decision that took 3 ms still gets a visible beat, while a 2-second LLM call does not leave the viewer staring at a frozen diagram. The number printed on the edge is the real duration; only the playback speed is compressed.

Each hop animates a dot along the SVG path with a cubic ease-out:

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

The dot reverses direction when the message travels against the edge's natural direction, lights the source and target nodes, and fades a millisecond label at the midpoint. When the last hop lands, the outcome node takes the verdict color — green for APPROVE, amber for REVIEW, red for BLOCK — and the summary line reports total hops, total time, and how much of it was agent reasoning.

Clicking a node switches from timeline to content. The dashboard fetches `/api/messages` for up to eight sessions, flattens the hops, filters to those whose source or target is the selected node, and renders each message body as a card. The Rule Engine is special-cased: it runs in-process inside the Decision BP, so there is no separate message hop, and the panel says so instead of showing an empty list.

Finally, the panel deep-links to the Management Portal:

```
EnsPortal.MessageViewer.zen?SESSIONID=<production session>
```

That link is intentional. The dashboard is a summary; the viewer is the complete record.

![Decision detail dialog: the transaction's Flow replay over the production topology and its vector-similar transactions](docs/decision-detail.png)

## Human review is in the same trace

A REVIEW decision opens a native Workflow Engine task. The interesting part for replay is what happens after the analyst decides.

The endpoint claims the task with `AssignTask`, completes it with `CompleteTask`, and then saves it explicitly:

```objectscript
Set tSC = t.AssignTask(reviewer, .cnt)
Set tSC = t.CompleteTask(action)

// This build's Workflow Engine only mutates the in-memory status and relies
// on deferred-response delivery to save it, which does not happen from a CSP
// worker process. Without this the task stays open and can be decided twice.
Set tSC = t.%Save()
```

That explicit `%Save()` is required. Without it, the task stays open in the worklist and can be decided twice.

Then the endpoint pushes a `ReviewFinalization` message into the production's finalizer business process. This is a deliberate design choice. In this build, the Workflow Engine does not call back into a bare `OnRequest` business process, so a "magic wake-up" would be invisible in the trace. Instead, finalization is an explicit message: REST → Finalizer → Settlement or Fraud Alert. The human decision appears as real hops in the same replay, with the reviewer's name in the audit record.

## Serving it from a NoPWS build

The 2026.3 AI Hub early-access image disables the private web server entirely. The stack therefore runs a standard Web Gateway sidecar. Three details make it work:

- **Credentials live in `CSP.ini`.** This gateway build ignores the usual `ISC_CSP_IRIS_*` environment variables. The `[LOCAL]` section needs `Username=CSPSystem` / `Password=SYS`, and the EAP image no longer creates the `CSPSystem` user, so the installer creates it and enables `%Service_WebGateway`.
- **Apache dispatches by file extension.** `CSPFileTypes` must include the extensions you serve, and an extensionless REST URL never reaches IRIS. The stack rewrites extensionless routes to `.csp` twins (mod_rewrite plus a doubled `UrlMap`), so `POST /payments` works unchanged.
- **Anonymous demo access needs roles.** Grant the web application's roles to `UnknownUser`, or every request fails with a `<PROTECT>`/403 before reaching the dispatch class.

The dashboard itself is static and served by Apache from the mounted `web/` directory. No IRIS web server is involved in serving the page.

## A checklist for another production

If you want the same replay on a different IRIS production:

1. Add a thin `/trace` endpoint over `Ens.MessageHeader` (ID, session, source, target, time, body class) and return server time.
2. Persist the AI session id, model, token counts, tool-call count and latency with every decision.
3. Add `/reasoning` that opens `%AI.Agent.Session` and returns the `ContextData` messages.
4. Add `/messages` that opens message bodies by class and id and exports them defensively.
5. Keep the body classes JSON-exportable; treat export as best-effort.
6. Map config names to UI nodes once, not in every render path.
7. Prefer deep links to the Message Viewer for the raw record.
8. Test against the message retention window you actually run in production.

## What this buys

The replay is not a demo trick. It changes how the workflow is debugged and reviewed:

- A wrong decision can be traced to the exact context the agent saw and the tool result that misled it.
- Latency is attributable per hop, not just end to end.
- Token cost is attached to the decision, not to a monthly bill.
- A human approval is a visible part of the chain, with a name and a timestamp.

An agent that moves money should be able to show its work. In IRIS, most of the evidence already exists; the work is joining it into one timeline.

---

Try the replay on the live demo: [43.139.159.100:8082/paymentguard](http://43.139.159.100:8082/paymentguard/) · Source: [github.com/Dylan5237/payment-guard-ai](https://github.com/Dylan5237/payment-guard-ai)

If this approach is useful to you, [vote for PaymentGuard AI on Open Exchange](https://openexchange.intersystems.com/contest/49) — find **PaymentGuard AI** in the list and click **Vote**. Thank you.
