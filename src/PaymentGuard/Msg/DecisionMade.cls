Include (%occStatus)

/// Decision notification message routed to the downstream business operations
/// (settlement, review queue, fraud alert).
Class PaymentGuard.Msg.DecisionMade Extends Ens.Request
{

Property TxnId As %String(MAXLEN = 64);

Property CustomerId As %String(MAXLEN = 64);

/// APPROVE | REVIEW | BLOCK
Property Action As %String(VALUELIST = ",APPROVE,REVIEW,BLOCK");

Property Source As %String(MAXLEN = 16);

Property RiskScore As %Integer;

Property Summary As %String(MAXLEN = 4000);

Property Model As %String(MAXLEN = 128);

Property Tokens As %Integer [ InitialExpression = 0 ];

}
