Include (%occStatus)

/// Convenience runner for the whole suite:
///   do ##class(PaymentGuard.Tests.Suite).RunAll()
Class PaymentGuard.Tests.Suite
{

ClassMethod RunAll() As %Status
{
    // Package form: the manager imports ^UnitTestRoot/PaymentGuard/Tests/*.cls
    // and runs every %TestCase class. Fully-qualified class names with /noload
    // resolve each name as a directory and fail on this EAP build.
    Set ^UnitTestRoot = "/home/irisowner/dev/src"
    Quit ##class(%UnitTest.Manager).RunTest("PaymentGuard.Tests", "/nodebug")
}

}
