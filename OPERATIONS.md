# PaymentGuard AI — Operations Guide

Runbook for operating the PaymentGuard demo deployment (and for reusing it as
a starting point in a real environment). For architecture and API reference
see [README](README.md).

## Deployment shape

```
docker compose up -d
├── iris          InterSystems IRIS 2026.3 EAP (AI Hub image, NoPWS build)
│                 IRISAPP namespace: PaymentGuard production + data + REST
└── webgateway    Web Gateway (Apache + CSP module) sidecar
                  ├── /paymentguard      dashboard (static, from web/)
                  ├── /paymentguard/api  REST (rewritten to *.csp twins)
                  └── /csp/...           Management Portal
```

Two things about this layout that matter operationally:

- **The EAP image has no private web server (NoPWS)** — everything HTTP goes
  through the Web Gateway sidecar. Port 52773 does not exist; the IRIS
  container publishes only 1972.
- **The Web Gateway CSP module intercepts by file extension**, not by path.
  Extensionless REST URLs are internally rewritten to a `.csp` twin (both
  forms are mapped in `PaymentGuard.REST.Dispatch`). The `/csp` extension
  list must include the Portal's static assets (`js css png ... xsl xml xsd`)
  or the Portal renders as raw `${...}` templates.

## First-line health checks

```bash
docker compose ps                       # both containers Up (healthy)
curl http://localhost:8082/paymentguard/api/health
# {"production_running":true, "agent_mode":"live", ...}
curl http://localhost:8082/paymentguard/api/reviews   # open workflow tasks
```

`agent_mode: "mock"` means no API key is reachable — see configuration below.

## Configuration

Precedence for every setting: **runtime override → environment variable →
default**. The agent resolves settings on every decision, so runtime changes
apply to the next request without a restart.

| Setting | Env var | Runtime override | Notes |
|---|---|---|---|
| Provider | `AI_PROVIDER` | `PUT /admin/model {"provider":...}` | any `%AI.Provider` name |
| Model | `AI_MODEL` | `PUT /admin/model {"model":...}` | e.g. `deepseek-chat` |
| API key | `<PROVIDER>_API_KEY` or `AI_API_KEY` | `PUT /admin/model {"api_key":...}` | never returned by GET |
| Base URL | `AI_BASE_URL` | `PUT /admin/model {"base_url":...}` | OpenAI-compatible gateways |
| Mock mode | `AGENT_MOCK=1` | `PUT /admin/model {"mock":true/false}` | deterministic offline engine |
| Admin token | `ADMIN_TOKEN` | `^PaymentGuardSettings("AdminToken")` | required by `/admin/*` |

Reading current effective values (each field reports its source):

```bash
curl http://localhost:8082/paymentguard/api/admin/model
```

Setting the key at runtime (takes effect on the next decision):

```bash
curl -X PUT http://localhost:8082/paymentguard/api/admin/model \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -d '{"provider":"openai","model":"gpt-4o-mini","api_key":"sk-..."}'
```

Env var changes require recreating the IRIS container
(`docker compose up -d --force-recreate iris`); runtime overrides do not.

## Routine operations

**Reseed demo data** (wipes customers/transactions/decisions/cases, cancels
open workflow tasks, restarts the production):

```bash
curl -X POST http://localhost:8082/paymentguard/api/admin/reseed \
  -H "X-Admin-Token: $ADMIN_TOKEN"
```

**Logs**: `docker compose logs iris` (interoperability + `messages.log`),
`docker compose logs webgateway` (Apache/CSP). Per-decision reasoning lives in
the database, not logs: every decision carries the persisted AI Hub session id
(`/api/decisions` → `/api/reasoning?session=...`), and every message hop is in
`Ens.MessageHeader` (Portal → Message Viewer, or `/api/trace`).

**Human review queue**: every REVIEW decision (including agent-failure
fallbacks) opens a native Workflow Engine task in the role
`PaymentGuard Human Review`. Action it from the dashboard panel or:

```bash
curl -X POST http://localhost:8082/paymentguard/api/reviews/decide \
  -H "Content-Type: application/json" \
  -d '{"task_id":12,"action":"Approve","reviewer":"RiskAnalyst"}'
```

## Failure playbook

**All requests hang / only the first hop (REST→Decision) appears, `StartProduction` fails with `ErrProductionNotShutdownCleanly`**
The production's shutdown state got poisoned (classic cause: wiping tables
while requests were in flight). `docker restart` does **not** fix this — the
poisoned state lives in the container's writable layer. The only reliable
recovery: `docker compose down && docker compose up -d`, then reseed if
needed. The reseed endpoint stops the production first precisely to avoid
creating this state.

**Agent answers fall back to human review (`source: FALLBACK`)**
By design: a hung or failing LLM call never blocks or silently approves —
after 20 s the decision degrades to REVIEW and a workflow task opens. Check
`/api/admin/model` (key present? right provider?), then watch
`docker compose logs iris` for the agent call error. DeepSeek or any
OpenAI-compatible endpoint works; see configuration above.

**Portal pages render as raw `${title}` placeholders or are blank**
The `/csp` `CSPFileTypes` list is missing an extension the Portal needs. Edit
the gateway config **inside the container** (`cat > /etc/cspgateway/csp-apache.conf`,
never `sed -i` on the host — the single-file bind mount keeps the old inode),
then `apache2ctl -k restart` (a graceful reload sometimes picks up stale
config). The current full list lives in `webgateway/csp-apache.conf`.

**Production doesn't start after container boot**
`%ZSTART` can fire before the interoperability subsystem is ready.
`PaymentGuard.Util.Setup.EnsureRunning()` retries the start 3× every 4 s; the
first REST request also self-heals via `GetBusinessService`. If it is still
down after ~15 s, check `docker compose logs iris` for license or journal
errors.

**Code changes disappeared after `compose down/up`**
Classes compiled into the running container's writable layer are lost when the
container is recreated from the image. After hot-patching classes in a
container, re-bake the image (`docker commit <iris-container> <image>:latest`)
or rebuild from source, or the next recreate silently reverts the fix.

## Security notes — before real-world reuse

The demo ships deliberately open. For anything exposed beyond a demo:

- **REST API**: decision/inspection endpoints are unauthenticated. Put real
  authentication in front (the Web Gateway supports it, or an API gateway):
  at minimum require auth on `POST /payments`, `POST /claims`,
  `POST /reviews/decide`, and all of `/admin/*`.
- **Admin token**: set `ADMIN_TOKEN` (the endpoints refuse to run without one)
  and rotate it via `^PaymentGuardSettings("AdminToken")` if it leaks.
- **Portal**: the demo grants `UnknownUser` the `%All` role and unauthenticated
  access to `/paymentguard/*` web apps (see `iris.script` and
  `PaymentGuard.Util.Setup`). Remove both grants, disable
  `UnExpireUserPasswords("*")`, and change all default passwords
  (`SuperUser`, `CSPSystem`). Portal credentials belong in a password manager,
  not in the dashboard.
- **Transport**: terminate TLS at the gateway or a front proxy; the demo is
  plain HTTP.
- **Data**: transaction/audit tables grow unbounded. Add a retention policy
  (e.g. a scheduled task purging `PaymentGuard_Data.*` and purged message
  bodies older than N days) and consider pseudonymization if real payment data
  ever flows through.
- **LLM egress**: the agent sends decision context (customer/merchant
  identifiers, amounts) to the configured provider. Pick a provider/region
  that matches your data-residency requirements, or point `base_url` at a
  self-hosted gateway.

## Image licensing note

The IRIS image is the InterSystems **AI Hub EAP Community** image
(`2026.3.0AI.154.0`) downloaded from the EAP portal. It may not be
redistributed; everyone reproducing this deployment must download it
themselves. The non-community image of the same version lacks the
Interoperability/CSP license and will fail with `<PROTECT>` errors.
