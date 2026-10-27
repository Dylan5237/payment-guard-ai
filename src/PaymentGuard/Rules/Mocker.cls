Include (%occStatus)

/// Deterministic mock decision engine. Used when the agent operation runs in
/// mock mode (no LLM key configured) so the whole production works end to end
/// without any external dependency — and so the test suite can run offline.
Class PaymentGuard.Rules.Mocker
{

/// Return a decision JSON string (same contract as the real agent) for the
/// given decision context.
ClassMethod DecideJSON(pContextJSON As %String) As %String
{
    Set o = {"action": "REVIEW", "risk_score": 50, "confidence": 0.9, "reasons": [], "summary": "mock decision"}
    Try {
        Set ctx = ##class(%DynamicObject).%FromJSON(pContextJSON)
        Set txn = ctx.%Get("payment")
        Set cust = ctx.%Get("customer")
        Set score = 10
        Set reasons = o.%Get("reasons")

        If $IsObject(txn) {
            Set amount = $Get(txn.amount)
            If amount > 2000 { Set score = score + 30 Do reasons.%Push("high_amount") }
            ElseIf amount > 500 { Set score = score + 15 Do reasons.%Push("elevated_amount") }
            Set geo = $Get(txn.geo_country)
            If $Find("KP,IR,SY", geo) > 0 { Set score = score + 60 Do reasons.%Push("sanctioned_geo") }
            ElseIf $Find("NG,RU,VE,PK", geo) > 0 { Set score = score + 25 Do reasons.%Push("watchlist_geo") }
        }
        If $IsObject(cust) {
            If $Get(cust.risk_rating) = "HIGH" { Set score = score + 30 Do reasons.%Push("high_risk_customer") }
            If $Get(cust.kyc_status) = "PENDING" { Set score = score + 10 Do reasons.%Push("kyc_pending") }
        }
        Set dev = ctx.%Get("device")
        If $IsObject(dev) {
            If $Get(dev.customer_count) > 1 { Set score = score + 40 Do reasons.%Push("device_shared_across_customers") }
            If $Get(dev.known) = 0 { Set score = score + 20 Do reasons.%Push("unknown_device") }
        }
        Set v1 = ctx.%Get("velocity_1h")
        If $IsObject(v1), $Get(v1.count) > 5 { Set score = score + 25 Do reasons.%Push("high_velocity") }
        Set v24 = ctx.%Get("velocity_24h")
        If $IsObject(v24), $Get(v24.total_usd) > 20000 { Set score = score + 20 Do reasons.%Push("daily_volume_exceeded") }

        If score > 100 Set score = 100
        Do o.%Set("risk_score", score)
        Set action = $Select(score >= 80: "BLOCK", score >= 45: "REVIEW", 1: "APPROVE")
        Do o.%Set("action", action)
        Do o.%Set("summary", "Mock engine decision (score "_score_")")
    } Catch ex {
        Do o.%Set("action", "REVIEW")
        Do o.%Set("risk_score", 60)
        Do o.%Set("summary", "Mock engine could not parse context, defaulting to REVIEW")
    }
    Quit o.%ToJSON()
}

}
