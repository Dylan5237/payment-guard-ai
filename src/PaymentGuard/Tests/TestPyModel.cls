Include (%occStatus)

/// Unit tests for the Embedded Python logistic risk prior.
Class PaymentGuard.Tests.TestPyModel Extends %UnitTest.TestCase
{

ClassMethod CtxJSON(pAmount As %Float = 90, pAvgMonthly As %Float = 900, pV1 As %Integer = 0, pDevKnown As %Boolean = 1, pDevCusts As %Integer = 1, pGeo As %String = "US", pHome As %String = "US", pKyc As %String = "VERIFIED", pTrust As %Integer = 80, pBlockRate As %Float = 0) As %String
{
    Set ctx = {}
    Do ctx.%Set("payment", {"amount": (pAmount), "geo_country": (pGeo)})
    Do ctx.%Set("customer", {"known": 1, "avg_monthly_usd": (pAvgMonthly), "kyc_status": (pKyc), "trust_score": (pTrust), "country": (pHome)})
    Do ctx.%Set("velocity_1h", {"count": (pV1)})
    Do ctx.%Set("device", {"known": (pDevKnown), "customer_count": (pDevCusts)})
    Do ctx.%Set("merchant", {"block_rate_30d": (pBlockRate)})
    Quit ctx.%ToJSON()
}

Method TestScoreBounds()
{
    Set s = ##class(PaymentGuard.Rules.PyModel).Score(..CtxJSON())
    Do $$$AssertTrue($IsObject(s), "score object returned")
    Set v = s.%Get("risk_score")
    Do $$$AssertTrue(v >= 0 && v <= 100, "score within 0-100")
    Do $$$AssertTrue(v < 30, "clean profile scores low, got "_v)
}

Method TestScoreRespondsToRiskSignals()
{
    Set clean = ##class(PaymentGuard.Rules.PyModel).Score(..CtxJSON())
    // new device, geo mismatch, 7x baseline amount, low trust, shared device
    Set risky = ##class(PaymentGuard.Rules.PyModel).Score(..CtxJSON(4200, 600, 3, 0, 4, "HK", "US", "VERIFIED", 40, 0.1))
    Do $$$AssertTrue(risky.%Get("risk_score") > clean.%Get("risk_score") + 20, "risk signals raise the score: clean="_clean.%Get("risk_score")_" risky="_risky.%Get("risk_score"))
}

Method TestOutputShape()
{
    Set s = ##class(PaymentGuard.Rules.PyModel).Score(..CtxJSON())
    Do $$$AssertEquals(s.%Get("model"), "logistic-embedpy-v1", "model name")
    Do $$$AssertTrue($IsObject(s.%Get("top_signals")), "top_signals array present")
    Do $$$AssertNotEquals(s.%Get("note"), "", "note present")
}

}
