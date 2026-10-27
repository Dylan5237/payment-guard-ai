Include (%occStatus)

/// Deterministic pre-decision rules. Rules that produce a certain outcome run
/// here — cheap, explainable and instant; only the gray zone between them is
/// escalated to the AI Hub agent. Returns "BLOCK", "APPROVE" or "" (escalate
/// to the agent).
Class PaymentGuard.Rules.RuleEngine
{

Parameter SANCTIONEDGEO = "KP,IR,SY,SD,MM,CU,BY";

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
    If $Get(cust.blacklisted) = 1 {
        Set pRule = "BLACKLISTED_CUSTOMER", pReason = "Customer is on the platform blacklist"
        Quit "BLOCK"
    }
    If $Get(cust.known) = 1, $Get(cust.kyc_status) = "FAILED" {
        Set pRule = "KYC_FAILED", pReason = "Customer KYC verification has failed"
        Quit "BLOCK"
    }
    If pReq.GeoCountry '= "", $Find(..#SANCTIONEDGEO, pReq.GeoCountry) > 0 {
        Set pRule = "SANCTIONED_GEO", pReason = "Payment geo "_pReq.GeoCountry_" is sanctioned"
        Quit "BLOCK"
    }
    If pReq.Amount > ..SegmentCap($Get(cust.segment)) {
        Set pRule = "OVER_SEGMENT_LIMIT", pReason = "Amount "_pReq.Amount_" exceeds segment cap "_..SegmentCap($Get(cust.segment))
        Quit "BLOCK"
    }
    Set v1h = pCtx.%Get("velocity_1h")
    If $IsObject(v1h), $Get(v1h.count) >= 8 {
        Set pRule = "VELOCITY_SPIKE", pReason = $Get(v1h.count)_" payment attempts in the last hour"
        Quit "BLOCK"
    }

    // ── Fast approve: trusted, verified, small, known device ───
    If $Get(cust.known) = 1,
       $Get(cust.kyc_status) = "VERIFIED",
       $Get(cust.trust_score) >= 75,
       pReq.Amount <= 100,
       pReq.GeoCountry = $Get(cust.country) {
        Set dev = pCtx.%Get("device")
        If $IsObject(dev), $Get(dev.known) = 1, $Get(dev.customer_count) <= 1 {
            Set pRule = "LOW_RISK_FAST_PATH", pReason = "Trusted customer, small amount, home country, known personal device"
            Quit "APPROVE"
        }
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

}
