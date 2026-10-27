# PaymentGuard AI

**An AI Hub agent making live payment-risk decisions inside an InterSystems IRIS interoperability production.**

PaymentGuard AI is a payment-authorization workflow built with the IRIS 2026.3 **AI Hub** Early Access build. Every inbound payment flows through an interoperability production where a **hybrid decision strategy** applies:

- **Deterministic rules first** — sanctions, blacklists, hard limits and velocity spikes are blocked instantly, and fully-trusted payments are approved instantly, with zero LLM cost.
- **The gray zone goes to an AI Hub agent** — a real `%AI.Agent` ("AI Risk Agent") with read-only **SQL tools** over the payment platform's own data. It grounds its APPROVE / REVIEW / BLOCK decision in live customer history, velocity, device reputation and merchant statistics.
- **Fail-safe by design** — if the agent errors, times out or returns malformed output, the payment degrades to a human-review queue, never to a silent approve and never to a blind block.

Every decision — rules, agent, mock or fallback — lands in an immutable audit record with **full cost observability**: prompt/completion tokens, tool-call count, latency, model and the persisted AI Hub session id (replayable via `%AI.Agent.Session`).

Built for the **InterSystems Programming Contest: AI Agent in Interoperability Workflows** (Oct–Nov 2026).

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

### The agent

`PaymentGuard.Agent.RiskAgent` extends `%AI.Agent`:

| Piece | What it does |
|---|---|
| `XData INSTRUCTIONS` | Underwriter persona + decision policy + a strict JSON output contract (`action`, `risk_score`, `confidence`, `reasons[]`, `summary`) |
| `TOOLSETS` | `PaymentGuard.Agent.ToolSet` → 5 read-only tools (`%AI.Tool` methods): customer profile, recent transactions, velocity, device history, merchant profile — all live SQL |
| Provider | Environment-driven: `AI_PROVIDER` (default `deepseek`), `AI_MODEL` (default `deepseek-chat`), `<PROVIDER>_API_KEY`. Any AI Hub provider works (OpenAI, Anthropic, Gemini, Kimi, GLM/Z.ai, Zhipu, Ollama, …) |

### Decision flow detail

1. **Persist** the payment attempt (`PENDING`)
2. **Enrich** — customer, 1h/24h velocity, last 5 transactions, device reputation, merchant 30-day stats
3. **Rules** — blacklist, failed KYC, sanctioned geo, segment caps, velocity spike → `BLOCK`; trusted + small + home + known device → `APPROVE` fast path. Everything in between is the gray zone
4. **Agent** — gray-zone payments are sent (as `PaymentGuard.Request.AgentDecision`) to the AI Risk Agent operation; the agent may call its tools, then must answer with JSON; the answer is parsed defensively (`Util.JSON.ExtractObject`) and validated (`Util.Validator.ValidDecision`)
5. **Route** — `APPROVE` → Settlement, `REVIEW` → human review queue (case record), `BLOCK` → fraud alert
6. **Audit** — decision record with reasons, model, session id, tokens, latency; transaction status updated

---

## Quick start

### Prerequisites

- Docker with the **IRIS AI Hub EAP community image** (contest requirement). Download
  `iris-community-2026.3.0AI.154.0-docker.tar.gz` (amd64) from the
  [Early Access Program portal](https://evaluation.intersystems.com/Eval/early-access/AIHub)
  (free InterSystems account required), then:

  ```bash
  docker load -i iris-community-2026.3.0AI.154.0-docker.tar.gz
  ```

  > If the loaded tag differs from the one in the `Dockerfile`, adjust the
  > `ARG IMAGE` line at the top.

### Run

```bash
git clone https://github.com/<you>/payment-guard-ai
cd payment-guard-ai
cp .env.example .env         # put your DEEPSEEK_API_KEY in it (or another provider)
docker compose up -d --build # first build: ~2-3 min
```

Then open:

| What | URL |
|---|---|
| **Live dashboard** (decision feed, stats, burst simulator) | http://localhost:52773/csp/paymentguard/index.html |
| Management Portal (production, message viewer) | http://localhost:52773/csp/sys/UtilHome.csp — `SuperUser` / `SYS` |
| Production config | Portal → Interoperability → productions → `PaymentGuard.Production` |

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

---

## API

Base: `http://localhost:52773/paymentguard/api`

| Method & path | Description |
|---|---|
| `GET /health` | Production status, provider/model, live-vs-mock mode |
| `POST /payments` | Authorize one payment (body below) → full decision incl. tokens & latency |
| `POST /payments/batch` | `{"count": n}` (≤25) — generates and decides n mixed-pattern demo payments |
| `GET /transactions?limit=20` | Recent payment attempts |
| `GET /decisions?limit=20` | Decision audit trail with reasons, model, tokens, latency |
| `GET /cases?limit=20` | Human-review cases and fraud alerts |
| `GET /stats` | Aggregates for the dashboard |
| `POST /admin/reseed` | Wipe and reseed demo data |

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
curl -s -X POST localhost:52773/paymentguard/api/payments -H "Content-Type: application/json" \
  -d '{"customer_id":"cust_ret_001","amount":99,"geo_country":"KP","merchant":"Amazon"}'

# instant fast-path approve (trusted customer, small, home country, known device)
curl -s -X POST localhost:52773/paymentguard/api/payments -H "Content-Type: application/json" \
  -d '{"customer_id":"cust_vip_001","amount":90,"geo_country":"US","device_id":"dev_vip_001","merchant":"Amazon"}'

# gray zone → the AI agent decides (new device, odd geo, elevated amount)
curl -s -X POST localhost:52773/paymentguard/api/payments -H "Content-Type: application/json" \
  -d '{"customer_id":"cust_ret_003","amount":430,"geo_country":"SG","device_id":"dev_new_9","merchant":"GadgetWorld"}'

# fraud-flavored burst
curl -s -X POST localhost:52773/paymentguard/api/payments/batch -H "Content-Type: application/json" -d '{"count":8}'
```

Seeded demo customers: `cust_vip_001` (trusted VIP), `cust_ret_001..003` (retail, one
KYC-pending), `cust_sme_001/002` (business), `cust_risk_001` (high-risk), `cust_blk_001`
(blacklisted) — with ~30 days of history so tools and enrichment return real data.

---

## Observability

- **Message viewer**: every hop — REST entry, decision process, agent operation call,
  settlement/review/alert routing — is a traced interoperability message.
- **Decision audit table** (`PaymentGuard.Data.Decision`): source, action, risk score,
  reason codes, human-readable summary, model, AI Hub **session id**, prompt/completion
  tokens, tool calls, latency.
- **Sessions**: each agent decision's conversation is `%Save()`d; replay any decision with
  `##class(%AI.Agent.Session).%OpenId(<id>)`.
- **Dashboard** shows live token spend and average agent latency next to approval metrics.

## Testing

In the container:

```bash
docker compose exec iris iris session iris -U IRISAPP
IRISAPP>do ##class(PaymentGuard.Tests.Suite).RunAll()
```

The suite covers the rule engine branches, defensive JSON parsing/validation, and an
end-to-end production run in mock mode (blocked, fast-approved, gray-zone, fraud-pattern
and audit-trail cases) — it runs offline, no API key needed.

## Project structure

```
├── Dockerfile / docker-compose.yml / merge.cpf / iris.script   # container build on the EAP image
├── module.xml                     # IPM package: classes, web apps, dashboard files, install hook
├── src/PaymentGuard/
│   ├── Agent/       RiskAgent (%AI.Agent), Tools (%AI.Tool), ToolSet (%AI.ToolSet)
│   ├── Interop/     Production, DecisionBP, AgentOperation, Settle/Review/Alert BOs
│   ├── REST/        Dispatch (%CSP.REST), BS (EnsLib.REST.Service)
│   ├── Rules/       RuleEngine, Mocker (deterministic offline engine)
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
