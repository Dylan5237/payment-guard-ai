Include (%occStatus)

/// Closes the human-review loop inside the production. When a risk analyst
/// completes the Workflow Engine task for a REVIEW decision, the decide
/// endpoint (or the test suite) pushes a PaymentGuard.Request.ReviewFinalization
/// into this process: it routes the final outcome (settlement or fraud alert),
/// appends the immutable HUMAN audit record, settles/blocks the transaction
/// and resolves the review case — every hop visible in the message trace,
/// exactly like the automated path.
Class PaymentGuard.Interop.FinalizeBP Extends Ens.BusinessProcess
{

Parameter SETTLETARGET = "PaymentGuard Settlement";

Parameter ALERTTARGET = "PaymentGuard Fraud Alerts";

Method OnRequest(pRequest As PaymentGuard.Request.ReviewFinalization, Output pResponse As Ens.Response) As %Status
{
    Set pResponse = ##class(Ens.Response).%New()
    Set txnId = pRequest.TxnId
    Set finalAction = pRequest.Action
    Set reviewer = $Select(pRequest.Reviewer'="": pRequest.Reviewer, 1: "unknown")

    // ── Route the final outcome ─────────────────────────────
    Set msg = ##class(PaymentGuard.Msg.DecisionMade).%New()
    Set msg.TxnId = txnId
    Set msg.CustomerId = pRequest.CustomerId
    Set msg.Action = finalAction
    Set msg.Source = "HUMAN"
    Set msg.RiskScore = pRequest.RiskScore
    Set msg.Summary = "Human final review by "_reviewer_": "_pRequest.HumanAction
    Set target = $Select(finalAction = "APPROVE": ..#SETTLETARGET, 1: ..#ALERTTARGET)
    Set routeResp = ""
    Set routeSC = ..SendRequestSync(target, msg, .routeResp)
    If $$$ISERR(routeSC) {
        Do ##class(Ens.Util.Log).LogWarning($classname(),"OnRequest","Routing to "_target_" failed for txn="_txnId_": "_$System.Status.GetErrorText(routeSC))
    }

    // ── Append the human audit record ───────────────────────
    Set reasons = ##class(%DynamicArray).%New()
    Do reasons.%Push($Select(pRequest.HumanAction = "Approve": "human_approved", 1: "human_rejected"))
    Set rec = ##class(PaymentGuard.Data.Decision).%New()
    Set rec.TxnId = txnId
    Set rec.CustomerId = pRequest.CustomerId
    Set rec.Amount = pRequest.Amount
    Set rec.Currency = pRequest.Currency
    Set rec.Action = finalAction
    Set rec.Source = "HUMAN"
    Set rec.RiskScore = pRequest.RiskScore
    Set rec.Confidence = 1.0
    Set rec.ReasonCodes = reasons.%ToJSON()
    Set rec.Summary = "Final decision by human reviewer "_reviewer_" ("_pRequest.HumanAction_") - "_pRequest.Summary
    Set rec.ReviewedBy = reviewer
    Set recSC = rec.%Save()
    If $$$ISERR(recSC) {
        Do ##class(Ens.Util.Log).LogWarning($classname(),"OnRequest","Audit save failed for txn="_txnId_": "_$System.Status.GetErrorText(recSC))
    }

    // ── Close the transaction ───────────────────────────────
    Set txn = ##class(PaymentGuard.Data.Transaction).OpenByTxnId(txnId)
    If $IsObject(txn) {
        Set txn.Status = $Select(finalAction = "APPROVE": "SETTLED", 1: "BLOCKED")
        If $$$ISOK(recSC) Set txn.DecisionId = rec.%Id()
        Do txn.%Save()
    } Else {
        Do ##class(Ens.Util.Log).LogWarning($classname(),"OnRequest","Transaction "_txnId_" no longer exists (reseeded?) - audit record only")
    }

    // ── Resolve the review case ─────────────────────────────
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT ID FROM PaymentGuard_Data.CaseRecord WHERE TxnId = ? AND Type = 'REVIEW' AND Status = 'OPEN'")
    If $$$ISOK(tSC) {
        Set tRS = tStmt.%Execute(txnId)
        While tRS.%Next() {
            Set c = ##class(PaymentGuard.Data.CaseRecord).%OpenId(tRS.%Get("ID"), 4)
            If '$IsObject(c) Continue
            Set c.Status = "RESOLVED"
            Set c.Resolution = finalAction
            Set c.ResolvedBy = reviewer
            Set c.ResolvedAt = $ZDATETIME($HOROLOG, 3, 1)
            Do c.%Save()
        }
    }

    Do ##class(Ens.Util.Log).LogInfo($classname(),"OnRequest","Human final review txn="_txnId_" action="_pRequest.HumanAction_" by="_reviewer_" -> "_finalAction)
    Quit $$$OK
}

/// Push a finalization request into this process from outside the production
/// (the REST decide endpoint, or the test suite). Uses the same entry the
/// REST dispatch uses, so the finalization shows up in the message trace.
ClassMethod SubmitFinalization(pReq As PaymentGuard.Request.ReviewFinalization, pTimeout As %Integer = 30) As %Status
{
    Set sc = ##class(Ens.Director).CreateBusinessService("PaymentGuard REST", .tBS)
    If $$$ISERR(sc) Quit sc
    Set resp = ""
    Quit tBS.SendRequestSync("PaymentGuard Review Finalizer", pReq, .resp, pTimeout)
}

}
