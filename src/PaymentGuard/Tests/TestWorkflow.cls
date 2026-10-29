Include (%occStatus)

/// Native Workflow Engine integration: a REVIEW decision opens a workflow task
/// for the human role; completing the task (Approve/Reject — exactly what the
/// /reviews/decide endpoint does) delivers a TaskResponse back to the Decision
/// BP, which finalizes the transaction, appends a HUMAN audit record and
/// resolves the review case. Runs fully offline via the mock agent engine.
Class PaymentGuard.Tests.TestWorkflow Extends %UnitTest.TestCase
{

Method OnBeforeAllTests() As %Status
{
    Set ^PaymentGuardSettings("MockMode") = 1
    Set tSC = ##class(PaymentGuard.Util.Setup).ResetDemo()
    If $$$ISERR(tSC) Quit tSC
    Quit ##class(PaymentGuard.Util.Setup).EnsureWorkflow()
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

/// A gray-zone payment the mock engine scores at exactly 45 (elevated amount +
/// unknown device) — a deterministic REVIEW decision.
ClassMethod ReviewRequest() As PaymentGuard.Request.Payment
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "cust_wf_001"
    Set req.Amount = 600
    Set req.GeoCountry = "SG"
    Set req.DeviceId = "dev_wf_"_$Increment(^PaymentGuardUnitTestSeq)
    Set req.Merchant = "GadgetWorld"
    Quit req
}

/// Find the open workflow task whose payload references txnId (polls: the
/// task is created asynchronously right after the REVIEW reply).
ClassMethod FindOpenTask(pTxnId As %String, pSeconds As %Integer = 10) As EnsLib.Workflow.TaskResponse
{
    For attempt = 1:1:pSeconds {
        Set found = ""
        Set tStmt = ##class(%SQL.Statement).%New()
        Do tStmt.%Prepare("SELECT TOP 50 ID FROM EnsLib_Workflow.TaskResponse ORDER BY ID DESC")
        Set tRS = tStmt.%Execute()
        While tRS.%Next() {
            Set t = ##class(EnsLib.Workflow.TaskResponse).%OpenId(tRS.%Get("ID"))
            If '$IsObject(t) Continue
            If t.%TaskStatus.IsComplete Continue
            If $Find(t.%Message, pTxnId) Set found = t Quit
        }
        If $IsObject(found) Quit
        Hang 1
    }
    Quit found
}

/// Mirror of the /reviews/decide endpoint finalization: parse the task
/// payload and push the ReviewFinalization request into the production.
ClassMethod SubmitFinalization(pTask As EnsLib.Workflow.TaskResponse, pAction As %String, pTxnId As %String) As %Status
{
    Set info = ##class(%DynamicObject).%FromJSON(pTask.%Message)
    Set fin = ##class(PaymentGuard.Request.ReviewFinalization).%New()
    Set fin.TxnId = pTxnId
    Set fin.CustomerId = info.%Get("customer_id")
    Set fin.Amount = info.%Get("amount")
    Set fin.Currency = info.%Get("currency")
    Set fin.Action = $Select(pAction = "Approve": "APPROVE", 1: "BLOCK")
    Set fin.HumanAction = pAction
    Set fin.Reviewer = pTask.%UserName
    Set fin.RiskScore = info.%Get("risk_score")
    Set fin.Summary = info.%Get("summary")
    Set fin.OriginSource = info.%Get("source")
    Set fin.WorkflowTaskId = pTask.%Id()
    Quit ##class(PaymentGuard.Interop.FinalizeBP).SubmitFinalization(fin)
}

/// Poll until the transaction reaches the expected status, "" on timeout.
ClassMethod WaitForStatus(pTxnId As %String, pStatus As %String, pSeconds As %Integer = 15) As %Boolean
{
    Set done = 0
    For attempt = 1:1:pSeconds {
        Set txn = ##class(PaymentGuard.Data.Transaction).OpenByTxnId(pTxnId)
        Set done = $IsObject(txn) && (txn.Status = pStatus)
        If done Quit
        Hang 1
    }
    Quit done
}

Method TestReviewOpensWorkflowTask()
{
    Set sc = ..Submit(..ReviewRequest(), .resp)
    Do $$$AssertStatusOK(sc)
    Do $$$AssertEquals(resp.Action, "REVIEW", "gray-zone payment goes to review")
    Do $$$AssertTrue($Find(resp.ReasonCodes, "elevated_amount") > 0 || $Find(resp.ReasonCodes, "unknown_device") > 0, "mock gray-zone reasons present")

    Set task = ..FindOpenTask(resp.TxnId)
    Do $$$AssertTrue($IsObject(task), "workflow task opened for the REVIEW decision")
    Quit:'$IsObject(task)
    Do $$$AssertEquals(task.%Actions, "Approve,Reject", "task offers the two human actions")
    Do $$$AssertTrue(task.%Priority >= 1 && task.%Priority <= 3, "task priority set")
    Set info = ##class(%DynamicObject).%FromJSON(task.%Message)
    Do $$$AssertEquals(info.%Get("txn_id"), resp.TxnId, "task payload carries the transaction")
    Do $$$AssertTrue($IsObject(task.%TaskStatus.Role), "task belongs to the review role")
    Do $$$AssertEquals(task.%TaskStatus.Role.Name, "PaymentGuard Human Review", "role is the workflow operation config name")

    Set txn = ##class(PaymentGuard.Data.Transaction).OpenByTxnId(resp.TxnId)
    Do $$$AssertEquals(txn.Status, "REVIEW", "transaction parked in REVIEW awaiting the human")
}

Method TestApproveFinalizesSettlement()
{
    Set sc = ..Submit(..ReviewRequest(), .resp)
    Do $$$AssertStatusOK(sc)
    Set task = ..FindOpenTask(resp.TxnId)
    Do $$$AssertTrue($IsObject(task), "task opened for the REVIEW decision")
    Quit:'$IsObject(task)

    // Same path as the /reviews/decide endpoint: claim then complete
    If task.%TaskStatus.AssignedTo = "" {
        Set sc = task.AssignTask("RiskAnalyst", .cnt)
        Do $$$AssertStatusOK(sc)
    }
    Set sc = task.CompleteTask("Approve")
    Do $$$AssertStatusOK(sc)

    // Finalization runs inside the production, same call the endpoint makes
    Do $$$AssertStatusOK(..SubmitFinalization(task, "Approve", resp.TxnId))
    Do $$$AssertTrue(..WaitForStatus(resp.TxnId, "SETTLED"), "approved review settles the transaction")

    // HUMAN audit record appended by OnResponse
    Set tStmt = ##class(%SQL.Statement).%New()
    Do tStmt.%Prepare("SELECT Action, Source, ReviewedBy FROM PaymentGuard_Data.Decision WHERE TxnId = ? AND Source = 'HUMAN'")
    Set tRS = tStmt.%Execute(resp.TxnId)
    Do $$$AssertTrue(tRS.%Next(), "human final decision audited")
    Do $$$AssertEquals(tRS.%Get("Action"), "APPROVE", "final action is APPROVE")
    Do $$$AssertEquals(tRS.%Get("ReviewedBy"), "RiskAnalyst", "reviewer recorded")

    // Review case resolved
    Do tStmt.%Prepare("SELECT Status, Resolution, ResolvedBy FROM PaymentGuard_Data.CaseRecord WHERE TxnId = ? AND Type = 'REVIEW'")
    Set tRS = tStmt.%Execute(resp.TxnId)
    Do $$$AssertTrue(tRS.%Next(), "review case exists")
    Do $$$AssertEquals(tRS.%Get("Status"), "RESOLVED", "case resolved")
    Do $$$AssertEquals(tRS.%Get("Resolution"), "APPROVE", "resolution recorded")
    Do $$$AssertEquals(tRS.%Get("ResolvedBy"), "RiskAnalyst", "resolver recorded")
}

Method TestRejectFinalizesBlock()
{
    Set sc = ..Submit(..ReviewRequest(), .resp)
    Do $$$AssertStatusOK(sc)
    Set task = ..FindOpenTask(resp.TxnId)
    Do $$$AssertTrue($IsObject(task), "task opened for the REVIEW decision")
    Quit:'$IsObject(task)

    If task.%TaskStatus.AssignedTo = "" {
        Do task.AssignTask("RiskAnalyst", .cnt)
    }
    Set sc = task.CompleteTask("Reject")
    Do $$$AssertStatusOK(sc)

    Do $$$AssertStatusOK(..SubmitFinalization(task, "Reject", resp.TxnId))
    Do $$$AssertTrue(..WaitForStatus(resp.TxnId, "BLOCKED"), "rejected review blocks the transaction")

    Set tStmt = ##class(%SQL.Statement).%New()
    Do tStmt.%Prepare("SELECT Action, ReviewedBy FROM PaymentGuard_Data.Decision WHERE TxnId = ? AND Source = 'HUMAN'")
    Set tRS = tStmt.%Execute(resp.TxnId)
    Do $$$AssertTrue(tRS.%Next(), "human final decision audited")
    Do $$$AssertEquals(tRS.%Get("Action"), "BLOCK", "final action is BLOCK")

    // The fraud alert side of the final routing
    Do tStmt.%Prepare("SELECT COUNT(*) AS C FROM PaymentGuard_Data.CaseRecord WHERE TxnId = ? AND Type = 'ALERT'")
    Set tRS = tStmt.%Execute(resp.TxnId)
    Do tRS.%Next()
    Do $$$AssertTrue(tRS.%Get("C") > 0, "rejected payment raised a fraud alert case")
}

}
