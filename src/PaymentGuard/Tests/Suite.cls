Include (%occStatus)

/// Convenience runner for the whole suite:
///   do ##class(PaymentGuard.Tests.Suite).RunAll()
Class PaymentGuard.Tests.Suite
{

ClassMethod RunAll() As %Status
{
    Quit ##class(%UnitTest.Manager).RunTest("PaymentGuard.Tests", "/nodebug")
}

}
