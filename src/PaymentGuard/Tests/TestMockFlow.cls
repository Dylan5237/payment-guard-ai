Include (%occStatus)

/// End-to-end tests: real production, real message flow, mock agent engine
/// (forced via ^PaymentGuardSettings("MockMode")) — runs fully offline.
Class PaymentGuard.Tests.TestMockFlow Extends %UnitTest.TestCase
{

Method OnBeforeAllTests() As %Status
{
    // Force the agent operation into mock mode for this test run
    Set ^PaymentGuardSettings("MockMode") = 1
    Do ##class(PaymentGuard.Data.Populate).Seed(1)
    Quit ##class(PaymentGuard.Util.Setup).EnsureRunning()
}

Method OnAfterAllTests() As %Status
{
    Kill ^PaymentGuardSettings("MockMode")
    Quit $$$OK
}

ClassMethod Submit(pReq As PaymentGuard.Request.Payment, Output pResp As PaymentGuard.Response.Decision) As %Status
{
    Set sc = ##class(Ens.Director).CreateBusinessService("PaymentGuard REST", .tBS)
    Quit:$$$ISERR(sc) sc
    Quit tBS.SendRequestSync("PaymentGuard Decision", pReq, .pResp, 60)
}

Method TestRuleBlockBlacklisted()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "cust_blk_001", req.Amount = 100, req.GeoCountry = "GB", req.DeviceId = "dev_blk_001", req.Merchant = "Amazon"
    Set sc = ..Submit(req, .resp)
    Do $$$AssertStatusOK(sc)
    Do $$$AssertEquals(resp.Action, "BLOCK", "blacklisted customer is blocked by rules")
    Do $$$AssertEquals(resp.Source, "RULES", "decision source is rules")
}

Method TestRuleBlockSanctionedGeo()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "cust_ret_001", req.Amount = 120, req.GeoCountry = "KP", req.DeviceId = "dev_ret_001", req.Merchant = "Amazon"
    Set sc = ..Submit(req, .resp)
    Do $$$AssertStatusOK(sc)
    Do $$$AssertEquals(resp.Action, "BLOCK", "sanctioned geo is blocked")
    Do $$$AssertEquals(resp.Source, "RULES", "decision source is rules")
}

Method TestFastPathApprove()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "cust_vip_001", req.Amount = 90, req.GeoCountry = "US", req.DeviceId = "dev_vip_001", req.Merchant = "Amazon"
    Set sc = ..Submit(req, .resp)
    Do $$$AssertStatusOK(sc)
    Do $$$AssertEquals(resp.Action, "APPROVE", "trusted payment fast-approves without the LLM")
    Do $$$AssertEquals(resp.Source, "RULES", "no agent call needed")
    Do $$$AssertEquals(resp.PromptTokens, 0, "zero tokens spent")
}

Method TestGrayZoneGoesToAgent()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "cust_ret_003", req.Amount = 400, req.GeoCountry = "SG", req.DeviceId = "dev_new_77", req.Merchant = "GadgetWorld"
    Set sc = ..Submit(req, .resp)
    Do $$$AssertStatusOK(sc)
    Do $$$AssertEquals(resp.Source, "MOCK", "gray zone reached the (mock) agent")
    Do $$$AssertTrue((resp.Action = "APPROVE") || (resp.Action = "REVIEW") || (resp.Action = "BLOCK"), "valid action from mock engine")
    Do $$$AssertTrue(resp.RiskScore >= 0 && resp.RiskScore <= 100, "risk score in range")
}

Method TestFraudPatternBlockedByAgent()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "cust_ret_001", req.Amount = 3000, req.GeoCountry = "NG", req.DeviceId = "dev_shared_7", req.Merchant = "CryptoExchange X"
    Set sc = ..Submit(req, .resp)
    Do $$$AssertStatusOK(sc)
    Do $$$AssertEquals(resp.Source, "MOCK", "reached the (mock) agent")
    Do $$$AssertEquals(resp.Action, "BLOCK", "high-amount watchlist-geo shared-device payment blocks")
}

Method TestAuditTrailWritten()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "cust_ret_002", req.Amount = 250, req.GeoCountry = "SG", req.DeviceId = "dev_new_88", req.Merchant = "TravelHub"
    Set sc = ..Submit(req, .resp)
    Do $$$AssertStatusOK(sc)
    Do $$$AssertTrue(resp.DecisionId '= "", "decision id returned")

    // The audit record exists and links back to the transaction
    Set tStmt = ##class(%SQL.Statement).%New()
    Do tStmt.%Prepare("SELECT Action, Source, Model FROM PaymentGuard_Data.Decision WHERE TxnId = ?")
    Set tRS = tStmt.%Execute(resp.TxnId)
    Do $$$AssertTrue(tRS.%Next(), "audit record persisted")
    Do $$$AssertEquals(tRS.%Get("Source"), "MOCK", "audit source recorded")

    // And the transaction status matches the action
    Set txn = ##class(PaymentGuard.Data.Transaction).OpenByTxnId(resp.TxnId)
    Do $$$AssertTrue($IsObject(txn), "transaction persisted")
    Do $$$AssertEquals($Select(txn.Status = "SETTLED": "APPROVE", txn.Status = "REVIEW": "REVIEW", txn.Status = "BLOCKED": "BLOCK", 1: "?"), resp.Action, "transaction status matches decision")
}

}
