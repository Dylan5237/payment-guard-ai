Include (%occStatus)

/// Work item produced by the downstream business operations: a REVIEW case for
/// the human risk team or a fraud ALERT escalation.
Class PaymentGuard.Data.CaseRecord Extends %Persistent
{

Property CaseId As %String(MAXLEN = 64) [ Required ];

Property TxnId As %String(MAXLEN = 64);

Property CustomerId As %String(MAXLEN = 64);

/// REVIEW | ALERT
Property Type As %String(VALUELIST = ",REVIEW,ALERT");

/// LOW | MEDIUM | HIGH
Property Priority As %String(VALUELIST = ",LOW,MEDIUM,HIGH") [ InitialExpression = "MEDIUM" ];

Property RiskScore As %Integer;

Property Summary As %String(MAXLEN = 4000);

/// OPEN | RESOLVED
Property Status As %String(VALUELIST = ",OPEN,RESOLVED") [ InitialExpression = "OPEN" ];

Property CreatedAt As %TimeStamp [ InitialExpression = {$ZDATETIME($HOROLOG,3,1)} ];

Index CaseIdIdx On CaseId [ Unique ];
Index TypeIdx On (Type, Status);

}
