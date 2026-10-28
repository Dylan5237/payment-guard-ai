Include (%occStatus)

/// REST API for PaymentGuard. Mounted at /paymentguard/api by the module.
/// Unauthenticated on purpose for the demo; see README for production notes.
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
  <Route Url="/decisions" Method="GET" Call="ListDecisions"/>
  <Route Url="/cases" Method="GET" Call="ListCases"/>
  <Route Url="/stats" Method="GET" Call="Stats"/>
  <Route Url="/admin/reseed" Method="POST" Call="Reseed"/>
  <!-- .csp-suffixed twins: the Web Gateway's Apache module only intercepts
       requests whose path carries a listed file extension, so the gateway
       rewrites extensionless REST URLs to *.csp before they reach IRIS -->
  <Route Url="/health.csp" Method="GET" Call="Health"/>
  <Route Url="/payments.csp" Method="POST" Call="CreatePayment"/>
  <Route Url="/payments/batch.csp" Method="POST" Call="BatchPayments"/>
  <Route Url="/claims.csp" Method="POST" Call="CreateClaim"/>
  <Route Url="/transactions.csp" Method="GET" Call="ListTransactions"/>
  <Route Url="/decisions.csp" Method="GET" Call="ListDecisions"/>
  <Route Url="/cases.csp" Method="GET" Call="ListCases"/>
  <Route Url="/stats.csp" Method="GET" Call="Stats"/>
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

/// Recent decisions with full observability detail
ClassMethod ListDecisions() As %Status
{
    Set limit = +(%request.Data("limit", 1))
    If limit < 1 Set limit = 20
    If limit > 200 Set limit = 200
    Set arr = []
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT TOP ? TxnId, CustomerId, Amount, Action, Source, RiskScore, Confidence, ReasonCodes, Summary, Model, SessionId, PromptTokens, CompletionTokens, ToolCalls, LatencyMs, CreatedAt FROM PaymentGuard_Data.Decision ORDER BY ID DESC")
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
    Set tSC = tStmt.%Prepare("SELECT TOP ? CaseId, TxnId, CustomerId, Type, Priority, RiskScore, Status, Summary, CreatedAt FROM PaymentGuard_Data.CaseRecord ORDER BY ID DESC")
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
        Do row.%Set("summary", tRS.%Get("Summary"))
        Do row.%Set("created_at", tRS.%Get("CreatedAt"))
        Do arr.%Push(row)
    }
    Quit ..WriteJSON({"cases": (arr)})
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
    Set tSC = tStmt.%Prepare("SELECT COUNT(*) AS Cnt, COALESCE(SUM(PromptTokens),0) AS PTok, COALESCE(SUM(CompletionTokens),0) AS CTok, COALESCE(AVG(LatencyMs),0) AS Lat, COALESCE(AVG(RiskScore),0) AS Risk FROM PaymentGuard_Data.Decision")
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

/// Reseed demo data
ClassMethod Reseed() As %Status
{
    Set sc = ##class(PaymentGuard.Data.Populate).Seed(1)
    If $$$ISERR(sc) Quit ..WriteError(500, $System.Status.GetErrorText(sc))
    Quit ..WriteJSON({"reseeded": (1)})
}

}
