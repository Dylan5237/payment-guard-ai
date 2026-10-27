Include (%occStatus)

/// The decision orchestrator of the PaymentGuard production.
///
/// Flow for every inbound payment:
///   1. Persist the attempt (PENDING)
///   2. Enrich: customer profile, velocity, device and merchant intelligence
///   3. Deterministic rules: hard blocks and the trusted fast path never
///      reach the LLM; only the gray zone does
///   4. Gray zone: ask the AI Risk Agent operation (AI Hub agent with SQL
///      tools); any agent failure or malformed answer degrades to a fail-safe
///      human REVIEW — an AI outage never blocks revenue and never approves
///      silently
///   5. Route the outcome: settlement, human review queue or fraud alert
///   6. Persist an immutable decision audit record with full agent cost data
Class PaymentGuard.Interop.DecisionBP Extends Ens.BusinessProcess
{

Parameter AGENTTARGET = "PaymentGuard AI Risk Agent";

Parameter SETTLETARGET = "PaymentGuard Settlement";

Parameter REVIEWTARGET = "PaymentGuard Review Queue";

Parameter ALERTTARGET = "PaymentGuard Fraud Alerts";

Method OnRequest(pRequest As PaymentGuard.Request.Payment, Output pResponse As PaymentGuard.Response.Decision) As %Status
{
    Set tSC = $$$OK
    Set pResponse = ##class(PaymentGuard.Response.Decision).%New()

    // Decision variables
    Set action = "REVIEW", source = "FALLBACK", riskScore = 50, confidence = 0.5
    Set reasonCodes = "[]", summary = "", model = "", sessionId = ""
    Set promptTokens = 0, completionTokens = 0, latencyMs = 0
    Set aResp = ""

    // ── 1. Persist the attempt ────────────────────────────────
    Set txn = ##class(PaymentGuard.Data.Transaction).%New()
    Set txn.TxnId = $Select(pRequest.TxnId '="": pRequest.TxnId, 1: "txn_"_$Piece($Horolog,",",1)_$Piece($Horolog,",",2)_"_"_$RANDOM(999999))
    Set txn.CustomerId = pRequest.CustomerId
    Set txn.Amount = pRequest.Amount
    Set txn.Currency = $Select(pRequest.Currency '="": pRequest.Currency, 1: "USD")
    Set txn.Merchant = pRequest.Merchant
    Set txn.MerchantCategory = pRequest.MerchantCategory
    Set txn.Channel = pRequest.Channel
    Set txn.GeoCountry = pRequest.GeoCountry
    Set txn.DeviceId = pRequest.DeviceId
    Set txn.TxnTime = ..ParseTime(pRequest.TxnTime)
    Set tSC = txn.%Save()
    If $$$ISERR(tSC) Quit tSC
    Set txnId = txn.TxnId

    // ── 2. Enrich ─────────────────────────────────────────────
    Set cust = ##class(PaymentGuard.Data.Customer).OpenByCustomerId(pRequest.CustomerId)
    Set ctx = ##class(PaymentGuard.Data.Enricher).BuildContext(pRequest, cust)
    Do ctx.%Set("payment", ..PaymentJSON(pRequest, txnId))

    // ── 3. Deterministic rules ────────────────────────────────
    Set ruleName = "", ruleReason = ""
    Set ruleResult = ##class(PaymentGuard.Rules.RuleEngine).Evaluate(pRequest, ctx, .ruleName, .ruleReason)

    If (ruleResult = "BLOCK") || (ruleResult = "APPROVE") {
        Set action = ruleResult
        Set source = "RULES"
        Set riskScore = $Select(ruleResult = "BLOCK": 90, 1: 10)
        Set confidence = 1.0
        Set reasonCodes = ##class(%DynamicArray).%New()
        Do reasonCodes.%Push(ruleName)
        Set summary = ruleReason
        Set model = ""
        Do ##class(Ens.Util.Log).LogInfo($classname(),"OnRequest","Rules decided txn="_txnId_" action="_action_" rule="_ruleName)
    } Else {

        // ── 4. Gray zone: the AI Hub agent decides ────────────
        Set aReq = ##class(PaymentGuard.Request.AgentDecision).%New()
        Set aReq.TxnId = txnId
        Set aReq.ContextJSON = ctx.%ToJSON()

        Set aResp = ""
        Set agentSC = ..SendRequestSync(..#AGENTTARGET, aReq, .aResp)

        If $$$ISERR(agentSC) || '$IsObject(aResp) {
            Set action = "REVIEW"
            Set source = "FALLBACK"
            Set riskScore = 60
            Set confidence = 0.0
            Set reasonCodes = ##class(%DynamicArray).%New()
            Do reasonCodes.%Push("agent_call_failed")
            Set summary = "AI Risk Agent unavailable - routed to human review. "_$System.Status.GetErrorText(agentSC)
            Do ##class(Ens.Util.Log).LogWarning($classname(),"OnRequest","Agent call failed for txn="_txnId_": "_$System.Status.GetErrorText(agentSC))
        } Else {
            Set d = ##class(PaymentGuard.Util.JSON).ExtractObject(aResp.RawContent)
            If (d = "") || '##class(PaymentGuard.Util.Validator).ValidDecision(d) {
                Set action = "REVIEW"
                Set source = "FALLBACK"
                Set riskScore = 60
                Set confidence = 0.0
                Set reasonCodes = ##class(%DynamicArray).%New()
                Do reasonCodes.%Push("agent_output_invalid")
                Set summary = "AI Risk Agent returned an unparseable or invalid decision - routed to human review"
                Do ##class(Ens.Util.Log).LogWarning($classname(),"OnRequest","Invalid agent output for txn="_txnId)
            } Else {
                Set action = d.action
                Set source = $Select(aResp.MockMode: "MOCK", 1: "AGENT")
                Set riskScore = d.%Get("risk_score")
                Set confidence = d.%Get("confidence")
                Set reasonCodes = d.%Get("reasons")
                Set summary = d.%Get("summary")
            }
            Set model = aResp.Model
            Set sessionId = aResp.SessionId
            Set promptTokens = aResp.PromptTokens
            Set completionTokens = aResp.CompletionTokens
            Set latencyMs = aResp.LatencyMs
        }
    }

    // ── 5. Route the outcome ──────────────────────────────────
    Set msg = ##class(PaymentGuard.Msg.DecisionMade).%New()
    Set msg.TxnId = txnId
    Set msg.CustomerId = pRequest.CustomerId
    Set msg.Action = action
    Set msg.Source = source
    Set msg.RiskScore = riskScore
    Set msg.Summary = summary
    Set msg.Model = model
    Set msg.Tokens = promptTokens + completionTokens

    Set target = $Select(action = "APPROVE": ..#SETTLETARGET, action = "REVIEW": ..#REVIEWTARGET, 1: ..#ALERTTARGET)
    Set routeResp = ""
    Set routeSC = ..SendRequestSync(target, msg, .routeResp)
    If $$$ISERR(routeSC) {
        // Routing failure must not lose the decision itself
        Do ##class(Ens.Util.Log).LogWarning($classname(),"OnRequest","Routing to "_target_" failed for txn="_txnId_": "_$System.Status.GetErrorText(routeSC))
    }

    // ── 6. Audit record + close the transaction ───────────────
    Set reasonJSON = reasonCodes
    If $IsObject(reasonCodes) Set reasonJSON = reasonCodes.%ToJSON()

    Set rec = ##class(PaymentGuard.Data.Decision).%New()
    Set rec.TxnId = txnId
    Set rec.CustomerId = pRequest.CustomerId
    Set rec.Amount = pRequest.Amount
    Set rec.Currency = txn.Currency
    Set rec.Action = action
    Set rec.Source = source
    Set rec.RiskScore = riskScore
    Set rec.Confidence = confidence
    Set rec.ReasonCodes = reasonJSON
    Set rec.Summary = summary
    Set rec.Model = model
    Set rec.SessionId = sessionId
    Set rec.PromptTokens = promptTokens
    Set rec.CompletionTokens = completionTokens
    If $IsObject(aResp) Set rec.ToolCalls = aResp.ToolCalls
    Set rec.LatencyMs = latencyMs
    Set recSC = rec.%Save()

    Set txn.Status = $Select(action = "APPROVE": "SETTLED", action = "REVIEW": "REVIEW", 1: "BLOCKED")
    If $$$ISOK(recSC) Set txn.DecisionId = rec.%Id()
    Do txn.%Save()

    // ── 7. Respond ────────────────────────────────────────────
    Set pResponse.TxnId = txnId
    Set pResponse.Action = action
    Set pResponse.Source = source
    Set pResponse.RiskScore = riskScore
    Set pResponse.Confidence = confidence
    Set pResponse.ReasonCodes = reasonJSON
    Set pResponse.Summary = summary
    Set pResponse.Model = model
    Set pResponse.SessionId = sessionId
    Set pResponse.PromptTokens = promptTokens
    Set pResponse.CompletionTokens = completionTokens
    Set pResponse.LatencyMs = latencyMs
    If $$$ISOK(recSC) Set pResponse.DecisionId = rec.%Id()

    Quit $$$OK
}

ClassMethod PaymentJSON(pReq As PaymentGuard.Request.Payment, pTxnId As %String) As %DynamicObject
{
    Set o = {}
    Do o.%Set("txn_id", pTxnId)
    Do o.%Set("customer_id", pReq.CustomerId)
    Do o.%Set("amount", pReq.Amount)
    Do o.%Set("currency", $Select(pReq.Currency '="": pReq.Currency, 1: "USD"))
    Do o.%Set("merchant", pReq.Merchant)
    Do o.%Set("merchant_category", pReq.MerchantCategory)
    Do o.%Set("channel", pReq.Channel)
    Do o.%Set("geo_country", pReq.GeoCountry)
    Do o.%Set("device_id", pReq.DeviceId)
    Quit o
}

ClassMethod ParseTime(pTime As %String) As %TimeStamp
{
    If pTime = "" Quit $ZDATETIME($HOROLOG, 3, 1)
    Set out = $ZDATETIME($HOROLOG, 3, 1)
    Try {
        Set internal = $ZDATETIMEH(pTime, 3, 1)
        Set out = $ZDATETIME(internal, 3, 1)
    } Catch ex {
    }
    Quit out
}

}
