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
    Set tSC = ..EnsureWorkflow()
    If $$$ISERR(tSC) Quit tSC
    Set tSC = ##class(PaymentGuard.Data.Populate).Seed(0)
    If $$$ISERR(tSC) Quit tSC
    Quit ..EnsureRunning()
}

Parameter WORKFLOWROLE = "PaymentGuard Human Review";

/// Seed the native Workflow Engine side of the human-review loop: the role
/// (named after the business operation config), a demo analyst user and the
/// role membership. The operation auto-creates the role on start (AutoCreateRole);
/// this guarantees the user exists before the first task arrives.
ClassMethod EnsureWorkflow() As %Status
{
    Set tSC = $$$OK
    Set role = ..#WORKFLOWROLE
    Try {
        If '##class(EnsLib.Workflow.RoleDefinition).%ExistsId(role) {
            Set tSC = ##class(EnsLib.Workflow.RoleDefinition).CreateRole(role)
            If $$$ISERR(tSC) Quit
        }
        If '##class(EnsLib.Workflow.UserDefinition).%ExistsId("RiskAnalyst") {
            Set tSC = ##class(EnsLib.Workflow.UserDefinition).CreateUser("RiskAnalyst", "Demo Risk Analyst")
            If $$$ISERR(tSC) Quit
        }
        If '##class(EnsLib.Workflow.RoleMembership).%ExistsId(role_"||RiskAnalyst") {
            Set tSC = ##class(EnsLib.Workflow.RoleDefinition).AddUserToRole(role, "RiskAnalyst")
        }
    } Catch ex {
        Return $$$ERROR($$$GeneralError, "Workflow setup failed: "_ex.DisplayString())
    }
    Quit tSC
}

/// Force-close every open workflow task without delivering responses (used by
/// Reseed, which runs while the production is stopped): mark the task complete
/// and drop its worklist items, so a wiped demo dataset leaves no orphan tasks.
ClassMethod CancelOpenWorkflowTasks() As %Status
{
    Set tSC = $$$OK
    Set tStmt = ##class(%SQL.Statement).%New()
    Set dStmt = ##class(%SQL.Statement).%New()
    Set tSC = dStmt.%Prepare("DELETE FROM EnsLib.Workflow.Worklist WHERE Task = ?")
    If $$$ISERR(tSC) Quit tSC
    Set tSC = tStmt.%Prepare("SELECT ID FROM EnsLib.Workflow.TaskResponse ORDER BY ID DESC")
    If $$$ISERR(tSC) Quit tSC
    Set tRS = tStmt.%Execute()
    While tRS.%Next() {
        Set t = ##class(EnsLib.Workflow.TaskResponse).%OpenId(tRS.%Get("ID"), 4)
        If '$IsObject(t) Continue
        If t.%TaskStatus.IsComplete Continue
        Set t.%TaskStatus.IsComplete = 1
        Set t.%TaskStatus.TimeCompleted = $ZDATETIME($HOROLOG, 3, 1)
        Set t.%Status = "Cancelled"
        Set tSC = t.%Save()
        If $$$ISERR(tSC) Quit
        Do dStmt.%Execute(t.%Id())
    }
    Quit tSC
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

/// Start the production if it is not running already. Retried three times:
/// at instance boot %ZSTART can fire before the interoperability subsystem
/// is ready, and a single StartProduction attempt silently loses that race.
ClassMethod EnsureRunning() As %Status
{
    Set tSC = $$$OK
    // NB: this EAP rejects QUIT-with-argument inside loop bodies (<COMMAND>
    // at runtime) - exit the loop with a bare QUIT, return afterwards
    For attempt = 1:1:3 {
        If ##class(Ens.Director).IsProductionRunning() Quit
        Try {
            Do ##class(Ens.Director).StartProduction(..#PRODUCTION)
        } Catch ex {
            // Already running or transient - a later attempt covers the race
        }
        Hang 4
    }
    Quit tSC
}

/// True once the production has actually stopped. Starting a production while
/// a previous StopProduction is still settling wedges the runtime into
/// ErrProductionNotShutdownCleanly - always wait for the stop to finish.
ClassMethod WaitStopped(pSeconds As %Integer = 30) As %Boolean
{
    For i = 1:1:pSeconds {
        If '##class(Ens.Director).IsProductionRunning() Quit
        Hang 1
    }
    Quit '##class(Ens.Director).IsProductionRunning()
}

/// Clean demo reset: stop (and wait for the stop!), wipe+reseed, start again.
/// Shared by the /admin/reseed endpoint and the test suites - wiping tables
/// while the production is running poisons its shutdown state.
ClassMethod ResetDemo() As %Status
{
    Do ##class(Ens.Director).StopProduction()
    Do ..WaitStopped(30)
    Set tSC = ##class(PaymentGuard.Data.Populate).Seed(1)
    If $$$ISERR(tSC) Quit tSC
    Set tSC = ..EnsureRunning()
    Hang 1
    Quit tSC
}

}
