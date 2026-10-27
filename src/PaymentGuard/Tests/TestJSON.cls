Include (%occStatus, %UnitTest)

/// Unit tests for defensive LLM-output parsing and decision validation.
Class PaymentGuard.Tests.TestJSON Extends %UnitTest.TestCase
{

Method TestPlainJSON()
{
    Set o = ##class(PaymentGuard.Util.JSON).ExtractObject("{""action"": ""APPROVE""}")
    Do $$$AssertTrue($IsObject(o), "plain JSON parses")
    Do $$$AssertEquals(o.%Get("action"), "APPROVE", "action read")
}

Method TestFencedJSON()
{
    Set raw = "```json"_$C(10)_"{""action"": ""BLOCK"", ""risk_score"": 88}"_$C(10)_"```"
    Set o = ##class(PaymentGuard.Util.JSON).ExtractObject(raw)
    Do $$$AssertTrue($IsObject(o), "fenced JSON parses")
    Do $$$AssertEquals(o.%Get("action"), "BLOCK", "action read")
}

Method TestJSONWithProse()
{
    Set raw = "Here is my decision: {""action"": ""REVIEW"", ""risk_score"": 55, ""confidence"": 0.7} hope this helps"
    Set o = ##class(PaymentGuard.Util.JSON).ExtractObject(raw)
    Do $$$AssertTrue($IsObject(o), "JSON in prose parses")
    Do $$$AssertEquals(o.%Get("action"), "REVIEW", "action read")
}

Method TestGarbage()
{
    Set o = ##class(PaymentGuard.Util.JSON).ExtractObject("no json here at all")
    Do $$$AssertFalse($IsObject(o), "garbage returns not-an-object")
    Set o2 = ##class(PaymentGuard.Util.JSON).ExtractObject("")
    Do $$$AssertFalse($IsObject(o2), "empty returns not-an-object")
}

Method TestValidDecision()
{
    Set good = {"action": "APPROVE", "risk_score": 20, "confidence": 0.9, "reasons": ["ok"], "summary": "fine"}
    Do $$$AssertTrue(##class(PaymentGuard.Util.Validator).ValidDecision(good), "well-formed decision validates")

    Set badAction = {"action": "MAYBE", "risk_score": 20}
    Do $$$AssertFalse(##class(PaymentGuard.Util.Validator).ValidDecision(badAction), "bad action rejected")

    Set badRisk = {"action": "APPROVE", "risk_score": 150}
    Do $$$AssertFalse(##class(PaymentGuard.Util.Validator).ValidDecision(badRisk), "risk 150 rejected")

    Set noAction = {"risk_score": 20}
    Do $$$AssertFalse(##class(PaymentGuard.Util.Validator).ValidDecision(noAction), "missing action rejected")
}

}
