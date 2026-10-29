Include (%occStatus)

/// Convenience runner for the whole suite:
///   do ##class(PaymentGuard.Tests.Suite).RunAll()
Class PaymentGuard.Tests.Suite
{

ClassMethod RunAll() As %Status
{
    // /noload mode takes comma-separated, fully-qualified test class names
    Quit ##class(%UnitTest.Manager).RunTest("PaymentGuard.Tests.TestRules,PaymentGuard.Tests.TestJSON,PaymentGuard.Tests.TestPyModel,PaymentGuard.Tests.TestMockFlow,PaymentGuard.Tests.TestClaims,PaymentGuard.Tests.TestWorkflow", "/noload/nodebug")
}

}
