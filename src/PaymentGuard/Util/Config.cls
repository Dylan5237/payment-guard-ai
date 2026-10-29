Include (%occStatus)

/// Central place for environment-driven configuration.
///
/// Precedence for every setting: runtime override (^PaymentGuardSettings,
/// writable via the /paymentguard/api/admin/model endpoint) → environment
/// variable (.env / container) → built-in default. Runtime overrides let a
/// running deployment switch provider, model or API key without recreating
/// the container; the agent reads these on every decision, so changes take
/// effect on the next request.
Class PaymentGuard.Util.Config
{

ClassMethod Env(pName As %String) As %String
{
    Quit $System.Util.GetEnviron(pName)
}

ClassMethod RuntimeGet(pName As %String) As %String
{
    Quit $Get(^PaymentGuardSettings(pName))
}

/// AI Hub provider name; DeepSeek works out of the box in China and is cheap,
/// but any provider supported by %AI.Provider can be selected.
ClassMethod ProviderName() As %String
{
    Set t = ..RuntimeGet("Provider")
    If t = "" Set t = ..Env("AI_PROVIDER")
    If t = "" Set t = "deepseek"
    Quit t
}

ClassMethod ProviderSource() As %String
{
    If ..RuntimeGet("Provider") '= "" Quit "runtime"
    If ..Env("AI_PROVIDER") '= "" Quit "env"
    Quit "default"
}

ClassMethod ModelName() As %String
{
    Set t = ..RuntimeGet("Model")
    If t = "" Set t = ..Env("AI_MODEL")
    If t = "" Set t = "deepseek-chat"
    Quit t
}

ClassMethod ModelSource() As %String
{
    If ..RuntimeGet("Model") '= "" Quit "runtime"
    If ..Env("AI_MODEL") '= "" Quit "env"
    Quit "default"
}

/// Optional OpenAI-compatible base URL override for self-hosted gateways.
ClassMethod BaseUrl() As %String
{
    Set t = ..RuntimeGet("BaseUrl")
    If t = "" Set t = ..Env("AI_BASE_URL")
    Quit t
}

ClassMethod BaseUrlSource() As %String
{
    If ..RuntimeGet("BaseUrl") '= "" Quit "runtime"
    If ..Env("AI_BASE_URL") '= "" Quit "env"
    Quit "none"
}

/// Resolve the API key for a provider: runtime override first, then
/// provider-specific env var, then the generic AI_API_KEY.
ClassMethod APIKey(pProvider As %String = "") As %String
{
    Set k = ..RuntimeGet("APIKey")
    If k '= "" Quit k
    If pProvider = "" Set pProvider = ..ProviderName()
    // Provider name uppercase + _API_KEY, e.g. DEEPSEEK_API_KEY
    Set up = $ZConvert(pProvider, "U")
    Set k = ..Env(up_"_API_KEY")
    If k '= "" Quit k
    Quit ..Env("AI_API_KEY")
}

ClassMethod APIKeySource() As %String
{
    If ..RuntimeGet("APIKey") '= "" Quit "runtime"
    If ..APIKey() '= "" Quit "env"
    Quit "none"
}

/// Shared-secret for the /admin/* endpoints (see OPERATIONS.md). Runtime
/// override first (so a leaked token can be rotated without recreating the
/// container), then the ADMIN_TOKEN env var.
ClassMethod AdminToken() As %String
{
    Set t = ..RuntimeGet("AdminToken")
    If t = "" Set t = ..Env("ADMIN_TOKEN")
    Quit t
}

/// True when mock mode was requested (AGENT_MOCK=1, the runtime override, or
/// no API key configured at all — the out-of-the-box experience without a key).
ClassMethod MockRequested() As %Boolean
{
    If ..RuntimeGet("MockMode") = 1 Quit 1
    If ..Env("AGENT_MOCK") = "1" Quit 1
    If ..APIKey() = "" Quit 1
    Quit 0
}

}
