Include (%occStatus)

/// Healthcare claims scenario: claim-to-payment mapping, the duplicate
/// cross-city rule, the provider blacklist, and the end-to-end claim flow
/// through the production with the mock agent engine.
Class PaymentGuard.Tests.TestClaims Extends %UnitTest.TestCase
{

Method OnBeforeAllTests() As %Status
{
    Set ^PaymentGuardSettings("MockMode") = 1
    // Clean reset: stop first - reseeding while the production runs poisons it
    Do ##class(PaymentGuard.Util.Setup).ResetDemo()
    Quit ##class(PaymentGuard.Util.Setup).EnsureRunning()
}

Method OnAfterAllTests() As %Status
{
    Kill ^PaymentGuardSettings("MockMode")
    Quit $$$OK
}

ClassMethod Ctx() As %DynamicObject
{
    Quit {"customer": {"known": 1, "kyc_status": "VERIFIED", "blacklisted": 0, "segment": "VIP", "trust_score": 80, "country": "CN"}, "velocity_1h": {"count": 0}, "device": {"known": 0, "customer_count": 0}}
}

/// Unique-per-run member id so repeated runs never hit the unique index
ClassMethod FixtureId() As %String
{
    Quit "memb_tc_"_$Increment(^PaymentGuardTests)
}

ClassMethod FixtureMember(pId As %String, pPriorCity As %String, pPriorDaysAgo As %Integer) As %Status
{
    Set c = ##class(PaymentGuard.Data.Customer).%New()
    Set c.CustomerId = pId
    Set c.Name = "Claim Fixture"
    Set c.Segment = "VIP"
    Set c.Country = "CN"
    Set c.RiskRating = "LOW"
    Set c.KycStatus = "VERIFIED"
    Set c.TrustScore = 85
    Set tSC = c.%Save()
    If $$$ISERR(tSC) Quit tSC
    Quit ##class(PaymentGuard.Data.Populate).ClaimTxn(pId, "Fixture Hospital", "TESTPROC", "T99.9", 5000, pPriorCity, pPriorDaysAgo)
}

ClassMethod Submit(pReq As PaymentGuard.Request.Payment, Output pResp As PaymentGuard.Response.Decision) As %Status
{
    Set sc = ##class(Ens.Director).CreateBusinessService("PaymentGuard REST", .tBS)
    Quit:$$$ISERR(sc) sc
    Quit tBS.SendRequestSync("PaymentGuard Decision", pReq, .pResp, 60)
}

/// A claim on the endpoint vocabulary maps onto the standard payment request
Method TestClaimMapping()
{
    Set body = {"member_id": "memb_001", "provider": "Shanghai Renji Hospital", "procedure": "CATARACT_SURGERY", "diagnosis": "H25.9", "amount": 12800, "city": "Beijing"}
    Set req = ##class(PaymentGuard.REST.Dispatch).ClaimToPayment(body)
    Do $$$AssertEquals(req.CustomerId, "memb_001", "member maps to customer")
    Do $$$AssertEquals(req.Merchant, "Shanghai Renji Hospital", "provider maps to merchant")
    Do $$$AssertEquals(req.Procedure, "CATARACT_SURGERY", "procedure carried")
    Do $$$AssertEquals(req.Diagnosis, "H25.9", "diagnosis carried")
    Do $$$AssertEquals(req.City, "Beijing", "city carried")
    Do $$$AssertEquals(req.Amount, 12800, "amount carried")
    Do $$$AssertEquals(req.Currency, "CNY", "claims default to CNY")
    Do $$$AssertEquals(req.GeoCountry, "CN", "claims default to CN geo")
    Do $$$AssertEquals(req.MerchantCategory, "HEALTHCARE", "claims tagged HEALTHCARE")
    // explicit overrides win
    Set body2 = {"member_id": "memb_001", "amount": 100, "currency": "USD", "geo_country": "US"}
    Set req2 = ##class(PaymentGuard.REST.Dispatch).ClaimToPayment(body2)
    Do $$$AssertEquals(req2.Currency, "USD", "explicit currency wins")
    Do $$$AssertEquals(req2.GeoCountry, "US", "explicit geo wins")
    Do $$$AssertEquals(req2.Procedure, "", "no procedure means a plain payment")
}

/// A claim from a blacklisted provider is blocked deterministically
Method TestBlacklistedProvider()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "memb_002", req.Amount = 900, req.GeoCountry = "CN"
    Set req.Procedure = "PHYSICAL_EXAM", req.City = "Shenzhen"
    Set req.Merchant = "Sunrise Wellness Center"
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(), .rule, .reason)
    Do $$$AssertEquals(r, "BLOCK", "blacklisted provider blocks the claim")
    Do $$$AssertEquals(rule, "BLACKLISTED_MERCHANT", "rule name")
}

/// Same member + same procedure settled in another city within 7 days blocks
Method TestDuplicateCrossCityClaim()
{
    Set id = ..FixtureId()
    Do $$$AssertStatusOK(..FixtureMember(id, "Wuhan", 2))
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = id, req.Amount = 5000, req.GeoCountry = "CN"
    Set req.Procedure = "TESTPROC", req.City = "Xian", req.Merchant = "Xian Central Hospital"
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(), .rule, .reason)
    Do $$$AssertEquals(r, "BLOCK", "cross-city duplicate claim blocks")
    Do $$$AssertEquals(rule, "DUPLICATE_CROSS_CITY_CLAIM", "rule name")
    Do $$$AssertTrue($Find(reason, "Wuhan") > 0, "reason names the prior city")
}

/// Same city, or a prior outside the 7-day window, stays in the gray zone
Method TestSameCityAndStalePriorStayGray()
{
    Set id = ..FixtureId()
    Do $$$AssertStatusOK(..FixtureMember(id, "Wuhan", 2))
    // same city as the prior settlement: no cross-city duplicate signal
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = id, req.Amount = 5000, req.GeoCountry = "CN"
    Set req.Procedure = "TESTPROC", req.City = "Wuhan", req.Merchant = "Wuhan Union Hospital"
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ..Ctx(), .rule, .reason)
    Do $$$AssertEquals(r, "", "same-city claim escalates to the agent")

    // prior in another city but 9 days old: outside the duplicate window
    Set id2 = ..FixtureId()
    Do $$$AssertStatusOK(..FixtureMember(id2, "Chengdu", 9))
    Set req2 = ##class(PaymentGuard.Request.Payment).%New()
    Set req2.CustomerId = id2, req2.Amount = 5000, req2.GeoCountry = "CN"
    Set req2.Procedure = "TESTPROC", req2.City = "Hangzhou", req2.Merchant = "Hangzhou First Hospital"
    Set r2 = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req2, ..Ctx(), .rule2, .reason2)
    Do $$$AssertEquals(r2, "", "stale prior stays in the gray zone")
}

/// End to end: the seeded Shanghai settlement makes a Beijing claim for the
/// same surgery a deterministic rule block through the full production
Method TestClaimRuleBlockEndToEnd()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "memb_001", req.Amount = 12800, req.Currency = "CNY", req.GeoCountry = "CN"
    Set req.Merchant = "Beijing Union Medical College Hospital", req.MerchantCategory = "HEALTHCARE"
    Set req.Procedure = "CATARACT_SURGERY", req.Diagnosis = "H25.9", req.City = "Beijing"
    Set sc = ..Submit(req, .resp)
    Do $$$AssertStatusOK(sc)
    Do $$$AssertEquals(resp.Action, "BLOCK", "cross-city duplicate claim blocked")
    Do $$$AssertEquals(resp.Source, "RULES", "decided by the rule engine")
    Do $$$AssertTrue($Find(resp.ReasonCodes, "DUPLICATE_CROSS_CITY_CLAIM") > 0, "reason code recorded")
    Set txn = ##class(PaymentGuard.Data.Transaction).OpenByTxnId(resp.TxnId)
    Do $$$AssertTrue($IsObject(txn), "claim persisted as a transaction")
    Do $$$AssertEquals(txn.Status, "BLOCKED", "transaction status BLOCKED")
    Do $$$AssertEquals(txn.Procedure, "CATARACT_SURGERY", "procedure persisted")
    Do $$$AssertTrue(resp.DecisionId '= "", "audit record linked")
}

/// End to end: a same-city claim slips past the rule and the agent correlates
/// it with the member's claim history (mock engine mirrors the behavior)
Method TestClaimGrayZoneCorrelatedByAgent()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "memb_001", req.Amount = 12800, req.Currency = "CNY", req.GeoCountry = "CN"
    Set req.Merchant = "Shanghai Renji Hospital", req.MerchantCategory = "HEALTHCARE"
    Set req.Procedure = "CATARACT_SURGERY", req.Diagnosis = "H25.9", req.City = "Shanghai"
    Set sc = ..Submit(req, .resp)
    Do $$$AssertStatusOK(sc)
    Do $$$AssertEquals(resp.Source, "MOCK", "same-city claim reaches the agent")
    Do $$$AssertEquals(resp.Action, "BLOCK", "agent correlates the duplicate reimbursement")
    Do $$$AssertTrue($Find(resp.ReasonCodes, "duplicate_reimbursement") > 0, "duplicate reason surfaced")
}

}
