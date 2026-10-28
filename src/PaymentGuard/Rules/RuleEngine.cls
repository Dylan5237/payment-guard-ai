Include (%occStatus)

/// Deterministic pre-decision rules. Rules that produce a certain outcome run
/// here — cheap, explainable and instant; only the gray zone between them is
/// escalated to the AI Hub agent. Returns "BLOCK", "APPROVE" or "" (escalate
/// to the agent).
Class PaymentGuard.Rules.RuleEngine
{

Parameter SANCTIONEDGEO = "KP,IR,SY,SD,MM,CU,BY";

/// Merchant / healthcare-provider blacklist (fraud shops, shuttered clinics).
/// Claims reuse this via the merchant field: the provider IS the merchant.
Parameter BLACKLISTEDMERCHANTS = "Sunrise Wellness Center";

/// Duplicate-claim lookback window in hours: same insured member + same
/// procedure settled in another city within this window => duplicate claim
Parameter CLAIMDUPLICATEHOURS = 168;

/// Segment hard caps in USD
Parameter CAPRETAIL = 5000;

Parameter CAPSME = 50000;

Parameter CAPVIP = 100000;

/// Evaluate deterministic rules.
/// pCtx is the enrichment context built by PaymentGuard.Data.Enricher.
/// pRule and pReason are set to the matched rule name and its reason when a
/// decision is produced.
ClassMethod Evaluate(pReq As PaymentGuard.Request.Payment, pCtx As %DynamicObject, Output pRule As %String, Output pReason As %String) As %String
{
    Set pRule = "", pReason = ""
    Set cust = pCtx.%Get("customer")

    // ── Hard blocks ─────────────────────────────────────────────
    If $IsObject(cust), cust.%Get("blacklisted") = 1 {
        Set pRule = "BLACKLISTED_CUSTOMER", pReason = "Customer is on the platform blacklist"
        Quit "BLOCK"
    }
    If pReq.Merchant '= "", $Find(..#BLACKLISTEDMERCHANTS, pReq.Merchant) > 0 {
        Set pRule = "BLACKLISTED_MERCHANT", pReason = "Merchant/provider "_pReq.Merchant_" is on the platform blacklist"
        Quit "BLOCK"
    }
    If $IsObject(cust), cust.%Get("known") = 1, cust.%Get("kyc_status") = "FAILED" {
        Set pRule = "KYC_FAILED", pReason = "Customer KYC verification has failed"
        Quit "BLOCK"
    }
    If pReq.GeoCountry '= "", $Find(..#SANCTIONEDGEO, pReq.GeoCountry) > 0 {
        Set pRule = "SANCTIONED_GEO", pReason = "Payment geo "_pReq.GeoCountry_" is sanctioned"
        Quit "BLOCK"
    }
    Set segCap = ..SegmentCap($Select($IsObject(cust): cust.%Get("segment"), 1: ""))
    If pReq.Amount > segCap {
        Set pRule = "OVER_SEGMENT_LIMIT", pReason = "Amount "_pReq.Amount_" exceeds segment cap "_segCap
        Quit "BLOCK"
    }
    Set v1h = pCtx.%Get("velocity_1h")
    If $IsObject(v1h), v1h.%Get("count") >= 8 {
        Set pRule = "VELOCITY_SPIKE", pReason = v1h.%Get("count")_" payment attempts in the last hour"
        Quit "BLOCK"
    }

    // ── Healthcare claim rules (payment carries a procedure) ───
    If pReq.Procedure '= "", pReq.City '= "" {
        Set prior = ..PriorCrossCityClaim(pReq)
        If $IsObject(prior) {
            Set pRule = "DUPLICATE_CROSS_CITY_CLAIM"
            Set pReason = "Insured member settled procedure "_pReq.Procedure_" in "_prior.%Get("city")_" within the last "_(..#CLAIMDUPLICATEHOURS \ 24)_" days (prior claim "_prior.%Get("txn_id")_" on "_prior.%Get("time")_") - duplicate cross-city reimbursement"
            Quit "BLOCK"
        }
    }

    // ── Fast approve: trusted, verified, small, known device ───
    Set dev = pCtx.%Get("device")
    If $IsObject(cust),
       cust.%Get("known") = 1,
       cust.%Get("kyc_status") = "VERIFIED",
       cust.%Get("trust_score") >= 75,
       pReq.Amount <= 100,
       pReq.GeoCountry '= "",
       pReq.GeoCountry = cust.%Get("country"),
       $IsObject(dev),
       dev.%Get("known") = 1,
       dev.%Get("customer_count") <= 1 {
        Set pRule = "LOW_RISK_FAST_PATH", pReason = "Trusted customer, small amount, home country, known personal device"
        Quit "APPROVE"
    }

    // ── Gray zone: the AI Hub agent decides ────────────────────
    Quit ""
}

ClassMethod SegmentCap(pSegment As %String) As %Integer
{
    If pSegment = "VIP" Quit ..#CAPVIP
    If pSegment = "SME" Quit ..#CAPSME
    Quit ..#CAPRETAIL
}

/// Most recent prior settled claim of the same member for the same procedure
/// in a different city inside the duplicate window; "" when none.
ClassMethod PriorCrossCityClaim(pReq As PaymentGuard.Request.Payment) As %DynamicObject
{
    Set cutoff = ##class(PaymentGuard.Data.Enricher).HoursAgo(..#CLAIMDUPLICATEHOURS)
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT TOP 1 TxnId, City, Amount, TxnTime FROM PaymentGuard_Data.""Transaction"" WHERE CustomerId = ? AND ""Procedure"" = ? AND Status = 'SETTLED' AND City <> '' AND City <> ? AND TxnTime > ? ORDER BY TxnTime DESC")
    If $$$ISERR(tSC) Quit ""
    Set tRS = tStmt.%Execute(pReq.CustomerId, pReq.Procedure, pReq.City, cutoff)
    If 'tRS.%Next() Quit ""
    Quit {"txn_id": (tRS.%Get("TxnId")), "city": (tRS.%Get("City")), "amount": (tRS.%Get("Amount")), "time": (tRS.%Get("TxnTime"))}
}

}
