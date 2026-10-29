Include (%occStatus)

/// Final decision returned by the production to the REST caller.
Class PaymentGuard.Response.Decision Extends (Ens.Response, %JSON.Adaptor)
{

Property TxnId As %String(MAXLEN = 64);

/// APPROVE | REVIEW | BLOCK
Property Action As %String(VALUELIST = ",APPROVE,REVIEW,BLOCK");

/// RULES | AGENT | MOCK | FALLBACK
Property Source As %String(VALUELIST = ",RULES,AGENT,MOCK,FALLBACK");

Property RiskScore As %Integer;

Property Confidence As %Numeric(SCALE = 2);

/// Reason codes as a JSON array string, e.g. ["device_shared_across_customers"]
Property ReasonCodes As %String(MAXLEN = 2000);

Property Summary As %String(MAXLEN = 4000);

Property Model As %String(MAXLEN = 128);

Property SessionId As %String(MAXLEN = 64);

Property PromptTokens As %Integer;

Property CompletionTokens As %Integer;

Property LatencyMs As %Integer;

Property DecisionId As %String(MAXLEN = 64);

/// Serialize to the JSON shape returned by the REST API.
Method ToAPIJSON() As %DynamicObject
{
    Set o = {}
    Do o.%Set("txn_id", ..TxnId)
    Do o.%Set("action", ..Action)
    Do o.%Set("source", ..Source)
    Do o.%Set("risk_score", ..RiskScore)
    Do o.%Set("confidence", ..Confidence)
    Set reasons = []
    If ..ReasonCodes '= "" {
        Try { Set reasons = ##class(%DynamicArray).%FromJSON(..ReasonCodes) } Catch ex { Set reasons = [] }
    }
    Do o.%Set("reasons", reasons)
    Do o.%Set("summary", ..Summary)
    Do o.%Set("model", ..Model)
    Do o.%Set("session_id", ..SessionId)
    Do o.%Set("prompt_tokens", ..PromptTokens)
    Do o.%Set("completion_tokens", ..CompletionTokens)
    Do o.%Set("latency_ms", ..LatencyMs)
    Do o.%Set("decision_id", ..DecisionId)
    Quit o
}

}
