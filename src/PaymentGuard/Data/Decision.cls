Include (%occStatus)

/// Immutable audit record for every decision the production makes — whether it
/// came from deterministic rules, the AI Hub agent, the mock engine or a
/// fail-safe fallback. Includes full agent cost observability (tokens, latency,
/// session id) so every AI decision can be traced, replayed and accounted.
Class PaymentGuard.Data.Decision Extends %Persistent
{

Property TxnId As %String(MAXLEN = 64) [ Required ];

Property CustomerId As %String(MAXLEN = 64);

Property Amount As %Numeric(SCALE = 2);

Property Currency As %String(MAXLEN = 3);

/// APPROVE | REVIEW | BLOCK
Property Action As %String(VALUELIST = ",APPROVE,REVIEW,BLOCK");

/// RULES | AGENT | MOCK | FALLBACK
Property Source As %String(VALUELIST = ",RULES,AGENT,MOCK,FALLBACK");

Property RiskScore As %Integer;

Property Confidence As %Numeric(SCALE = 2);

/// Reason codes as a JSON array string
Property ReasonCodes As %String(MAXLEN = 2000);

Property Summary As %String(MAXLEN = 4000);

/// Raw decision payload from the agent (or mock engine), kept for audit/replay
Property EngineDetail As %String(MAXLEN = "");

/// Which LLM produced the decision ("" for rules)
Property Model As %String(MAXLEN = 128);

/// AI Hub agent session id — the persisted conversation can be reopened with
/// ##class(%AI.Agent.Session).%OpenId(...)
Property SessionId As %String(MAXLEN = 64);

Property PromptTokens As %Integer [ InitialExpression = 0 ];

Property CompletionTokens As %Integer [ InitialExpression = 0 ];

Property ToolCalls As %Integer [ InitialExpression = 0 ];

Property LatencyMs As %Integer [ InitialExpression = 0 ];

Property CreatedAt As %TimeStamp [ InitialExpression = {$ZDATETIME($HOROLOG,3,1)} ];

Index TxnIdx On TxnId;
Index CreatedIdx On CreatedAt;

}
