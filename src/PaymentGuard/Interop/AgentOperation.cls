Include (%occStatus)

/// Puts an AI Hub agent inside an interoperability production.
///
/// This is the bridge the EAP does not ship: a plain in-process business
/// operation that runs the PaymentGuard AI Hub agent (PaymentGuard.Agent.RiskAgent)
/// with the full production machinery around it — queueing, retries, and a
/// message-viewer trace for every agent call, exactly like any other
/// interoperability component.
///
/// A business process sends a PaymentGuard.Request.AgentDecision and receives
/// a PaymentGuard.Response.AgentResult carrying the agent's JSON decision plus
/// token usage, tool call count, latency and the persisted AI Hub session id.
///
/// MockMode (or AGENT_MOCK=1, or a missing API key) makes the operation answer
/// with a deterministic mock engine instead of calling the LLM, so the whole
/// production runs without any external dependency.
Class PaymentGuard.Interop.AgentOperation Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

Parameter SETTINGS = "MockMode";

/// Answer with the deterministic mock engine instead of calling the LLM
Property MockMode As %Boolean [ InitialExpression = 0 ];

XData MessageMap
{
<MapItems>
  <MapItem MessageType="PaymentGuard.Request.AgentDecision">
    <Method>Decide</Method>
  </MapItem>
</MapItems>
}

/// Run the AI Hub risk agent on a gray-zone payment.
Method Decide(pRequest As PaymentGuard.Request.AgentDecision, Output pResponse As PaymentGuard.Response.AgentResult) As %Status
{
    Set pResponse = ##class(PaymentGuard.Response.AgentResult).%New()
    Set tSC = $$$OK
    Set tStart = $ZH

    // ── Mock mode ─────────────────────────────────────────────
    // Three switches: the production item setting, the runtime global
    // ^PaymentGuardSettings("MockMode") (used by the test suite), or no
    // configured API key at all.
    If ..MockMode || $Get(^PaymentGuardSettings("MockMode")) {
        Do ##class(Ens.Util.Log).LogInfo($classname(),"Decide","Agent operation in mock mode, txn="_pRequest.TxnId)
        Set pResponse.RawContent = ##class(PaymentGuard.Rules.Mocker).DecideJSON(pRequest.ContextJSON)
        Set pResponse.Model = "mock-engine"
        Set pResponse.MockMode = 1
        Set pResponse.LatencyMs = ($ZH - tStart) * 1000 \ 1
        Quit $$$OK
    }
    If ##class(PaymentGuard.Util.Config).MockRequested() {
        Do ##class(Ens.Util.Log).LogInfo($classname(),"Decide","No API key configured - falling back to mock engine, txn="_pRequest.TxnId)
        Set pResponse.RawContent = ##class(PaymentGuard.Rules.Mocker).DecideJSON(pRequest.ContextJSON)
        Set pResponse.Model = "mock-engine"
        Set pResponse.MockMode = 1
        Set pResponse.LatencyMs = ($ZH - tStart) * 1000 \ 1
        Quit $$$OK
    }

    // ── Real AI Hub agent call ────────────────────────────────
    Set agent = ##class(PaymentGuard.Agent.RiskAgent).%New()
    Set tSC = agent.%Init()
    If $$$ISERR(tSC) Quit tSC

    Set session = agent.CreateSession({"max_iterations": 3})
    Set chatMsg = "Authorize or decline this payment. Context (JSON): "_pRequest.ContextJSON

    Try {
        Set llmResponse = agent.Chat(session, chatMsg)
    } Catch ex {
        Return $$$ERROR($$$GeneralError, "AI Hub agent chat failed: "_ex.DisplayString())
    }

    // Persist the session so any decision can be replayed/audited later
    Try {
        Do session.%Save()
    } Catch ex {
    }

    Set stats = session.GetStats()
    Set pResponse.RawContent = llmResponse.Content
    Set pResponse.Model = agent.Model
    Set pResponse.SessionId = session.%Id()
    Set pResponse.PromptTokens = stats."total_prompt_tokens"
    Set pResponse.CompletionTokens = stats."total_completion_tokens"
    Set pResponse.ToolCalls = stats."total_tool_calls"
    Set pResponse.LatencyMs = ($ZH - tStart) * 1000 \ 1

    Do ##class(Ens.Util.Log).LogInfo($classname(),"Decide","Agent decided txn="_pRequest.TxnId_" model="_pResponse.Model_" tokens="_(pResponse.PromptTokens + pResponse.CompletionTokens)_" latency_ms="_pResponse.LatencyMs)
    Quit $$$OK
}

}
