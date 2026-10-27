Include (%occStatus)

/// JSON helpers for parsing LLM output defensively.
Class PaymentGuard.Util.JSON
{

/// Extract the first JSON object from arbitrary LLM output: handles plain
/// JSON, markdown-fenced JSON and JSON surrounded by prose. Returns "" when
/// no valid object can be extracted.
ClassMethod ExtractObject(pContent As %String) As %DynamicObject
{
    If pContent = "" Quit ""
    Set text = pContent
    Set result = ""

    // Strip markdown fences
    If $Find(text, "```") > 0 {
        For replace = "```json", "```JSON", "```" {
            While $Find(text, replace) {
                Set text = $Replace(text, replace, " ")
            }
        }
    }

    // Direct parse first
    Try {
        Set o = ##class(%DynamicObject).%FromJSON(text)
        If $IsObject(o) Set result = o
    } Catch ex {
    }
    If $IsObject(result) Quit result

    // Otherwise: first '{' to last '}'
    Set start = $Find(text, "{")
    If start = 0 Quit ""
    Set last = 0
    For i = 1:1:$Length(text) {
        If $Extract(text, i) = "}" Set last = i
    }
    If last = 0 Quit ""
    Set candidate = $Extract(text, start - 1, last)

    Try {
        Set c = ##class(%DynamicObject).%FromJSON(candidate)
        If $IsObject(c) Set result = c
    } Catch ex {
    }
    Quit result
}

}
