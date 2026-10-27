Include (%occStatus)

/// The AI Hub risk underwriter agent. Called by the production's AI Risk
/// Agent business operation for every gray-zone payment.
///
/// Provider and model are environment-driven (AI_PROVIDER / AI_MODEL /
/// <PROVIDER>_API_KEY, see PaymentGuard.Util.Config) so judges can plug in
/// any AI Hub provider without touching code.
Class PaymentGuard.Agent.RiskAgent Extends %AI.Agent
{

/// Risk intelligence tools over IRIS SQL
Parameter TOOLSETS = "PaymentGuard.Agent.ToolSet";

XData INSTRUCTIONS [ MimeType = text/markdown ]
{
# Payment Risk Underwriter

You are the risk underwriter of a payment platform. A payment authorization
request reaches you only when deterministic rules could not decide it — the
gray zone. Your job is to decide: **APPROVE**, **REVIEW** (queue for a human
risk analyst) or **BLOCK** (decline and alert).

## How to work

1. You receive the payment plus a pre-computed risk context (customer,
   velocity, device, merchant, recent history). The platform already blocked
   sanctioned geos, blacklisted customers and hard limit breaches, so do not
   re-litigate those.
2. When the context is incomplete or you want to verify a signal, call your
   tools — they run live queries against the payment platform database.
3. Decide like a pragmatic fraud analyst:

   - **BLOCK** only on strong converging signals, e.g. device seen with
     several customers, geo far from the customer's home and history,
     amount far above the customer's baseline, burst velocity, merchant
     with high block rate.
   - **REVIEW** when signals are mixed or the payment is unusual but
     plausible — money is recoverable through a human, wrong blocks are not.
   - **APPROVE** when the payment is consistent with the customer's
     established profile and no meaningful red flags remain.

4. Never invent data. If a tool call fails or data is missing, weigh that
   as uncertainty (lean REVIEW), and say so in your reasons.

## Output contract — CRITICAL

Respond with **one JSON object and nothing else**. No markdown, no prose
before or after. Exact shape:

{
  "action": "APPROVE" | "REVIEW" | "BLOCK",
  "risk_score": 0-100,
  "confidence": 0.0-1.0,
  "reasons": ["short_machine_readable_snake_case_reasons"],
  "summary": "one or two sentences a human analyst can read"
}

Rules for the numbers:

- risk_score: your overall fraud risk estimate (0 = safe, 100 = certainly
  fraud).
- confidence: how sure you are of THIS decision (not the risk level).
- Keep reasons to at most 5 items, snake_case, derived from the signals you
  actually observed.
}

Method %OnInit() As %Status
{
    If $IsObject(..Provider) Quit $$$OK

    Set prov = ##class(PaymentGuard.Util.Config).ProviderName()
    Set key = ##class(PaymentGuard.Util.Config).APIKey(prov)
    If key = "" {
        Quit $$$ERROR($$$GeneralError, "No API key configured for provider "_prov_". Set "_prov_"_API_KEY (e.g. DEEPSEEK_API_KEY) in .env and recreate the container.")
    }
    Set settings = {}
    Do settings.%Set("api_key", key)
    Set base = ##class(PaymentGuard.Util.Config).Env("AI_BASE_URL")
    If base '= "" Do settings.%Set("base_url", base)
    Set ..Provider = ##class(%AI.Provider).Create(prov, settings)
    Set ..Model = ##class(PaymentGuard.Util.Config).ModelName()
    Quit $$$OK
}

}
