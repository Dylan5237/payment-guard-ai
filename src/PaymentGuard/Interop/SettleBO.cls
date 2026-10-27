Include (%occStatus, EnsTypes)

/// Marks approved payments as settled. In a real deployment this operation
/// would call the ledger / acquiring system; here it closes the loop in IRIS.
Class PaymentGuard.Interop.SettleBO Extends Ens.BusinessOperation
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
        Set txn.Status = "SETTLED"
        Do txn.%Save()
    }
    Do $$$LOGINFO("Settled txn="_pRequest.TxnId_" risk="_pRequest.RiskScore)
    Quit $$$OK
}

}
