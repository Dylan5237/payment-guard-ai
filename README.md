# PaymentGuard AI

**An AI Hub agent making live payment-risk decisions inside an InterSystems IRIS interoperability production.**

PaymentGuard AI is a payment-authorization workflow built with the IRIS 2026.3 **AI Hub** Early Access build. Every inbound payment flows through an interoperability production where a **hybrid decision strategy** applies:

- **Deterministic rules first** — sanctions, blacklists, hard limits and velocity spikes are blocked instantly, and fully-trusted payments are approved instantly, with zero LLM cost.
- **The gray zone goes to an AI Hub agent** — a real `%AI.Agent` ("AI Risk Agent") with read-only **SQL tools** over the payment platform's own data. It grounds its APPROVE / REVIEW / BLOCK decision in live customer history, velocity, device reputation and merchant statistics.
- **Fail-safe by design** — if the agent errors, times out or returns malformed output, the payment degrades to a human-review queue, never to a silent approve and never to a blind block.

Every decision — rules, agent, mock or fallback — lands in an immutable audit record with **full cost observability**: prompt/completion tokens, tool-call count, latency, model and the persisted AI Hub session id (replayable via `%AI.Agent.Session`).

Built for the **InterSystems Programming Contest: AI Agent in Interoperability Workflows** (Oct–Nov 2026).

## Demo

[![Watch the demo — PaymentGuard AI](https://img.youtube.com/vi/gk_4e_GpJN0/maxresdefault.jpg)](https://youtu.be/gk_4e_GpJN0)

A 4:47 walkthrough: instant rule decisions with zero LLM cost, the gray zone going to the AI Hub agent and its SQL tools, the native Workflow Engine human-review loop, the healthcare claims scenario (cross-city duplicate reimbursement, agent-correlated claims, blacklisted provider), a burst demo where the agent correlates an account-takeover pattern, and the audit trail with tokens, latency and a replayable session id.

## Deployment and distribution

- **One command, fully containerized** — `docker compose up -d --build` starts IRIS (AI Hub EAP community image) plus the Web Gateway sidecar (see Quick start).
- **Online demo** — [http://43.139.159.100:8082/paymentguard/](http://43.139.159.100:8082/paymentguard/): the live dashboard, the REST API at `/paymentguard/api` and the production behind it, deciding in live DeepSeek mode. Management Portal: http://43.139.159.100:8082/csp/sys/UtilHome.csp (`SuperUser` / `SYS`).
- **IPM package** — module `paymentguard`: `zpm "install paymentguard"` from the InterSystems package registry (or `zpm "load /path/to/payment-guard-ai"` from the clone) installs classes, REST web apps and the dashboard.
- **Embedded Python inside** — two Python-native components in the decision path: the offline-trained logistic risk prior (`ml_model` in the risk context) and the transaction feature hasher behind vector similarity (see below). Both are `[Language = python]` methods, pure standard library, no pip packages.
- **No API key? Mock mode** — the stack runs end-to-end offline: a deterministic engine answers in the same JSON contract, and the whole %UnitTest suite (33 tests) is green without any key.
- **Operations guide** — [OPERATIONS.md](OPERATIONS.md): configuration (including swapping the model at runtime), health checks, failure playbook and security notes for reusing the stack beyond the demo.
- **Sources & media** — this repository, the [demo video](https://youtu.be/gk_4e_GpJN0), the [Developer Community article](https://community.intersystems.com/post/paymentguard-ai-ai-hub-agent-fraud-decision-maker-inside-iris-interoperability-production) and Open Exchange (*PaymentGuard-AI*).

---

## Architecture

```
                          ┌──────────────────────────────────────────────────────────┐
   POST /paymentguard/api │                PaymentGuard.Production                    │
  ────────────────────────►                                                          │
        REST callers     │  ┌────────────┐    ┌─────────────────────┐                 │
                          │  │ REST BS    │───►│ Decision BP         │                 │
                          │  └────────────┘    │  1 persist attempt   │                 │
                          │                    │  2 enrich (SQL)      │                 │
                          │                    │  3 rules             │                 │
                          │                    │     ├─ BLOCK/APPROVE │ (no LLM call)  │
                          │                    │     └─ gray zone ────┼──┐             │
                          │                    │  4 parse+validate    │  │             │
                          │                    │  5 route             │  │             │
                          │                    │  6 audit record      │  │             │
                          │                    └─────────────────────┘  │             │
                          │                          ▲    ▲            │             │
                          │                          │    └────────────┼──────────┐  │
                          │                          │                 ▼          ▼  │
                          │              ┌───────────┴───┐  ┌─────────────────────────┴───┐
                          │              │ Settlement BO │  │ AI Risk Agent operation     │
                          │              │ ReviewQueueBO │  │ (in-process %AI.Agent):     │
                          │              │ FraudAlertBO  │  │  PaymentGuard.Agent.        │
                          │              └───────────────┘  │  RiskAgent + SQL tools      │
                          │                                 │  → JSON decision + tokens   │
                          │                                 └────────────────────────────┘
                          └──────────────────────────────────────────────────────────┘
```

The production item **"PaymentGuard AI Risk Agent"** is the contest's centerpiece: an ordinary `Ens.BusinessOperation` that hosts the AI Hub agent in-process. A business process talks to the AI exactly like it talks to any other operation — queued, traced in the message viewer, retryable — while the operation internally runs `%AI.Agent`, persists the session and reports token usage.

Two further items close the loop around the gray zone: **"PaymentGuard Human Review"** (the native Workflow Engine operation, `EnsLib.Workflow.Operation`) opens a human task for every REVIEW decision, and **"PaymentGuard Review Finalizer"** settles or blocks the payment when the analyst answers — see [Human review](#human-review--native-workflow-engine).

### The agent

`PaymentGuard.Agent.RiskAgent` extends `%AI.Agent`:

| Piece | What it does |
|---|---|
| `XData INSTRUCTIONS` | Underwriter persona + decision policy + a strict JSON output contract (`action`, `risk_score`, `confidence`, `reasons[]`, `summary`) |
| `TOOLSETS` | `PaymentGuard.Agent.ToolSet` → 6 read-only tools (`%AI.Tool` methods): customer profile, recent transactions, velocity, device history, merchant profile, semantic similarity search — all live SQL |
| Provider | Environment-driven: `AI_PROVIDER` (default `deepseek`), `AI_MODEL` (default `deepseek-chat`), `<PROVIDER>_API_KEY`. Any AI Hub provider works (OpenAI, Anthropic, Gemini, Kimi, GLM/Z.ai, Zhipu, Ollama, …) |

### Decision flow detail

1. **Persist** the payment attempt (`PENDING`)
2. **Enrich** — customer, 1h/24h velocity, last 3 transactions, device reputation, merchant 30-day stats, top-3 vector-similar historical transactions
3. **Rules** — blacklist, failed KYC, sanctioned geo, segment caps, velocity spike → `BLOCK`; trusted + small + home + known device → `APPROVE` fast path. Everything in between is the gray zone
4. **Agent** — gray-zone payments are sent (as `PaymentGuard.Request.AgentDecision`) to the AI Risk Agent operation; the agent may call its tools, then must answer with JSON; the answer is parsed defensively (`Util.JSON.ExtractObject`) and validated (`Util.Validator.ValidDecision`)
5. **Route** — `APPROVE` → Settlement, `REVIEW` → human review queue (case record) **+ a native Workflow Engine task** for the review role, `BLOCK` → fraud alert. When the analyst completes the task, the Review Finalizer process routes the final call (settle or alert), appends the `HUMAN` audit record and resolves the case
6. **Audit** — decision record with reasons, model, session id, tokens, latency; transaction status updated

---

## Quick start

### Prerequisites

- Docker with the **IRIS AI Hub EAP community image** (contest requirement — note:
  the community image, not the plain EAP image; only the community license covers
  interoperability). Download `iris-community-2026.3.0AI.154.0-docker.tar.gz`
  (amd64) from the [Early Access Program portal](https://evaluation.intersystems.com/Eval/early-access/AIHub)
  (free InterSystems account required), then:

  ```bash
  docker load -i iris-community-2026.3.0AI.154.0-docker.tar.gz
  docker images                    # note the long name of the loaded image
  docker tag <loaded image name> iris-community:2026.3.0AI.154.0
  docker pull containers.intersystems.com/intersystems/webgateway:latest-cd
  ```

  The Dockerfile and `docker-compose.yml` use `iris-community:2026.3.0AI.154.0`; the
  retag step is required because the loaded EAP image comes in with a long internal
  name. The EAP image itself is not redistributed with this repository — judges load
  it from the portal as above.

  > If you prefer a different local tag, default `ARG IMAGE` at the top of the
  > `Dockerfile` instead and keep it consistent with `docker-compose.yml`.

> **Why a Web Gateway sidecar?** The 2026.3 AI Hub EAP builds are *NoPWS*: the
> private web server on port 52773 is disabled and there is no Management
> Portal listener inside the IRIS container. The stack therefore runs the
> standard InterSystems **Web Gateway** as a second container: it serves the
> Management Portal, the REST API and the dashboard over HTTP and talks to
> IRIS through the web-gateway protocol on port 1972.

### Run

```bash
git clone https://github.com/Dylan5237/payment-guard-ai
cd payment-guard-ai
cp .env.example .env         # put your DEEPSEEK_API_KEY in it (or another provider)
docker compose up -d --build # first build: ~2-3 min
```

Then open:

| What | URL |
|---|---|
| **Live dashboard** (decision feed, stats, burst simulator) | http://localhost:8082/paymentguard/ |
| Management Portal (production, message viewer) | http://localhost:8082/csp/sys/UtilHome.csp — `SuperUser` / `SYS` |
| REST API base | http://localhost:8082/paymentguard/api |
| Production config | Portal → Interoperability → productions → `PaymentGuard.Production` |

Check that it is working:

```bash
curl -s localhost:8082/paymentguard/api/health
# {"app":"paymentguard","production_running":true,"provider":"deepseek","model":"deepseek-chat",
#  "api_key_present":true,"agent_mode":"live"}
```

`production_running` must be `true`; `agent_mode` reports `live` with a key and `mock`
without one.

Without an API key the stack still runs end-to-end in **mock mode** (`/health` reports
`agent_mode: "mock"`): the agent operation answers from a deterministic mock engine, so
you can explore the full flow, dashboard, audit trail and tests with zero external
dependencies. Add a key and recreate the container to go live.

### Configuration (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `AI_PROVIDER` | `deepseek` | Any `%AI.Provider` name: `openai`, `anthropic`, `gemini`, `kimi`, `zai`, `zhipu`, `xai`, `openrouter`, … |
| `AI_MODEL` | `deepseek-chat` | Model id passed to the provider |
| `DEEPSEEK_API_KEY` | — | `<PROVIDER>_API_KEY` for whichever provider you chose (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, …) |
| `AI_API_KEY` | — | Generic fallback key |
| `AI_BASE_URL` | — | Optional custom endpoint for OpenAI-compatible servers |
| `AGENT_MOCK` | `0` | `1` forces the deterministic mock engine even when a key exists |
| `ADMIN_TOKEN` | — | Shared secret required by `/admin/*` endpoints (`X-Admin-Token` header) |

Every model setting can also be changed **at runtime** (no restart, takes effect
on the next decision) via `PUT /admin/model` — see
[Operations](OPERATIONS.md#configuration); the API answers which value is in
effect and where each one comes from (`runtime` override, `env` or `default`).

---

## API

Base: `http://localhost:8082/paymentguard/api`

> The Web Gateway's Apache module dispatches by file extension, so the stack
> internally rewrites extensionless REST URLs to a `.csp` twin route — both
> `POST /payments` and `POST /payments.csp` work from outside.

| Method & path | Description |
|---|---|
| `GET /health` | Production status, provider/model, live-vs-mock mode |
| `POST /payments` | Authorize one payment (body below) → full decision incl. tokens & latency |
| `POST /payments/batch` | `{"count": n}` (≤25) — generates and decides n mixed-pattern demo payments |
| `POST /claims` | Submit one health-insurance claim settlement (see below) |
| `GET /transactions?limit=20` | Recent payment attempts |
| `GET /similar?txn_id=…&limit=5` | Top semantic neighbors of a stored transaction (IRIS Vector Search, cosine similarity) |
| `GET /trace?limit=300` | Recent `Ens.MessageHeader` hops (id, session, source, target, body class, ms timestamps) — powers the Flow replay panel |
| `GET /messages?session=N` | Every message body of one production session — the object behind each header, serialized to JSON |
| `GET /reasoning?session=N` | The persisted `%AI.Agent.Session` message chain (context, tool calls, final answer) |
| `GET /decisions?limit=20` | Decision audit trail with reasons, model, tokens, latency, reviewer (for `HUMAN` rows) |
| `GET /cases?limit=20` | Human-review cases and fraud alerts (with resolution + resolver once finalized) |
| `GET /reviews?limit=20` | Open human-review tasks from the native Workflow Engine |
| `POST /reviews/decide` | `{"task_id":N,"action":"Approve"\|"Reject","reviewer":"RiskAnalyst"}` — complete the task; the Review Finalizer settles or blocks the payment |
| `GET /stats` | Aggregates for the dashboard |
| `GET /admin/model` | Effective model configuration and where each value comes from |
| `PUT /admin/model` | Change provider/model/base_url/api_key or flip mock mode at runtime (`X-Admin-Token` required) |
| `POST /admin/reseed` | Wipe and reseed demo data (`X-Admin-Token` required) |

Payment body:

```json
{
  "customer_id": "cust_ret_001",
  "amount": 1850.00,
  "currency": "USD",
  "merchant": "LuxWatch Ltd",
  "merchant_category": "LUXURY",
  "channel": "CARD",
  "geo_country": "NG",
  "device_id": "dev_shared_7"
}
```

Try a few:

```bash
# instant rule-based block (sanctioned geo)
curl -s -X POST localhost:8082/paymentguard/api/payments -H "Content-Type: application/json" \
  -d '{"customer_id":"cust_ret_001","amount":99,"geo_country":"KP","merchant":"Amazon"}'

# instant fast-path approve (trusted customer, small, home country, known device)
curl -s -X POST localhost:8082/paymentguard/api/payments -H "Content-Type: application/json" \
  -d '{"customer_id":"cust_vip_001","amount":90,"geo_country":"US","device_id":"dev_vip_001","merchant":"Amazon"}'

# gray zone → the AI agent decides (new device, odd geo, elevated amount)
curl -s -X POST localhost:8082/paymentguard/api/payments -H "Content-Type: application/json" \
  -d '{"customer_id":"cust_ret_003","amount":430,"geo_country":"SG","device_id":"dev_new_9","merchant":"GadgetWorld"}'

# fraud-flavored burst
curl -s -X POST localhost:8082/paymentguard/api/payments/batch -H "Content-Type: application/json" -d '{"count":8}'
```

Seeded demo customers: `cust_vip_001` (trusted VIP), `cust_ret_001..003` (retail, one
KYC-pending), `cust_sme_001/002` (business), `cust_risk_001` (high-risk), `cust_blk_001`
(blacklisted) — with ~30 days of history so tools and enrichment return real data.

---

## Human review — native Workflow Engine

Every REVIEW decision — whether the gray-zone agent asked for a human or the
fail-safe fallback kicked in — opens a task in IRIS's **native Workflow Engine**
(`EnsLib.Workflow`):

- The Decision BP sends an `EnsLib.Workflow.TaskRequest` (async, no timeout)
  to the *PaymentGuard Human Review* operation; the task lands in the
  `PaymentGuard Human Review` **role** with the full decision context as its
  message payload and `Approve,Reject` as its actions. The message trace shows
  the session waiting on the human.
- An analyst completes the task from the dashboard's *Human review* panel or
  via `POST /reviews/decide`. The Workflow Engine's task lifecycle does the
  bookkeeping (worklist items, claim/assign, completion).
- The **Review Finalizer** business process then finalizes the payment inside
  the production — routes settlement or fraud alert, appends an immutable
  `HUMAN` audit record (with the reviewer's name), flips the transaction to
  `SETTLED`/`BLOCKED` and resolves the review case. Conservative by design:
  only an explicit **Approve** settles; a reject — or anything else — blocks.

```bash
# a gray-zone payment lands in review…
curl -s -X POST localhost:8082/paymentguard/api/payments -H "Content-Type: application/json" \
  -d '{"customer_id":"cust_ret_002","amount":600,"geo_country":"SG","device_id":"dev_rev_1","merchant":"GadgetWorld"}'
# …which opens a workflow task
curl -s localhost:8082/paymentguard/api/reviews
# the analyst decides — the finalizer settles or blocks, fully traced
curl -s -X POST localhost:8082/paymentguard/api/reviews/decide -H "Content-Type: application/json" \
  -d '{"task_id":1,"action":"Approve","reviewer":"RiskAnalyst"}'
```

## Healthcare claims scenario

The same production also decides **health-insurance claim settlements**. A claim
is simply a payment that carries a `procedure`: the endpoint vocabulary maps onto
insurance vocabulary — `member_id` (the insured member) becomes the customer,
`provider` (the hospital/clinic) becomes the merchant, and `procedure` /
`diagnosis` / `city` ride along through the entire pipeline — deterministic
rules, enrichment, agent context and the audit trail — unchanged.

Two deterministic claim rules extend the rule engine:

- **Duplicate cross-city claim** — the same member settling the *same procedure*
  in *another city* within 7 days of an already-settled claim → instant
  `BLOCK` (`DUPLICATE_CROSS_CITY_CLAIM`).
- **Provider blacklist** — providers reuse the merchant blacklist mechanism →
  instant `BLOCK` (`BLACKLISTED_MERCHANT`).

Everything else flows to the AI agent, whose instructions include the claim
vocabulary and the duplicate-reimbursement pattern, so it correlates a claim
against the member's settlement history on its own.

### Demo: duplicate reimbursement, three shots, three mechanisms

Seed data: member `memb_001` (Zhang Wei) settled a full-price cataract surgery
(CNY 12,800) at Shanghai Renji Hospital 3 days ago.

**Shot 1** — the same surgery filed in Beijing: the rule engine blocks instantly.

```bash
curl -s -X POST localhost:8082/paymentguard/api/claims -H "Content-Type: application/json" \
  -d '{"member_id":"memb_001","provider":"Beijing Union Medical College Hospital","procedure":"CATARACT_SURGERY","diagnosis":"H25.9","amount":12800,"city":"Beijing","currency":"CNY"}'
```

```json
{"txn_id":"txn_6787132142_141860","action":"BLOCK","source":"RULES","risk_score":90,"confidence":1,
 "reasons":["DUPLICATE_CROSS_CITY_CLAIM"],
 "summary":"Insured member settled procedure CATARACT_SURGERY in Shanghai within the last 7 days (prior claim claimhist_memb_001_CATARACT_SURGERY_3 on 2026-10-25 00:00:00) - duplicate cross-city reimbursement",
 "model":"","session_id":"","prompt_tokens":0,"completion_tokens":0,"latency_ms":0,"decision_id":"7"}
```

**Shot 2** — the same surgery back in Shanghai (same city, so the rule passes):
the gray-zone claim reaches the AI agent, which correlates it with the member's
history — the Shanghai settlement, the Beijing block — and declines with a
reason a human adjuster can read:

```bash
curl -s -X POST localhost:8082/paymentguard/api/claims -H "Content-Type: application/json" \
  -d '{"member_id":"memb_001","provider":"Shanghai Renji Hospital","procedure":"CATARACT_SURGERY","diagnosis":"H25.9","amount":12800,"city":"Shanghai","currency":"CNY"}'
```

```json
{"txn_id":"txn_6787132181_575310","action":"BLOCK","source":"AGENT","risk_score":92,"confidence":0.9,
 "reasons":["duplicate_reimbursement","same_procedure_multiple_cities","same_procedure_settled_3_days_ago","prior_attempt_blocked_today","amount_matches_duplicate_exactly"],
 "summary":"Member Zhang Wei already has CATARACT_SURGERY (H25.9) settled at Shanghai Renji Hospital on 2026-10-25 for CNY 12,800; a further identical claim was attempted at Beijing Union Medical College Hospital today and blocked, and now the same procedure/amount is presented again in Shanghai. This is a duplicate reimbursement attempt across providers/cities and should be declined and escalated.",
 "model":"deepseek-chat","session_id":"1","prompt_tokens":1985,"completion_tokens":154,"latency_ms":1834,"decision_id":"8"}
```

**Shot 3** — a claim from a blacklisted provider: instant block, no LLM involved.

```bash
curl -s -X POST localhost:8082/paymentguard/api/claims -H "Content-Type: application/json" \
  -d '{"member_id":"memb_002","provider":"Sunrise Wellness Center","procedure":"PHYSICAL_EXAM","diagnosis":"Z00.0","amount":980,"city":"Shenzhen"}'
```

```json
{"txn_id":"txn_6787132196_629126","action":"BLOCK","source":"RULES","risk_score":90,"confidence":1,
 "reasons":["BLACKLISTED_MERCHANT"],
 "summary":"Merchant/provider Sunrise Wellness Center is on the platform blacklist",
 "model":"","session_id":"","prompt_tokens":0,"completion_tokens":0,"latency_ms":0,"decision_id":"9"}
```

`POST /api/claims` body: `member_id` and `amount` are required; `provider`,
`procedure`, `diagnosis`, `city`, `currency` (defaults to CNY), `claim_time` and
`geo_country` (defaults to CN) are optional.

Seeded demo members: `memb_001` (premium plan, the demo trigger above),
`memb_002` (premium), `memb_003` (retail, dialysis patient with a 3-week
hemodialysis history in Guangzhou), `memb_004` (business plan) — plus settled
claim history at Shanghai Renji Hospital, Beijing Union Medical College
Hospital, Guangzhou First People's Hospital and the blacklisted Sunrise
Wellness Center.

---

## Semantic similarity — IRIS Vector Search + Embedded Python

Fraud evidence often looks like "this resembles something we have seen
before". PaymentGuard encodes that instinct with IRIS Vector Search:

- **Embedding** — `PaymentGuard.Vector.Embedder` is an Embedded Python
  method that hashes the structured transaction features (procedure,
  diagnosis, provider, city, channel, amount band, currency, …) into a
  256-dimension L2-normalized vector. Pure standard library: deterministic,
  offline, no external embedding API — identical inputs always produce the
  identical vector.
- **Storage** — every transaction persisted by the production gets its
  `Embedding` (`VECTOR(double, 256)` column) written after the row is
  final; seeded history is backfilled the same way.
- **Retrieval** — `VECTOR_COSINE` top-K queries power two paths:
  - a `similar_transactions` section in every gray-zone risk context
    (pre-computed evidence, always in the prompt), and
  - a `SearchSimilarTransactions` agent tool, so the underwriter agent can
    pull semantic neighbors on demand mid-reasoning.
- **Inspection** — `GET /similar?txn_id=…` returns the neighbors with
  similarity scores.

Example: querying the seeded Shanghai cataract settlement finds the same
member's Beijing attempt at 0.82 and unrelated MRI claims at 0.31 — the
duplicate-reimbursement pattern surfaces as a similarity ranking, and the
agent cites it (`same_procedure_attempted_in_second_city_same_hour`):

```bash
curl -s "localhost:8082/paymentguard/api/similar?txn_id=claimhist_memb_001_CATARACT_SURGERY_3&limit=3"
```

## Observability

- **Message viewer**: every hop — REST entry, decision process, agent operation call,
  settlement/review/alert routing — is a traced interoperability message.
- **Decision audit table** (`PaymentGuard.Data.Decision`): source, action, risk score,
  reason codes, human-readable summary, model, AI Hub **session id**, prompt/completion
  tokens, tool calls, latency.
- **Sessions**: each agent decision's conversation is `%Save()`d; replay any decision with
  `##class(%AI.Agent.Session).%OpenId(<id>)`.
- **Dashboard** shows live token spend and average agent latency next to approval metrics.
- **Flow replay** — the dashboard's Flow panel replays any decision hop by hop over the
  production topology with the real `Ens.MessageHeader` timings (`GET /trace`), unfolds the
  agent's reasoning chain (`GET /reasoning`), and lets you click a topology node to read the
  actual message bodies that passed through it (`GET /messages`).
- **Portal deep link** — the same session opens in the Management Portal Message Viewer
  (`EnsPortal.MessageViewer.zen?SESSIONID=…`, login `SuperUser` / `SYS`), so the replay is
  a convenience layer over the tooling IRIS already ships.
- **Typical latency** — rules decide in single-digit milliseconds at zero tokens; gray-zone
  agent decisions land in ~1.4–1.9 s end to end with ~2.5k prompt tokens. A slow or hung LLM
  is capped at 20 s and degrades to a human-review item, never wedging the pipeline.

## Testing

In the container:

```bash
docker compose exec iris iris session iris -U IRISAPP
IRISAPP>do ##class(PaymentGuard.Tests.Suite).RunAll()
```

The suite covers the rule engine branches, defensive JSON parsing/validation, an
end-to-end production run in mock mode (blocked, fast-approved, gray-zone, fraud-pattern
and audit-trail cases), the healthcare claims scenario (endpoint mapping, the
duplicate cross-city rule, the provider blacklist and the agent-correlated claim
flow), the vector search layer (embedding determinism, seeded-claim retrieval,
context injection, self-exclusion, end-to-end embedding), and the human-review
workflow (task creation for REVIEW decisions, claim + complete, approve→settlement
and reject→block finalization with audit and case resolution) — it runs offline,
no API key needed.

## Project structure

```
├── Dockerfile / docker-compose.yml / merge.cpf / iris.script   # container build on the EAP image
├── webgateway/                    # Web Gateway sidecar config (CSP.ini + Apache conf)
├── module.xml                     # IPM package: classes, web apps, dashboard files, install hook
├── src/PaymentGuard/
│   ├── Agent/       RiskAgent (%AI.Agent), Tools (%AI.Tool), ToolSet (%AI.ToolSet)
│   ├── Interop/     Production, DecisionBP, AgentOperation, Settle/Review/Alert BOs
│   ├── REST/        Dispatch (%CSP.REST), BS (EnsLib.REST.Service)
│   ├── Rules/       RuleEngine, Mocker (deterministic offline engine)
│   ├── Vector/      Embedder — Embedded Python feature hasher + cosine search
│   ├── Data/        Customer, Transaction, Decision, CaseRecord, Enricher, Populate
│   ├── Request/ Response/ Msg/    interoperability messages
│   ├── Util/        Config, JSON, Validator, Setup
│   └── Tests/       %UnitTest suite
└── web/index.html   live dashboard (served from /csp/paymentguard)
```

## Notes & limitations

- Demo web apps are unauthenticated for convenience — protect them before any real use.
- The mock engine is a deterministic stand-in, not a model: it exists so the flow, tests
  and dashboard work without an API key.
- EAP software: APIs may change before GA.

## License

MIT
