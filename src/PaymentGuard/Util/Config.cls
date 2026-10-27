Include (%occStatus)

/// Central place for environment-driven configuration.
Class PaymentGuard.Util.Config
{

ClassMethod Env(pName As %String) As %String
{
    Quit $System.Util.GetEnviron(pName)
}

/// AI Hub provider name; DeepSeek works out of the box in China and is cheap,
/// but any provider supported by %AI.Provider can be selected.
ClassMethod ProviderName() As %String
{
    Set t = ..Env("AI_PROVIDER")
    If t = "" Set t = "deepseek"
    Quit t
}

ClassMethod ModelName() As %String
{
    Set t = ..Env("AI_MODEL")
    If t = "" Set t = "deepseek-chat"
    Quit t
}

/// Resolve the API key for a provider: provider-specific env var first, then
/// the generic AI_API_KEY.
ClassMethod APIKey(pProvider As %String = "") As %String
{
    If pProvider = "" Set pProvider = ..ProviderName()
    // Provider name uppercase + _API_KEY, e.g. DEEPSEEK_API_KEY
    Set up = $ZConvert(pProvider, "U")
    Set k = ..Env(up_"_API_KEY")
    If k '= "" Quit k
    Quit ..Env("AI_API_KEY")
}

/// True when mock mode was requested via AGENT_MOCK=1 or when no API key is
/// configured at all (out-of-the-box experience without a key).
ClassMethod MockRequested() As %Boolean
{
    If ..Env("AGENT_MOCK") = "1" Quit 1
    If ..APIKey(..ProviderName()) = "" Quit 1
    Quit 0
}

}
