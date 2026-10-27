Include (%occStatus)

/// Opens a review case for the human risk team when the decision is REVIEW.
Class PaymentGuard.Interop.ReviewBO Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

XData MessageMap
{
<MapItems>
  <MapItem MessageType="PaymentGuard.Msg.DecisionMade">
    <Method>OnDecisionMade</Method>
  </MapItem>
</MapItems>
}

Method OnDecisionMade(pRequest As PaymentGuard.Msg.DecisionMade, Output pResponse As Ens.Response) As %Status
{
    Set pResponse = ##class(Ens.Response).%New()
    Set rec = ##class(PaymentGuard.Data.CaseRecord).%New()
    Set rec.CaseId = "rev_"_$Piece($Horolog,",",1)_$Piece($Horolog,",",2)_"_"_$RANDOM(999999)
    Set rec.TxnId = pRequest.TxnId
    Set rec.CustomerId = pRequest.CustomerId
    Set rec.Type = "REVIEW"
    Set rec.Priority = $Select(pRequest.RiskScore >= 70: "HIGH", pRequest.RiskScore >= 40: "MEDIUM", 1: "LOW")
    Set rec.RiskScore = pRequest.RiskScore
    Set rec.Summary = pRequest.Summary
    Set recSC = rec.%Save()
    If $$$ISERR(recSC) Quit recSC
    Do ##class(Ens.Util.Log).LogInfo($classname(),"OnDecisionMade","Opened review case "_rec.CaseId_" for txn="_pRequest.TxnId_" priority="_rec.Priority)
    Quit $$$OK
}

}
