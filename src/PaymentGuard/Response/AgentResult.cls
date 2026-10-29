Include (%occStatus)

/// Raw result from the AI Risk Agent operation: the agent's final answer plus
/// full cost observability (tokens, tool calls, latency, session id).
Class PaymentGuard.Response.AgentResult Extends (Ens.Response, %JSON.Adaptor)
{

/// The agent's final message content (expected to be a JSON decision object)
Property RawContent As %String(MAXLEN = "");

Property Model As %String(MAXLEN = 128);

Property SessionId As %String(MAXLEN = 64);

Property PromptTokens As %Integer [ InitialExpression = 0 ];

Property CompletionTokens As %Integer [ InitialExpression = 0 ];

Property ToolCalls As %Integer [ InitialExpression = 0 ];

Property LatencyMs As %Integer [ InitialExpression = 0 ];

Property MockMode As %Boolean [ InitialExpression = 0 ];

}
