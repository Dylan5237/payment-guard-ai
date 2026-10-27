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
    Set tSC = ..ConfigureWebApps()
    If $$$ISERR(tSC) Quit tSC
    Set tSC = ##class(PaymentGuard.Data.Populate).Seed(0)
    If $$$ISERR(tSC) Quit tSC
    Quit ..EnsureRunning()
}

/// The web apps are served through the Web Gateway sidecar with
/// unauthenticated demo access (see README - lock down for real use).
ClassMethod ConfigureWebApps() As %Status
{
    Set tSC = $$$OK
    New $Namespace
    Zn "%SYS"
    Set props("GrantedRoles") = "%All"
    Set props("AutheEnabled") = 64
    Set tSC1 = ##class(Security.Applications).Modify("/paymentguard/api", .props)
    Set tSC2 = ##class(Security.Applications).Modify("/csp/paymentguard", .props)
    If $$$ISERR(tSC1) Quit tSC1
    If $$$ISERR(tSC2) Quit tSC2
    Quit tSC
}

/// Start the production if it is not running already.
ClassMethod EnsureRunning() As %Status
{
    Set tSC = $$$OK
    Try {
        Do ##class(Ens.Director).StartProduction(..#PRODUCTION)
    } Catch ex {
        // Already running or transient - report state via GetProductionState
    }
    Quit tSC
}

}
