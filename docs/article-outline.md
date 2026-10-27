# Community article outline (EN) — to publish on community.intersystems.com

**Working title:** "PaymentGuard AI: an AI Hub agent as a fraud decision-maker inside an IRIS interoperability production"

## Structure

1. **The problem** — payment authorization is a decision task: most flows are
   deterministic, but the gray zone needs judgment. Where should an LLM sit in a
   mission-critical workflow?
2. **The architecture** — diagram: REST → decision BP → rules-first → gray zone →
   AI Risk Agent operation → route (settle / review / alert) → audit.
   Key idea: the agent is an ordinary business operation (queue, retry, message
   viewer trace), not a bolt-on HTTP call.
3. **The AI Hub pieces** — `%AI.Agent` subclass with SQL tools (`%AI.Tool`),
   toolset composition, strict JSON output contract, defensive parsing +
   validation, fail-safe REVIEW fallback.
4. **Cost observability** — every decision stores prompt/completion tokens,
   tool calls, latency, model, session id; dashboard shows live spend; sessions
   replayable via `%AI.Agent.Session`.
5. **The NoPWS surprise** — the EAP builds ship without the private web server;
   how we serve everything through a Web Gateway sidecar (CSP.ini + Apache
   config specifics, the extension-based dispatch workaround for extensionless
   REST URLs).
6. **Demo walkthrough** — dashboard screenshots: rule block, fast-path approve,
   agent gray-zone decisions with tokens, fraud burst.
7. **What we'd do next** — second-stage analyst agent for REVIEW cases, OTel
   span export, RAG over analyst notes.
8. **Try it** — one-command docker compose, DeepSeek key (or any provider),
   mock mode without any key.

## Notes for writing
- Include real numbers from the demo: tokens per decision, latency, cost estimate.
- Mention contest context + repo link + Open Exchange link.
- Tone: engineering walkthrough, not marketing.
