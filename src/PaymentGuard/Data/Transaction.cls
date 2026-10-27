Include (%occStatus)

/// One payment authorization attempt. Every request that enters the production
/// is persisted here first; its <property>Status</property> tracks the outcome.
Class PaymentGuard.Data.Transaction Extends %Persistent
{

/// External transaction id (generated when the caller does not supply one)
Property TxnId As %String(MAXLEN = 64) [ Required ];

Property CustomerId As %String(MAXLEN = 64) [ Required ];

Property Amount As %Numeric(SCALE = 2);

Property Currency As %String(MAXLEN = 3) [ InitialExpression = "USD" ];

Property Merchant As %String(MAXLEN = 128);

Property MerchantCategory As %String(MAXLEN = 64);

/// CARD | WIRE | ECOM | POS | ATM
Property Channel As %String(VALUELIST = ",CARD,WIRE,ECOM,POS,ATM");

Property GeoCountry As %String(MAXLEN = 2);

Property DeviceId As %String(MAXLEN = 64);

Property TxnTime As %TimeStamp;

/// PENDING | SETTLED | REVIEW | BLOCKED
Property Status As %String(VALUELIST = ",PENDING,SETTLED,REVIEW,BLOCKED") [ InitialExpression = "PENDING" ];

/// Id of the PaymentGuard.Data.Decision audit row that resolved this transaction
Property DecisionId As %String(MAXLEN = 64);

Index TxnIdIdx On TxnId [ Unique ];
Index CustTimeIdx On (CustomerId, TxnTime);
Index DeviceIdx On DeviceId;
Index StatusIdx On Status;

/// Open by TxnId, returning "" when not found.
ClassMethod OpenByTxnId(pTxnId As %String) As PaymentGuard.Data.Transaction
{
    Set tSC = $$$OK
    Set tObj = ..TxnIdIdxOpen(pTxnId, .tSC)
    If $$$ISERR(tSC) Quit ""
    Quit tObj
}

}
