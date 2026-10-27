Include (%occStatus)

/// Post-install hook invoked by the IPM module (module.xml Invoke) and by
/// %ZSTART on instance boot: seeds demo data if needed and starts the
/// production.
Class PaymentGuard.Util.Setup
{

Parameter PRODUCTION = "PaymentGuard.Production";

/// Called by the module installer.
ClassMethod Run() As %Status
{
    Set tSC = ##class(PaymentGuard.Data.Populate).Seed(0)
    If $$$ISERR(tSC) Quit tSC
    Quit ..EnsureRunning()
}

/// Start the production if it is not running already.
ClassMethod EnsureRunning() As %Status
{
    Set tSC = $$$OK
    Try {
        Do ##class(ENS.Director).StartProduction(..#PRODUCTION)
    } Catch ex {
        // Already running or transient - report state via GetProductionState
    }
    Quit tSC
}

}
