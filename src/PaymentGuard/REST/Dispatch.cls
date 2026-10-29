Include (%occStatus)

/// REST API for PaymentGuard. Mounted at /paymentguard/api by the module.
/// Decision and inspection endpoints are unauthenticated on purpose for the
/// demo; admin endpoints (/admin/*) require the X-Admin-Token shared secret.
/// See README and OPERATIONS.md for production notes.
Class PaymentGuard.REST.Dispatch Extends %CSP.REST
{

Parameter CHARSET = "utf-8";

Parameter CONTENTTYPE = "application/json";

Parameter HandleCorsRequest = 1;

Parameter DECISIONTARGET = "PaymentGuard Decision";

Parameter BSTARGET = "PaymentGuard REST";

XData UrlMap
{
<Routes>
  <Route Url="/health" Method="GET" Call="Health"/>
  <Route Url="/payments" Method="POST" Call="CreatePayment"/>
  <Route Url="/payments/batch" Method="POST" Call="BatchPayments"/>
  <Route Url="/claims" Method="POST" Call="CreateClaim"/>
  <Route Url="/transactions" Method="GET" Call="ListTransactions"/>
  <Route Url="/similar" Method="GET" Call="SimilarTransactions"/>
  <Route Url="/trace" Method="GET" Call="Trace"/>
  <Route Url="/messages" Method="GET" Call="Messages"/>
  <Route Url="/reasoning" Method="GET" Call="Reasoning"/>
  <Route Url="/decisions" Method="GET" Call="ListDecisions"/>
  <Route Url="/cases" Method="GET" Call="ListCases"/>
  <Route Url="/reviews" Method="GET" Call="ListReviews"/>
  <Route Url="/reviews/decide" Method="POST" Call="DecideReview"/>
  <Route Url="/stats" Method="GET" Call="Stats"/>
  <Route Url="/admin/model" Method="GET" Call="GetModelSettings"/>
  <Route Url="/admin/model" Method="PUT" Call="PutModelSettings"/>
  <Route Url="/admin/reseed" Method="POST" Call="Reseed"/>
  <!-- .csp-suffixed twins: the Web Gateway's Apache module only intercepts
       requests whose path carries a listed file extension, so the gateway
       rewrites extensionless REST URLs to *.csp before they reach IRIS -->
  <Route Url="/health.csp" Method="GET" Call="Health"/>
  <Route Url="/payments.csp" Method="POST" Call="CreatePayment"/>
  <Route Url="/payments/batch.csp" Method="POST" Call="BatchPayments"/>
  <Route Url="/claims.csp" Method="POST" Call="CreateClaim"/>
  <Route Url="/transactions.csp" Method="GET" Call="ListTransactions"/>
  <Route Url="/similar.csp" Method="GET" Call="SimilarTransactions"/>
  <Route Url="/trace.csp" Method="GET" Call="Trace"/>
  <Route Url="/messages.csp" Method="GET" Call="Messages"/>
  <Route Url="/reasoning.csp" Method="GET" Call="Reasoning"/>
  <Route Url="/decisions.csp" Method="GET" Call="ListDecisions"/>
  <Route Url="/cases.csp" Method="GET" Call="ListCases"/>
  <Route Url="/reviews.csp" Method="GET" Call="ListReviews"/>
  <Route Url="/reviews/decide.csp" Method="POST" Call="DecideReview"/>
  <Route Url="/stats.csp" Method="GET" Call="Stats"/>
  <Route Url="/admin/model.csp" Method="GET" Call="GetModelSettings"/>
  <Route Url="/admin/model.csp" Method="PUT" Call="PutModelSettings"/>
  <Route Url="/admin/reseed.csp" Method="POST" Call="Reseed"/>
</Routes>
}

/// ── helpers ─────────────────────────────────────────────────

ClassMethod ReadBody() As %DynamicObject
{
    Set text = ""
    If $IsObject(%request.Content) {
        While '%request.Content.AtEnd {
            Set text = text_%request.Content.Read(32000)
        }
    }
    If text = "" Quit ""
    Set text = $ZConvert(text, "I", "UTF8")
    Try {
        Return ##class(%DynamicObject).%FromJSON(text)
    } Catch ex {
        Return ""
    }
}

ClassMethod WriteJSON(pObj As %DynamicObject, pStatus As %Integer = 200) As %Status
{
    Set %response.Status = pStatus
    Write pObj.%ToJSON()
    Quit $$$OK
}

ClassMethod WriteError(pStatus As %Integer, pMsg As %String) As %Status
{
    Set %response.Status = pStatus
    Write {"error": (pMsg)}.%ToJSON()
    Quit $$$OK
}

/// Get a handle to the entry business service, self-healing: if the
/// production is not running (e.g. fresh container, no auto-start yet),
/// start it and retry once.
ClassMethod GetBusinessService(Output pBS) As %Status
{
    Set pSC = ##class(Ens.Director).CreateBusinessService(..#BSTARGET, .pBS)
    If $$$ISOK(pSC) Quit pSC
    Do ##class(PaymentGuard.Util.Setup).EnsureRunning()
    Hang 2
    Quit ##class(Ens.Director).CreateBusinessService(..#BSTARGET, .pBS)
}

/// Submit one payment request through the production; pTimeout leaves room
/// for the LLM to answer on live agent mode.
ClassMethod SubmitPayment(pReq As PaymentGuard.Request.Payment, Output pResp As PaymentGuard.Response.Decision, Output pSC As %Status) As %Boolean
{
    Set pSC = ..GetBusinessService(.tBS)
    If $$$ISERR(pSC) Quit 0
    Set pSC = tBS.SendRequestSync(..#DECISIONTARGET, pReq, .pResp, 120)
    Quit $$$ISOK(pSC)
}

/// ── endpoints ───────────────────────────────────────────────

/// Liveness + configuration snapshot
ClassMethod Health() As %Status
{
    Set sc = ##class(Ens.Director).CreateBusinessService(..#BSTARGET, .tBS)
    Set key = ##class(PaymentGuard.Util.Config).APIKey()
    Set o = {}
    Do o.%Set("app", "paymentguard")
    Do o.%Set("production_running", $$$ISOK(sc), "boolean")
    Do o.%Set("provider", ##class(PaymentGuard.Util.Config).ProviderName())
    Do o.%Set("model", ##class(PaymentGuard.Util.Config).ModelName())
    Do o.%Set("api_key_present", key '= "", "boolean")
    Do o.%Set("agent_mode", $Select(##class(PaymentGuard.Util.Config).MockRequested(): "mock", 1: "live"))
    Quit ..WriteJSON(o)
}

/// Authorize one payment
ClassMethod CreatePayment() As %Status
{
    Set body = ..ReadBody()
    If '$IsObject(body) Quit ..WriteError(400, "Invalid or missing JSON body")
    If body.%Get("customer_id") = "" Quit ..WriteError(400, "customer_id is required")
    If (+body.%Get("amount")) <= 0 Quit ..WriteError(400, "amount must be a positive number")

    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.TxnId = body.%Get("txn_id")
    Set req.CustomerId = body.%Get("customer_id")
    Set req.Amount = +body.%Get("amount")
    Set req.Currency = $Select(body.%Get("currency") '="": body.%Get("currency"), 1: "USD")
    Set req.Merchant = body.%Get("merchant")
    Set req.MerchantCategory = body.%Get("merchant_category")
    Set req.Channel = body.%Get("channel")
    Set req.GeoCountry = body.%Get("geo_country")
    Set req.DeviceId = body.%Get("device_id")
    Set req.TxnTime = body.%Get("txn_time")

    If '..SubmitPayment(req, .resp, .sc) {
        Quit ..WriteError(503, "Production call failed - is the PaymentGuard production running? "_$System.Status.GetErrorText(sc))
    }
    Quit ..WriteJSON(resp.ToAPIJSON(), 201)
}

/// Map a health-insurance claim body onto the standard payment request:
/// member -> customer, provider -> merchant, plus procedure/diagnosis/city.
/// The claim then flows through the exact same decision and audit pipeline.
ClassMethod ClaimToPayment(pBody As %DynamicObject) As PaymentGuard.Request.Payment
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.TxnId = pBody.%Get("claim_id")
    Set req.CustomerId = pBody.%Get("member_id")
    Set req.Amount = +pBody.%Get("amount")
    Set req.Currency = $Select(pBody.%Get("currency") '="": pBody.%Get("currency"), 1: "CNY")
    Set req.Merchant = pBody.%Get("provider")
    Set req.MerchantCategory = "HEALTHCARE"
    Set req.Procedure = pBody.%Get("procedure")
    Set req.Diagnosis = pBody.%Get("diagnosis")
    Set req.City = pBody.%Get("city")
    Set req.GeoCountry = $Select(pBody.%Get("geo_country") '="": pBody.%Get("geo_country"), 1: "CN")
    Set req.TxnTime = pBody.%Get("claim_time")
    Quit req
}

/// Submit one health-insurance claim settlement for a decision
ClassMethod CreateClaim() As %Status
{
    Set body = ..ReadBody()
    If '$IsObject(body) Quit ..WriteError(400, "Invalid or missing JSON body")
    If body.%Get("member_id") = "" Quit ..WriteError(400, "member_id is required")
    If (+body.%Get("amount")) <= 0 Quit ..WriteError(400, "amount must be a positive number")

    Set req = ..ClaimToPayment(body)
    If '..SubmitPayment(req, .resp, .sc) {
        Quit ..WriteError(503, "Production call failed - is the PaymentGuard production running? "_$System.Status.GetErrorText(sc))
    }
    Quit ..WriteJSON(resp.ToAPIJSON(), 201)
}

/// Generate and submit a batch of demo payments (count in body, max 25)
ClassMethod BatchPayments() As %Status
{
    Set body = ..ReadBody()
    Set count = $Select($IsObject(body): +body.%Get("count"), 1: 5)
    If count < 1 Set count = 1
    If count > 25 Set count = 25

    Set results = []
    For i = 1:1:count {
        Set req = ##class(PaymentGuard.Data.Populate).GenTxn()
        If '..SubmitPayment(req, .resp, .sc) {
            Do results.%Push({"txn_id": (req.TxnId), "error": ($System.Status.GetErrorText($Get(sc, $$$ERROR($$$GeneralError, "production call failed"))))})
            Continue
        }
        Set o = {}
        Do o.%Set("txn_id", resp.TxnId)
        Do o.%Set("customer_id", req.CustomerId)
        Do o.%Set("amount", req.Amount)
        Do o.%Set("action", resp.Action)
        Do o.%Set("source", resp.Source)
        Do o.%Set("risk_score", resp.RiskScore)
        Do o.%Set("model", resp.Model)
        Do results.%Push(o)
    }
    Quit ..WriteJSON({"submitted": (count), "results": (results)})
}

/// Recent transactions
ClassMethod ListTransactions() As %Status
{
    Set limit = +(%request.Data("limit", 1))
    If limit < 1 Set limit = 20
    If limit > 200 Set limit = 200
    Set arr = []
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT TOP ? TxnId, CustomerId, Amount, Currency, Merchant, GeoCountry, Channel, Status, TxnTime FROM PaymentGuard_Data.""Transaction"" ORDER BY ID DESC")
    If $$$ISERR(tSC) Quit ..WriteError(500, $System.Status.GetErrorText(tSC))
    Set tRS = tStmt.%Execute(limit)
    While tRS.%Next() {
        Set row = {}
        Do row.%Set("txn_id", tRS.%Get("TxnId"))
        Do row.%Set("customer_id", tRS.%Get("CustomerId"))
        Do row.%Set("amount", tRS.%Get("Amount"))
        Do row.%Set("currency", tRS.%Get("Currency"))
        Do row.%Set("merchant", tRS.%Get("Merchant"))
        Do row.%Set("geo_country", tRS.%Get("GeoCountry"))
        Do row.%Set("channel", tRS.%Get("Channel"))
        Do row.%Set("status", tRS.%Get("Status"))
        Do row.%Set("time", tRS.%Get("TxnTime"))
        Do arr.%Push(row)
    }
    Quit ..WriteJSON({"transactions": (arr)})
}

/// Semantic nearest neighbors of a stored transaction: IRIS Vector Search
/// (cosine) over Embedded-Python feature embeddings. Demo/inspection helper
/// mirroring the agent tool.
ClassMethod SimilarTransactions() As %Status
{
    Set txnId = %request.Data("txn_id", 1)
    If txnId = "" Quit ..WriteError(400, "txn_id is required")
    Set limit = +(%request.Data("limit", 1))
    If limit < 1 Set limit = 5
    If limit > 25 Set limit = 25
    Set feat = ##class(PaymentGuard.Vector.Embedder).TxnFeatures(txnId)
    If feat = "" Quit ..WriteError(404, "transaction not found: "_txnId)
    Set results = ##class(PaymentGuard.Vector.Embedder).Search(feat, limit, 0.1, txnId)
    Quit ..WriteJSON({"query_txn_id": (txnId), "results": (results)})
}

/// The real interoperability message trace: every hop each request made
/// through the production, straight from Ens.MessageHeader — the same data
/// the Management Portal message viewer shows. Powers the flow-replay panel.
ClassMethod Trace() As %Status
{
    Set limit = +(%request.Data("limit", 1))
    If limit < 1 Set limit = 200
    If limit > 500 Set limit = 500
    Set arr = []
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT TOP ? ID, SessionId, SourceConfigName, TargetConfigName, TimeCreated, MessageBodyClassName FROM Ens.MessageHeader ORDER BY ID DESC")
    If $$$ISERR(tSC) Quit ..WriteError(500, $System.Status.GetErrorText(tSC))
    Set tRS = tStmt.%Execute(limit)
    While tRS.%Next() {
        Set row = {}
        Do row.%Set("id", tRS.%Get("ID"))
        Do row.%Set("session", tRS.%Get("SessionId"))
        Do row.%Set("source", tRS.%Get("SourceConfigName"))
        Do row.%Set("target", tRS.%Get("TargetConfigName"))
        Do row.%Set("time", tRS.%Get("TimeCreated"))
        Do row.%Set("body", tRS.%Get("MessageBodyClassName"))
        Do arr.%Push(row)
    }
    Quit ..WriteJSON({"now": ($ZDATETIME($HOROLOG, 3, 1)), "hops": (arr)})
}

/// Every message hop of one production session, with the actual message body
/// content — the same objects the Message Viewer shows. Session = Ens.MessageHeader
/// SessionId (the task queue in the dashboard carries it).
ClassMethod Messages() As %Status
{
    Set sid = %request.Data("session", 1)
    If sid = "" Quit ..WriteError(400, "session is required")
    Set arr = []
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT ID, SourceConfigName, TargetConfigName, TimeCreated, MessageBodyClassName, MessageBodyId FROM Ens.MessageHeader WHERE SessionId = ? ORDER BY ID ASC")
    If $$$ISERR(tSC) Quit ..WriteError(500, $System.Status.GetErrorText(tSC))
    Set tRS = tStmt.%Execute(sid)
    While tRS.%Next() {
        Set row = {}
        Do row.%Set("id", tRS.%Get("ID"))
        Do row.%Set("source", tRS.%Get("SourceConfigName"))
        Do row.%Set("target", tRS.%Get("TargetConfigName"))
        Do row.%Set("time", tRS.%Get("TimeCreated"))
        Set cls = tRS.%Get("MessageBodyClassName")
        Do row.%Set("body_class", cls)
        Set bodyJSON = ""
        If cls '= "" {
            Try {
                Set body = $CLASSMETHOD(cls, "%OpenId", tRS.%Get("MessageBodyId"))
                Set bodyJSON = ""
                If $IsObject(body) {
                    // %IsA("%JSON.Adaptor") is false in this EAP even for Adaptor
                    // subclasses — export and let the Catch handle the rest
                    Set bodySC = body.%JSONExportToString(.bodyJSON)
                    If $$$ISERR(bodySC) Set bodyJSON = "{""note"":""body not serializable""}"
                } Else {
                    Set bodyJSON = "{""note"":""body no longer available (purged)""}"
                }
            } Catch ex {
                Set bodyJSON = "{""note"":""body not serializable""}"
            }
        }
        Do row.%Set("body_json", bodyJSON)
        Do arr.%Push(row)
    }
    Quit ..WriteJSON({"session": (sid), "hops": (arr)})
}

/// The persisted AI Hub session behind a decision: the real message chain —
/// the context the agent saw, the tool calls it made, its final answer.
ClassMethod Reasoning() As %Status
{
    Set sid = %request.Data("session", 1)
    If sid = "" Quit ..WriteError(400, "session is required")
    Set sess = ##class(%AI.Agent.Session).%OpenId(sid)
    If '$IsObject(sess) Quit ..WriteError(404, "session not found: "_sid)
    Set msgs = []
    Set errText = ""
    Set st = sess.ContextData
    If $IsObject(st) {
        Try {
            Do st.Rewind()
            Set txt = ""
            While 'st.AtEnd { Set txt = txt_st.Read(60000) }
            Set o = ##class(%DynamicObject).%FromJSON(txt)
            Set raw = o.%Get("messages")
            If $IsObject(raw) {
                For i = 0:1:raw.%Size() - 1 {
                    Set m = raw.%Get(i)
                    Set out = {}
                    Do out.%Set("role", m.%Get("role"))
                    Set c = m.%Get("content")
                    If $IsObject(c) Set c = c.%ToJSON()
                    Do out.%Set("content", c)
                    Do msgs.%Push(out)
                }
            }
        } Catch ex {
            Set errText = ex.DisplayString()
        }
    }
    If errText '= "" Quit ..WriteError(500, "session parse failed: "_errText)
    Quit ..WriteJSON({"session": (sid), "model": (sess.Model), "created_at": (sess.CreatedAt), "messages": (msgs)})
}

/// Recent decisions with full observability detail
ClassMethod ListDecisions() As %Status
{
    Set limit = +(%request.Data("limit", 1))
    If limit < 1 Set limit = 20
    If limit > 200 Set limit = 200
    Set arr = []
    Set tStmt = ##class(%SQL.Statement).%New()
    Set sql = "SELECT TOP ? d.TxnId, d.CustomerId, d.Amount, d.Action, d.Source, d.RiskScore, d.Confidence, d.ReasonCodes, d.Summary, d.Model, d.SessionId, d.PromptTokens, d.CompletionTokens, d.ToolCalls, d.LatencyMs, d.ReviewedBy, d.CreatedAt, t.Merchant, t.GeoCountry FROM PaymentGuard_Data.Decision d LEFT JOIN PaymentGuard_Data.""Transaction"" t ON t.TxnId = d.TxnId ORDER BY d.ID DESC"
    Set tSC = tStmt.%Prepare(sql)
    If $$$ISERR(tSC) Quit ..WriteError(500, $System.Status.GetErrorText(tSC))
    Set tRS = tStmt.%Execute(limit)
    While tRS.%Next() {
        Set row = {}
        Do row.%Set("txn_id", tRS.%Get("TxnId"))
        Do row.%Set("customer_id", tRS.%Get("CustomerId"))
        Do row.%Set("amount", tRS.%Get("Amount"))
        Do row.%Set("action", tRS.%Get("Action"))
        Do row.%Set("source", tRS.%Get("Source"))
        Do row.%Set("risk_score", tRS.%Get("RiskScore"))
        Do row.%Set("confidence", tRS.%Get("Confidence"))
        Set reasons = []
        Set rcText = tRS.%Get("ReasonCodes")
        If rcText '= "" {
            Try {
                Set reasons = ##class(%DynamicArray).%FromJSON(rcText)
            } Catch ex {
                Set reasons = []
            }
        }
        Do row.%Set("reasons", reasons)
        Do row.%Set("summary", tRS.%Get("Summary"))
        Do row.%Set("model", tRS.%Get("Model"))
        Do row.%Set("session_id", tRS.%Get("SessionId"))
        Do row.%Set("prompt_tokens", tRS.%Get("PromptTokens"))
        Do row.%Set("completion_tokens", tRS.%Get("CompletionTokens"))
        Do row.%Set("tool_calls", tRS.%Get("ToolCalls"))
        Do row.%Set("latency_ms", tRS.%Get("LatencyMs"))
        Do row.%Set("merchant", tRS.%Get("Merchant"))
        Do row.%Set("geo_country", tRS.%Get("GeoCountry"))
        Do row.%Set("reviewed_by", tRS.%Get("ReviewedBy"))
        Do row.%Set("created_at", tRS.%Get("CreatedAt"))
        Do arr.%Push(row)
    }
    Quit ..WriteJSON({"decisions": (arr)})
}

/// Review cases and fraud alerts
ClassMethod ListCases() As %Status
{
    Set limit = +(%request.Data("limit", 1))
    If limit < 1 Set limit = 20
    If limit > 200 Set limit = 200
    Set arr = []
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT TOP ? CaseId, TxnId, CustomerId, Type, Priority, RiskScore, Status, Resolution, ResolvedBy, Summary, CreatedAt FROM PaymentGuard_Data.CaseRecord ORDER BY ID DESC")
    If $$$ISERR(tSC) Quit ..WriteError(500, $System.Status.GetErrorText(tSC))
    Set tRS = tStmt.%Execute(limit)
    While tRS.%Next() {
        Set row = {}
        Do row.%Set("case_id", tRS.%Get("CaseId"))
        Do row.%Set("txn_id", tRS.%Get("TxnId"))
        Do row.%Set("customer_id", tRS.%Get("CustomerId"))
        Do row.%Set("type", tRS.%Get("Type"))
        Do row.%Set("priority", tRS.%Get("Priority"))
        Do row.%Set("risk_score", tRS.%Get("RiskScore"))
        Do row.%Set("status", tRS.%Get("Status"))
        Do row.%Set("resolution", tRS.%Get("Resolution"))
        Do row.%Set("resolved_by", tRS.%Get("ResolvedBy"))
        Do row.%Set("summary", tRS.%Get("Summary"))
        Do row.%Set("created_at", tRS.%Get("CreatedAt"))
        Do arr.%Push(row)
    }
    Quit ..WriteJSON({"cases": (arr)})
}

/// Open human-review tasks from the native Workflow Engine (EnsLib.Workflow).
/// The task payload (%Message) carries the decision context; the analyst
/// actions each task via /reviews/decide.
ClassMethod ListReviews() As %Status
{
    Set limit = +(%request.Get("limit", 20))
    If limit < 1 Set limit = 20
    If limit > 100 Set limit = 100
    Set arr = []
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT TOP 200 ID FROM EnsLib_Workflow.TaskResponse ORDER BY ID DESC")
    If $$$ISERR(tSC) Quit ..WriteError(500, $System.Status.GetErrorText(tSC))
    Set tRS = tStmt.%Execute()
    While tRS.%Next() {
        If arr.%Size() >= limit Quit
        Set t = ##class(EnsLib.Workflow.TaskResponse).%OpenId(tRS.%Get("ID"))
        If '$IsObject(t) Continue
        If t.%TaskStatus.IsComplete Continue
        Set info = ""
        Try {
            Set info = ##class(%DynamicObject).%FromJSON(t.%Message)
        } Catch ex {
        }
        Set row = {}
        Do row.%Set("task_id", tRS.%Get("ID"))
        Do row.%Set("subject", t.%Subject)
        Do row.%Set("actions", t.%Actions)
        Do row.%Set("priority", t.%Priority)
        Do row.%Set("assigned_to", t.%TaskStatus.AssignedTo)
        If $IsObject(t.%TaskStatus.Role) Do row.%Set("role", t.%TaskStatus.Role.Name)
        Do row.%Set("time", t.%TaskStatus.TimeCreated)
        If $IsObject(info) {
            Do row.%Set("txn_id", info.%Get("txn_id"))
            Do row.%Set("customer_id", info.%Get("customer_id"))
            Do row.%Set("amount", info.%Get("amount"))
            Do row.%Set("currency", info.%Get("currency"))
            Do row.%Set("risk_score", info.%Get("risk_score"))
            Do row.%Set("summary", info.%Get("summary"))
            Do row.%Set("source", info.%Get("source"))
        }
        Do arr.%Push(row)
    }
    Quit ..WriteJSON({"reviews": (arr)})
}

/// Take a human-review action on one Workflow task: claim it for the reviewer
/// (if still unassigned) and complete it with Approve or Reject. The Workflow
/// Engine then delivers the TaskResponse back to the Decision BP, which
/// finalizes settlement or the fraud alert.
ClassMethod DecideReview() As %Status
{
    Set body = ..ReadBody()
    If '$IsObject(body) Quit ..WriteError(400, "Invalid or missing JSON body")
    Set taskId = body.%Get("task_id")
    Set action = body.%Get("action")
    Set reviewer = body.%Get("reviewer")
    If reviewer = "" Set reviewer = "RiskAnalyst"
    If taskId = "" Quit ..WriteError(400, "task_id is required")
    Set ok = (action = "Approve") || (action = "Reject")
    If 'ok Quit ..WriteError(400, "action must be Approve or Reject")

    Set t = ##class(EnsLib.Workflow.TaskResponse).%OpenId(taskId)
    If '$IsObject(t) Quit ..WriteError(404, "task not found: "_taskId)
    If t.%TaskStatus.IsComplete Quit ..WriteError(409, "task already completed")

    Set tSC = $$$OK
    If t.%TaskStatus.AssignedTo = "" {
        Set tSC = t.AssignTask(reviewer, .cnt)
        If $$$ISERR(tSC) Quit ..WriteError(400, "claim failed (unknown reviewer '"_reviewer_"'?): "_$System.Status.GetErrorText(tSC))
    } ElseIf t.%TaskStatus.AssignedTo '= reviewer {
        Quit ..WriteError(409, "task is owned by "_t.%TaskStatus.AssignedTo)
    }

    Set tSC = t.CompleteTask(action)
    If $$$ISERR(tSC) Quit ..WriteError(500, "complete failed: "_$System.Status.GetErrorText(tSC))

    // Push the final decision back into the production: the Review Finalizer
    // routes settlement/alert, appends the HUMAN audit record and resolves
    // the review case — all visible in the message trace.
    Set info = ""
    Try {
        Set info = ##class(%DynamicObject).%FromJSON(t.%Message)
    } Catch ex {
    }
    Set fin = ##class(PaymentGuard.Request.ReviewFinalization).%New()
    Set fin.TxnId = ""
    If $IsObject(info) Set fin.TxnId = info.%Get("txn_id")
    Set fin.CustomerId = $S($IsObject(info): info.%Get("customer_id"), 1: "")
    Set fin.Amount = $S($IsObject(info): info.%Get("amount"), 1: 0)
    Set fin.Currency = $S($IsObject(info): info.%Get("currency"), 1: "")
    Set fin.Action = $Select(action = "Approve": "APPROVE", 1: "BLOCK")
    Set fin.HumanAction = action
    Set fin.Reviewer = t.%UserName
    Set fin.RiskScore = $S($IsObject(info): info.%Get("risk_score"), 1: 0)
    Set fin.Summary = $S($IsObject(info): info.%Get("summary"), 1: "")
    Set fin.OriginSource = $S($IsObject(info): info.%Get("source"), 1: "")
    Set fin.WorkflowTaskId = taskId
    Set finSC = ##class(PaymentGuard.Interop.FinalizeBP).SubmitFinalization(fin)
    If $$$ISERR(finSC) Quit ..WriteError(500, "finalization failed: "_$System.Status.GetErrorText(finSC))

    Quit ..WriteJSON({"completed": (1), "task_id": (taskId), "action": (action), "reviewer": (t.%UserName), "final_action": (fin.Action)})
}

/// Aggregate stats for the dashboard
ClassMethod Stats() As %Status
{
    Set o = {}
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT Action, COUNT(*) AS Cnt FROM PaymentGuard_Data.Decision GROUP BY Action")
    If $$$ISOK(tSC) {
        Set tRS = tStmt.%Execute()
        While tRS.%Next() {
            Do o.%Set("action_"_tRS.%Get("Action")_"_count", tRS.%Get("Cnt"))
        }
    }
    Set tSC = tStmt.%Prepare("SELECT Source, COUNT(*) AS Cnt FROM PaymentGuard_Data.Decision GROUP BY Source")
    If $$$ISOK(tSC) {
        Set tRS = tStmt.%Execute()
        While tRS.%Next() {
            Do o.%Set("source_"_tRS.%Get("Source")_"_count", tRS.%Get("Cnt"))
        }
    }
    Set tSC = tStmt.%Prepare("SELECT COUNT(*) AS Cnt, COALESCE(SUM(PromptTokens),0) AS PTok, COALESCE(SUM(CompletionTokens),0) AS CTok, COALESCE(AVG(CASE WHEN LatencyMs > 0 THEN LatencyMs ELSE NULL END),0) AS Lat, COALESCE(AVG(RiskScore),0) AS Risk FROM PaymentGuard_Data.Decision")
    If $$$ISOK(tSC) {
        Set tRS = tStmt.%Execute()
        If tRS.%Next() {
            Do o.%Set("decision_count", tRS.%Get("Cnt"))
            Do o.%Set("prompt_tokens_total", tRS.%Get("PTok"))
            Do o.%Set("completion_tokens_total", tRS.%Get("CTok"))
            Do o.%Set("avg_latency_ms", tRS.%Get("Lat"))
            Do o.%Set("avg_risk_score", tRS.%Get("Risk"))
        }
    }
    Set tSC = tStmt.%Prepare("SELECT Type, COUNT(*) AS Cnt FROM PaymentGuard_Data.CaseRecord GROUP BY Type")
    If $$$ISOK(tSC) {
        Set tRS = tStmt.%Execute()
        While tRS.%Next() {
            Do o.%Set("cases_"_tRS.%Get("Type")_"_count", tRS.%Get("Cnt"))
        }
    }
    Quit ..WriteJSON(o)
}

/// Reseed demo data. Stops the production first: wiping tables while
/// requests are in flight poisons the shutdown state and wedges every
/// subsequent start (ErrProductionNotShutdownCleanly).
ClassMethod Reseed() As %Status
{
    Set token = ##class(PaymentGuard.Util.Config).AdminToken()
    If token = "" Quit ..WriteError(503, "No admin token configured - set ADMIN_TOKEN in .env (or ^PaymentGuardSettings(""AdminToken"")) before calling admin endpoints")
    If %request.GetCgiEnv("HTTP_X_ADMIN_TOKEN") '= token Quit ..WriteError(401, "Invalid or missing X-Admin-Token header")
    Set sc = ##class(PaymentGuard.Util.Setup).ResetDemo()
    If $$$ISERR(sc) Quit ..WriteError(500, $System.Status.GetErrorText(sc))
    Quit ..WriteJSON({"reseeded": (1)})
}

/// ── admin ───────────────────────────────────────────────────

/// Effective model configuration and where each value comes from. The API key
/// itself is never returned — only whether one is configured.
ClassMethod GetModelSettings() As %Status
{
    Set o = {}
    Do o.%Set("provider", ##class(PaymentGuard.Util.Config).ProviderName())
    Do o.%Set("provider_source", ##class(PaymentGuard.Util.Config).ProviderSource())
    Do o.%Set("model", ##class(PaymentGuard.Util.Config).ModelName())
    Do o.%Set("model_source", ##class(PaymentGuard.Util.Config).ModelSource())
    Do o.%Set("base_url", ##class(PaymentGuard.Util.Config).BaseUrl())
    Do o.%Set("base_url_source", ##class(PaymentGuard.Util.Config).BaseUrlSource())
    Do o.%Set("api_key_present", ##class(PaymentGuard.Util.Config).APIKey() '= "", "boolean")
    Do o.%Set("api_key_source", ##class(PaymentGuard.Util.Config).APIKeySource())
    Do o.%Set("agent_mode", $Select(##class(PaymentGuard.Util.Config).MockRequested(): "mock", 1: "live"))
    Quit ..WriteJSON(o)
}

/// Update model configuration at runtime. Each field is optional: a non-empty
/// value sets the runtime override, an explicit empty string clears it (the
/// setting falls back to its env/default). "mock": true/false flips the agent
/// between the deterministic mock engine and the live LLM. Changes apply to
/// the next decision — no restart needed.
ClassMethod PutModelSettings() As %Status
{
    Set token = ##class(PaymentGuard.Util.Config).AdminToken()
    If token = "" Quit ..WriteError(503, "No admin token configured - set ADMIN_TOKEN in .env (or ^PaymentGuardSettings(""AdminToken"")) before calling admin endpoints")
    If %request.GetCgiEnv("HTTP_X_ADMIN_TOKEN") '= token Quit ..WriteError(401, "Invalid or missing X-Admin-Token header")
    Set body = ..ReadBody()
    If '$IsObject(body) Quit ..WriteError(400, "Invalid or missing JSON body")

    If body.%Get("provider", $Char(0)) '= $Char(0) {
        Set v = body.%Get("provider")
        If v = "" {
            Kill ^PaymentGuardSettings("Provider")
        } Else {
            Set ^PaymentGuardSettings("Provider") = v
        }
    }
    If body.%Get("model", $Char(0)) '= $Char(0) {
        Set v = body.%Get("model")
        If v = "" {
            Kill ^PaymentGuardSettings("Model")
        } Else {
            Set ^PaymentGuardSettings("Model") = v
        }
    }
    If body.%Get("base_url", $Char(0)) '= $Char(0) {
        Set v = body.%Get("base_url")
        If v = "" {
            Kill ^PaymentGuardSettings("BaseUrl")
        } Else {
            Set ^PaymentGuardSettings("BaseUrl") = v
        }
    }
    If body.%Get("api_key", $Char(0)) '= $Char(0) {
        Set v = body.%Get("api_key")
        If v = "" {
            Kill ^PaymentGuardSettings("APIKey")
        } Else {
            Set ^PaymentGuardSettings("APIKey") = v
        }
    }
    If body.%Get("mock", $Char(0)) '= $Char(0) {
        If body.%Get("mock") = 1 {
            Set ^PaymentGuardSettings("MockMode") = 1
        } Else {
            Kill ^PaymentGuardSettings("MockMode")
        }
    }
    Quit ..GetModelSettings()
}

}
