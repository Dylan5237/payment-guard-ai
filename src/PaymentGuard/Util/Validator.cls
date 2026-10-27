Include (%occStatus)

/// Validation helpers.
Class PaymentGuard.Util.Validator
{

/// True when a parsed agent decision satisfies the output contract:
/// action in enum, 0-100 risk, 0-1 confidence, reasons an array.
ClassMethod ValidDecision(pDecision As %DynamicObject) As %Boolean
{
    If '$IsObject(pDecision) Quit 0
    Set action = pDecision.%Get("action")
    If (action '= "APPROVE") && (action '= "REVIEW") && (action '= "BLOCK") Quit 0
    Set risk = pDecision.%Get("risk_score")
    If risk '= +risk Quit 0
    If (risk < 0) || (risk > 100) Quit 0
    Set conf = pDecision.%Get("confidence")
    If (conf '= "") && (conf '= +conf) Quit 0
    If (conf < 0) || (conf > 1) Quit 0
    Set reasons = pDecision.%Get("reasons")
    If reasons '= "", '$IsObject(reasons) Quit 0
    Quit 1
}

}
