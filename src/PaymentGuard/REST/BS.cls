/// REST entry point business service. The dispatch class
/// (PaymentGuard.REST.Dispatch) creates this service via EnsLib.Director and
/// sends requests synchronously into the production, so every API call is a
/// fully traced interoperability message exchange.
Class PaymentGuard.REST.BS Extends EnsLib.REST.Service
{
}
