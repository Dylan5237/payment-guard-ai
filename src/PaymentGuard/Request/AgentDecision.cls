/// Ask the AI Risk Agent operation for a decision. The production's decision
/// process sends this to the agent business operation, exactly like any other
/// interoperability component.
Class PaymentGuard.Request.AgentDecision Extends Ens.Request
{

Property TxnId As %String(MAXLEN = 64);

/// Full decision context as JSON: the payment plus enrichment data
Property ContextJSON As %String(MAXLEN = "");

}
