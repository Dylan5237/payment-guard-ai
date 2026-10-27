# PaymentGuard AI: an AI Hub agent as the decision-maker in an IRIS interoperability production

*Built for the InterSystems Programming Contest "AI Agent in Interoperability Workflows" (Oct–Nov 2026). Source: [github.com/Dylan5237/payment-guard-ai](https://github.com/Dylan5237/payment-guard-ai)*

Payment authorization is a decision problem. Most payment flows are boring — a known customer, a typical amount, a familiar device — and a handful of deterministic rules settle them in microseconds. But between "obviously fine" and "obviously fraud" lives the gray zone: a new device, an unusual country, an amount a little above baseline, a customer with pending KYC. That gray zone is where human analysts spend their day, and it is exactly where an LLM agent with **grounded tool access** can help.

PaymentGuard AI puts a real IRIS AI Hub agent (`%AI.Agent`) inside an ordinary interoperability production as a business operation. The agent doesn't guess — it queries the payment platform's own IRIS database through AI Hub SQL tools, then answers with a strict JSON decision that the production routes, audits and accounts for.

## Architecture

```
POST /paymentguard/api/payments
        │
        ▼
┌─ PaymentGuard.Production ─────────────────────────────────┐
│  REST BS → Decision BP                                     │
│              1. persist attempt                            │
│              2. enrich (customer / velocity / device /     │
│                 merchant — live SQL)                       │
│              3. deterministic rules                        │
│                  ├─ blacklist / sanctions / caps / burst   │
│                  │    → BLOCK  (no LLM call, 0 tokens)     │
│                  ├─ trusted + small + home + known device  │
│                  │    → APPROVE fast path (0 tokens)       │
│                  └─ everything else = gray zone ──┐        │
│              4. parse + validate JSON            │        │
│              5. route outcome                    ▼        │
│              6. immutable audit record   AI Risk Agent BO  │
│                                            (%AI.Agent +    │
│  APPROVE → Settlement BO                  5 SQL tools)     │
│  REVIEW  → Review queue BO (case)                           │
│  BLOCK   → Fraud alert BO                                  │
└─────────────────────────────────────────────────────────────┘
```

The centerpiece is the **"PaymentGuard AI Risk Agent" business operation**: a plain `Ens.BusinessOperation` that hosts the AI Hub agent in-process. A business process talks to the AI exactly like it talks to any other operation — queued, retried, and traced message-by-message in the Management Portal — while the operation internally instantiates the declarative agent, runs the agentic loop, persists the `%AI.Agent.Session` and reports token usage back into the message flow.

## The agent

`PaymentGuard.Agent.RiskAgent` extends `%AI.Agent`:

- **INSTRUCTIONS** — a payment-underwriter persona with an explicit decision policy (BLOCK only on converging signals, REVIEW when unusual-but-plausible, APPROVE when consistent with established profile) and a strict output contract: one JSON object, nothing else — `action`, `risk_score`, `confidence`, snake_case `reasons[]`, a human-readable `summary`.
- **Tools** — five read-only tools (`%AI.Tool` methods): customer profile, recent transactions, payment velocity, device reputation, merchant statistics. Each is live SQL over the production's own tables; the agent decides what to verify.
- **Provider-agnostic** — DeepSeek out of the box (`AI_PROVIDER`/`AI_MODEL`/`<PROVIDER>_API_KEY` in `.env`); any AI Hub provider works.

The decision process treats the agent like any fallible dependency: its answer is parsed defensively (plain JSON, fenced JSON, JSON-in-prose), validated against the contract, and **any failure degrades to a human REVIEW with a reason code** — an AI outage never silently approves and never blocks revenue.

## Real decisions, real reasons

A 12-payment demo burst produced exactly the split you'd want — 7 APPROVE (2 by rules, 5 by the agent), 4 REVIEW, 1 BLOCK. The agent's reasoning is grounded in the data it queried. Two examples from the live run:

> **BLOCK, risk 88** — "Three high-value ecommerce payments from Hong Kong and UAE fired within 9 seconds on a device first seen today, far above Alice Tanaka's ~$900/month baseline of US-based small purchases — classic account-takeover card-testing burst."
> reasons: `burst_velocity_3_txns_9s`, `geo_mismatch_hk_ae_vs_us_home`, `amount_above_baseline_710_vs_avg_monthly_900`, `brand_new_device_first_seen_today`

> **REVIEW, risk 45** — "Customer's established history is DE e-commerce spend with AWS/Siemens, but this is a first-seen device making a card payment at a Turkish luxury watch merchant. Amount is small and there is no velocity burst … risk is moderate rather than clear-cut — route to human review."

The first decision is the interesting one: the agent **correlated three separate payments inside the same burst** (via its velocity tool) and named the fraud pattern. Every decision row carries prompt/completion tokens, tool-call count, latency, model and the persisted AI Hub session id — any decision can be replayed with `##class(%AI.Agent.Session).%OpenId(<id>)`. In the demo run the agent spent ~3,000 prompt + ~350 completion tokens and ~2–3 s per gray-zone decision; the fast-path and rule decisions cost zero.

## The NoPWS surprise (or: how to serve anything from these builds)

The 2026.3 AI Hub EAP builds are **NoPWS** — the private web server on port 52773 is disabled entirely; no portal, no REST, nothing HTTP from the IRIS container. PaymentGuard therefore ships a standard InterSystems **Web Gateway sidecar** (`containers.intersystems.com/intersystems/webgateway`) and documents the three things that made it work:

1. **Credentials live in CSP.ini** — this gateway build ignores the usual `ISC_CSP_IRIS_*` env vars; the `[LOCAL]` section needs `Username=CSPSystem` / `Password=SYS`, and the EAP builds no longer create the CSPSystem user, so the installer creates it and enables `%Service_WebGateway`.
2. **The Apache module dispatches by file extension** (`CSPFileTypes csp cls zen cxw`) — extensionless REST URLs never reach IRIS. The stack internally rewrites them to a `.csp` twin route (mod_rewrite + a doubled UrlMap), so pretty URLs like `POST /payments` work unchanged.
3. **Unauthenticated demo access** needs the web apps' roles granted to UnknownUser, or every request dies with `<PROTECT>`/403 before reaching your dispatch class.

The dashboard itself is plain static HTML served straight from Apache (mounted `web/` directory), polling the API — no build step, no npm.

## Try it

```bash
docker load -i iris-community-2026.3.0AI.154.0-docker.tar.gz   # from the EAP portal
docker pull containers.intersystems.com/intersystems/webgateway:latest-cd
git clone https://github.com/Dylan5237/payment-guard-ai && cd payment-guard-ai
cp .env.example .env      # add DEEPSEEK_API_KEY (or any provider)
docker compose up -d --build
```

Open http://localhost:8082/paymentguard/ for the live decision console, or POST a payment:

```bash
curl -s -X POST localhost:8082/paymentguard/api/payments -H "Content-Type: application/json" \
  -d '{"customer_id":"cust_ret_003","amount":430,"geo_country":"SG","device_id":"dev_new_9","merchant":"GadgetWorld"}'
```

No API key? The stack runs end-to-end in **mock mode** — a deterministic engine answers in the same JSON contract, so the flow, dashboard, audit trail and the whole %UnitTest suite work offline (`do ##class(PaymentGuard.Tests.Suite).RunAll()` — 18 tests, green).

## What we'd build next

- a second-stage **dispute analyst agent** that works the REVIEW queue with write-scoped tools (place holds, request documents);
- **OpenTelemetry span export** for agent calls (the `%AI` stack is OTel-ready — we ship the audit table today, spans next);
- RAG over analyst notes so the agent learns from past resolutions.

---

*PaymentGuard AI is an open-source demo built on the InterSystems IRIS 2026.3 AI Hub Early Access build. Thanks to the AI Hub team for the EAP program and the `%AI` SDK — the agent/production boundary felt genuinely well-designed once we stopped fighting the container's missing web server.*
