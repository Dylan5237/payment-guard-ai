Include (%occStatus)

/// Offline-trained logistic fraud-risk prior, computed by Embedded Python.
///
/// ScorePy is a [Language = python] method: pure standard library (json/math),
/// no pip packages, so it runs inside the IRIS container as-is. The weights
/// were calibrated offline against the seeded demo history; the output is an
/// advisory prior for the AI Risk Agent ("ml_model" in the enrichment
/// context), never a load-bearing input — if Embedded Python is unavailable
/// the decision flow proceeds without the score.
Class PaymentGuard.Rules.PyModel
{

/// Returns {"model":..., "risk_score":0-100, "top_signals":[...], "note":...}
/// or an error object if the context cannot be parsed.
ClassMethod Score(pCtxJson As %String) As %DynamicObject
{
    Quit ##class(%DynamicObject).%FromJSON(..ScorePy(pCtxJson))
}

ClassMethod ScorePy(pCtxJson As %String) As %String [ Language = python ]
{
import json, math

try:
    ctx = json.loads(pCtxJson)
except Exception:
    return json.dumps({"model": "logistic-embedpy-v1", "risk_score": None, "error": "context_parse_failed"})

p = ctx.get("payment") or {}
c = ctx.get("customer") or {}
v = ctx.get("velocity_1h") or {}
d = ctx.get("device") or {}
m = ctx.get("merchant") or {}

def num(x, default=0.0):
    try:
        return float(x)
    except (TypeError, ValueError):
        return default

amount = num(p.get("amount"))
avg_monthly = num(c.get("avg_monthly_usd"))
if avg_monthly > 0:
    ratio = min(amount / avg_monthly, 10.0)
else:
    ratio = 2.0 if amount > 0 else 0.0

v1 = min(int(num(v.get("count"))), 15)
new_device = 0.0 if d.get("known") else 1.0
shared = max(min(int(num(d.get("customer_count"))) - 1, 4), 0)
geo = p.get("geo_country") or ""
home = c.get("country") or ""
geo_mismatch = 1.0 if (c.get("known") and geo and home and geo != home) else 0.0
block_rate = min(num(m.get("block_rate_30d")), 1.0)
kyc_pending = 1.0 if (c.get("known") and c.get("kyc_status") != "VERIFIED") else 0.0
trust = num(c.get("trust_score"), 50.0) if c.get("known") else 50.0
trust_deficit = max(min((75.0 - trust) / 25.0, 3.0), 0.0)

terms = {
    "amount_vs_baseline": 0.45 * ratio,
    "velocity_1h": 0.30 * v1,
    "new_device": 0.90 * new_device,
    "shared_device": 0.50 * shared,
    "geo_mismatch": 0.80 * geo_mismatch,
    "merchant_block_rate": 1.20 * block_rate,
    "kyc_pending": 0.40 * kyc_pending,
    "low_trust": 0.35 * trust_deficit,
}
z = -3.2 + sum(terms.values())
score = round(max(0.0, min(100.0, 100.0 / (1.0 + math.exp(-z)))), 1)
top = [k for k, val in sorted(terms.items(), key=lambda kv: -kv[1]) if val >= 0.35][:4]

return json.dumps({
    "model": "logistic-embedpy-v1",
    "risk_score": score,
    "top_signals": top,
    "note": "offline-trained prior computed by Embedded Python; one advisory signal, not an oracle",
})
}

}
