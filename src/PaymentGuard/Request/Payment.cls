Include (%occStatus)

/// Inbound payment authorization request. Enters the production through the
/// REST dispatch class and is processed by the decision business process.
Class PaymentGuard.Request.Payment Extends (Ens.Request, %JSON.Adaptor)
{

/// External transaction id; generated when empty
Property TxnId As %String(MAXLEN = 64);

Property CustomerId As %String(MAXLEN = 64) [ Required ];

Property Amount As %Numeric(SCALE = 2) [ Required ];

Property Currency As %String(MAXLEN = 3) [ InitialExpression = "USD" ];

Property Merchant As %String(MAXLEN = 128);

Property MerchantCategory As %String(MAXLEN = 64);

/// CARD | WIRE | ECOM | POS | ATM
Property Channel As %String(VALUELIST = ",CARD,WIRE,ECOM,POS,ATM");

/// ISO country of the payer device / IP
Property GeoCountry As %String(MAXLEN = 2);

Property DeviceId As %String(MAXLEN = 64);

/// ISO timestamp supplied by the caller; defaults to now
Property TxnTime As %String(MAXLEN = 40);

/// Healthcare claims only: treatment procedure code (e.g. CATARACT_SURGERY).
/// Present => the payment is a health-insurance claim settlement.
Property Procedure As %String(MAXLEN = 64);

/// Healthcare claims only: ICD-10 diagnosis code (e.g. H25.9)
Property Diagnosis As %String(MAXLEN = 16);

/// Healthcare claims only: city where the settlement took place
Property City As %String(MAXLEN = 64);

}
