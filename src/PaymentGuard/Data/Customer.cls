Include (%occStatus)

/// A payment platform customer profile used for risk enrichment and demo seeding.
Class PaymentGuard.Data.Customer Extends %Persistent
{

/// External customer identifier (e.g. cust_vip_001)
Property CustomerId As %String(MAXLEN = 64) [ Required ];

Property Name As %String(MAXLEN = 128);

/// RETAIL | SME | VIP
Property Segment As %String(VALUELIST = ",RETAIL,SME,VIP") [ InitialExpression = "RETAIL" ];

/// ISO 3166-1 alpha-2 home country
Property Country As %String(MAXLEN = 2);

/// LOW | MEDIUM | HIGH
Property RiskRating As %String(VALUELIST = ",LOW,MEDIUM,HIGH") [ InitialExpression = "LOW" ];

/// VERIFIED | PENDING | FAILED
Property KycStatus As %String(VALUELIST = ",VERIFIED,PENDING,FAILED") [ InitialExpression = "PENDING" ];

Property Blacklisted As %Boolean [ InitialExpression = 0 ];

Property AccountAgeDays As %Integer [ InitialExpression = 0 ];

/// Average monthly spend in USD
Property AvgMonthlyUsd As %Numeric(SCALE = 2) [ InitialExpression = 0 ];

/// 0-100 platform trust score
Property TrustScore As %Integer [ InitialExpression = 50 ];

Index CustomerIdIdx On CustomerId [ Unique ];

/// Open by CustomerId, returning "" when not found.
ClassMethod OpenByCustomerId(pCustomerId As %String) As PaymentGuard.Data.Customer
{
    Set tSC = $$$OK
    Set tObj = ..CustomerIdIdxOpen(pCustomerId, .tSC)
    If $$$ISERR(tSC) Quit ""
    Quit tObj
}

}
