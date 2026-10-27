Include (%occStatus)

/// Unit tests for the deterministic rule engine.
Class PaymentGuard.Tests.TestRules Extends %UnitTest.TestCase
{

ClassMethod Ctx(pBlacklist As %Boolean = 0, pKyc As %String = "VERIFIED", pSegment As %String = "RETAIL", pTrust As %Integer = 50, pCountry As %String = "US", pDevKnown As %Boolean = 1, pDevCusts As %Integer = 1, pV1h As %Integer = 0) As %DynamicObject
{
    Quit {"customer": {"known": 1, "kyc_status": (pKyc), "blacklisted": (pBlacklist), "segment": (pSegment), "trust_score": (pTrust), "country": (pCountry)}, "velocity_1h": {"count": (pV1h)}, "device": {"known": (pDevKnown), "customer_count": (pDevCusts)}}
}

Method TestBlacklisted()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "x", req.Amount = 10
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(1), .rule, .reason)
    Do $$$AssertEquals(r, "BLOCK", "blacklisted customer blocks")
    Do $$$AssertEquals(rule, "BLACKLISTED_CUSTOMER", "rule name")
}

Method TestKycFailed()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "x", req.Amount = 10
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(, "FAILED"), .rule, .reason)
    Do $$$AssertEquals(r, "BLOCK", "failed KYC blocks")
}

Method TestSanctionedGeo()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "x", req.Amount = 10, req.GeoCountry = "KP"
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(), .rule, .reason)
    Do $$$AssertEquals(r, "BLOCK", "sanctioned geo blocks")
    Do $$$AssertEquals(rule, "SANCTIONED_GEO", "rule name")
}

Method TestOverSegmentLimit()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "x", req.Amount = 6000
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(), .rule, .reason)
    Do $$$AssertEquals(r, "BLOCK", "retail cap 5000 exceeded")
    // VIP cap is higher
    Set req2 = ##class(PaymentGuard.Request.Payment).%New()
    Set req2.CustomerId = "x", req2.Amount = 6000
    Set r2 = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req2, ..Ctx(0, "VERIFIED", "VIP"), .rule2, .reason2)
    Do $$$AssertNotEquals(r2, "BLOCK", "VIP cap 100000 not exceeded")
}

Method TestVelocitySpike()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "x", req.Amount = 10
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(, , , , , , , 9), .rule, .reason)
    Do $$$AssertEquals(r, "BLOCK", "9 attempts in 1h block")
    Do $$$AssertEquals(rule, "VELOCITY_SPIKE", "rule name")
}

Method TestFastPathApprove()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "cust_vip_001", req.Amount = 90, req.GeoCountry = "US"
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(0, "VERIFIED", "VIP", 92, "US"), .rule, .reason)
    Do $$$AssertEquals(r, "APPROVE", "trusted small home payment fast-approves")
    Do $$$AssertEquals(rule, "LOW_RISK_FAST_PATH", "rule name")
}

Method TestGrayZone()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "x", req.Amount = 800, req.GeoCountry = "SG"
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(), .rule, .reason)
    Do $$$AssertEquals(r, "", "gray zone escalates to the agent")
}

}
