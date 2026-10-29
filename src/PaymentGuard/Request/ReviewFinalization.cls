Include (%occStatus)

/// Final human decision on a REVIEW payment: delivered to the
/// PaymentGuard Review Finalizer business process when a human analyst
/// completes the Workflow Engine task (Approve/Reject).
Class PaymentGuard.Request.ReviewFinalization Extends (Ens.Request, %JSON.Adaptor)
{

Property TxnId As %String(MAXLEN = 64);

Property CustomerId As %String(MAXLEN = 64);

Property Amount As %Numeric(SCALE = 2);

Property Currency As %String(MAXLEN = 3);

/// APPROVE | BLOCK — the final call
Property Action As %String(VALUELIST = ",APPROVE,BLOCK");

/// Human action as taken on the workflow task (Approve/Reject)
Property HumanAction As %String(MAXLEN = 32);

/// Workflow user who made the call
Property Reviewer As %String(MAXLEN = 64);

Property RiskScore As %Integer;

/// Summary of the original (pre-review) decision
Property Summary As %String(MAXLEN = 4000);

/// Which engine produced the original REVIEW decision (AGENT/MOCK/FALLBACK)
Property OriginSource As %String(MAXLEN = 16);

Property WorkflowTaskId As %String(MAXLEN = 64);

}
