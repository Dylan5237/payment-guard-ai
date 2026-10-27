# Demo script (for the video)

~3 minutes, recorded at 1080p. Prepare: `.env` with a real `DEEPSEEK_API_KEY`,
`AGENT_MOCK=0`, stack running.

1. **[0:00] One-liner + dashboard open** — http://localhost:52773/csp/paymentguard/index.html
   "This is PaymentGuard AI — an InterSystems IRIS interoperability production
   where an AI Hub agent makes live payment-risk decisions."

2. **[0:20] Instant decisions (no AI)** — curl POST a sanctioned-geo payment →
   blocked by RULES in milliseconds, zero tokens. Then a trusted small payment →
   APPROVE fast path. Show both in the dashboard feed (source = RULES).

3. **[0:45] The gray zone → AI agent** — POST an unusual payment (new device,
   odd country, elevated amount). Point out: source = AI AGENT, reasons list,
   token count and latency on the decision row.

4. **[1:10] Agentic tool use** — open Management Portal message viewer, find the
   agent operation message, show the session id. In terminal:
   `Set s = ##class(%AI.Agent.Session).%OpenId("<id>")` — the saved conversation
   including tool calls. "The agent queried the customer's history itself —
   that's %AI.Agent with SQL tools inside a business operation."

5. **[1:40] Fraud burst** — dashboard "Simulate burst (8)". Watch mixed
   decisions land: rule blocks, agent blocks on shared-device/high-amount
   patterns, review cases opened. Show the review/alert panel.

6. **[2:00] Resilience** — stop the provider (set an invalid key / AGENT_MOCK=0
   with broken key, resend): decision degrades to REVIEW + FALLBACK with a clear
   reason. "An AI outage routes payments to humans — it never approves blindly
   and never blocks revenue."

7. **[2:20] Observability & wrap-up** — dashboard stats: tokens spent, average
   latency, decision split. Show a Decision audit row in the API
   (`GET /decisions`). "Hybrid decisions: rules where certainty exists, an AI
   Hub agent where judgment is needed, fail-safe everywhere — fully traced,
   fully audited, on one IRIS."
