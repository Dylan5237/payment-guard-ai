Include (%occStatus)

/// Raises a fraud alert (and blocks the payment) when the decision is BLOCK.
Class PaymentGuard.Interop.AlertBO Extends Ens.BusinessOperation
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
    Set txn = ##class(PaymentGuard.Data.Transaction).OpenByTxnId(pRequest.TxnId)
    If $IsObject(txn) {
        Set txn.Status = "BLOCKED"
        Do txn.%Save()
    }
    Set rec = ##class(PaymentGuard.Data.CaseRecord).%New()
    Set rec.CaseId = "alt_"_$Piece($Horolog,",",1)_$Piece($Horolog,",",2)_"_"_$RANDOM(999999)
    Set rec.TxnId = pRequest.TxnId
    Set rec.CustomerId = pRequest.CustomerId
    Set rec.Type = "ALERT"
    Set rec.Priority = $Select(pRequest.RiskScore >= 70: "HIGH", 1: "MEDIUM")
    Set rec.RiskScore = pRequest.RiskScore
    Set rec.Summary = pRequest.Summary
    Set recSC = rec.%Save()
    If $$$ISERR(recSC) Quit recSC
    Do ##class(Ens.Util.Log).LogWarning($classname(),"OnDecisionMade","FRAUD ALERT "_rec.CaseId_" txn="_pRequest.TxnId_" risk="_pRequest.RiskScore_" source="_pRequest.Source)
    Quit $$$OK
}

}
