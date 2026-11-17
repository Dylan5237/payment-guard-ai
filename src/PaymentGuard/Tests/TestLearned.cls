Include (%occStatus)

/// Unit tests for the learning layer (PaymentGuard.Learned.Store) and its
/// integration with the rule engine: an approved human review learns device
/// trust, LEARNED_DEVICE_FAST_PATH approves the next payment of the same
/// (customer, device) pair with zero LLM calls, hard rules stay absolute,
/// and the backtest gate refuses to contradict a past BLOCK.
Class PaymentGuard.Tests.TestLearned Extends %UnitTest.TestCase
{

/// Test fixtures use lt_-prefixed ids so cleanup never touches seeded data.
ClassMethod Clean()
{
    Do ##class(PaymentGuard.Learned.Store).Clear()
    Set tStmt = ##class(%SQL.Statement).%New()
    Do tStmt.%Prepare("DELETE FROM PaymentGuard_Data.""Transaction"" WHERE CustomerId %STARTSWITH 'lt_'")
    Do tStmt.%Execute()
}

Method OnBeforeAllTests() As %Status
{
    Do ..Clean()
    Quit $$$OK
}

Method OnAfterAllTests() As %Status
{
    Do ..Clean()
    Quit $$$OK
}

/// A gray-zone request on a learned pair: standard fast path must NOT fire
/// (no geo, customer not trusted) so only the learned rule can approve it.
ClassMethod PairRequest(pAmount As %Integer = 200) As PaymentGuard.Request.Payment
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "lt_c1", req.DeviceId = "lt_d1", req.Amount = pAmount
    Quit req
}

Method TestLearnWritesAndBacktestGate()
{
    Do ..Clean()
    // Clean pair learns
    Set r = ##class(PaymentGuard.Learned.Store).Learn("lt_c1", "lt_d1", "tester")
    Do $$$AssertTrue(r.%Get("learned"), "clean pair learns")
    Do $$$AssertTrue(##class(PaymentGuard.Learned.Store).Trusted("lt_c1", "lt_d1"), "entry is live")

    // Pair with a BLOCKED history never learns
    Set txn = ##class(PaymentGuard.Data.Transaction).%New()
    Set txn.TxnId = "lt_t1", txn.CustomerId = "lt_c2", txn.DeviceId = "lt_d2"
    Set txn.Amount = 100, txn.Status = "BLOCKED"
    Set txn.TxnTime = $ZDATETIME($HOROLOG, 3, 1)
    Do $$$AssertStatusOK(txn.%Save())
    Set r2 = ##class(PaymentGuard.Learned.Store).Learn("lt_c2", "lt_d2", "tester")
    Do $$$AssertNotTrue(r2.%Get("learned"), "prior BLOCKED history vetoes learning")
    Do $$$AssertEquals(r2.%Get("reason"), "prior_blocked_history", "gate reason")
    Do $$$AssertNotTrue(##class(PaymentGuard.Learned.Store).Trusted("lt_c2", "lt_d2"), "vetoed pair is not trusted")
}

Method TestLearnedFastPath()
{
    Do ..Clean()
    Do $$$AssertTrue(##class(PaymentGuard.Learned.Store).Learn("lt_c1", "lt_d1", "tester").%Get("learned"))

    Set ctx = {}
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(..PairRequest(200), ctx, .rule, .reason)
    Do $$$AssertEquals(r, "APPROVE", "learned pair fast-approves")
    Do $$$AssertEquals(rule, "LEARNED_DEVICE_FAST_PATH", "rule name")

    // Use counter incremented by the rule application
    Set info = ##class(PaymentGuard.Learned.Store).Info("lt_c1", "lt_d1")
    Do $$$AssertEquals(info.%Get("uses"), 1, "use counter counts rule applications")
    Do $$$AssertEquals(info.%Get("learned_by"), "tester", "reviewer recorded")
}

Method TestLearnedNeverOverridesHardRules()
{
    Do ..Clean()
    Do $$$AssertTrue(##class(PaymentGuard.Learned.Store).Learn("lt_c1", "lt_d1", "tester").%Get("learned"))

    Set req = ..PairRequest(200)
    Set req.GeoCountry = "KP"
    Set ctx = {}
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req, ctx, .rule, .reason)
    Do $$$AssertEquals(r, "BLOCK", "sanctioned geo still blocks a learned pair")
    Do $$$AssertEquals(rule, "SANCTIONED_GEO", "hard rule name")

    Set req2 = ..PairRequest(200)
    Set req2.Merchant = "Sunrise Wellness Center"
    Set r2 = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(req2, ctx, .rule2, .reason2)
    Do $$$AssertEquals(r2, "BLOCK", "blacklisted merchant still blocks a learned pair")
}

Method TestLearnedAmountCap()
{
    Do ..Clean()
    Do $$$AssertTrue(##class(PaymentGuard.Learned.Store).Learn("lt_c1", "lt_d1", "tester").%Get("learned"))

    // Above the learned cap the pair stays gray zone: learned trust widens
    // the fast path, it does not become an unlimited approval
    Set ctx = {}
    Set r = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(..PairRequest(251), ctx, .rule, .reason)
    Do $$$AssertEquals(r, "", "above LEARNEDCAP stays gray zone")
}

Method TestExpiryAndDemote()
{
    Do ..Clean()
    // Entry written with a negative TTL is already expired
    Do $$$AssertStatusOK(##class(PaymentGuard.Learned.Store).WriteEntry("lt_c3", "lt_d3", "tester", -25))
    Do $$$AssertNotTrue(##class(PaymentGuard.Learned.Store).Trusted("lt_c3", "lt_d3"), "expired entry is not trusted")

    // Fresh entry: trusted, demotable, second demote is a no-op
    Do $$$AssertStatusOK(##class(PaymentGuard.Learned.Store).WriteEntry("lt_c3", "lt_d3", "tester", 720))
    Do $$$AssertTrue(##class(PaymentGuard.Learned.Store).Trusted("lt_c3", "lt_d3"), "live entry is trusted")
    Do $$$AssertTrue(##class(PaymentGuard.Learned.Store).Demote("lt_c3", "lt_d3"), "demote reports removal")
    Do $$$AssertNotTrue(##class(PaymentGuard.Learned.Store).Trusted("lt_c3", "lt_d3"), "demoted pair is not trusted")
    Do $$$AssertNotTrue(##class(PaymentGuard.Learned.Store).Demote("lt_c3", "lt_d3"), "second demote is a no-op")
}

}
