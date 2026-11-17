Include (%occStatus)

/// Learned device trust — the learning layer of the decision flow.
///
/// When a human analyst approves a REVIEW payment, the (customer, device)
/// pair behind it is trusted deterministically for a bounded time: the next
/// payment of the same customer on the same device is approved by the rule
/// engine (LEARNED_DEVICE_FAST_PATH) with zero LLM calls. That is the
/// learning loop: the agent's gray-zone work, once confirmed by a person,
/// becomes a rule the deterministic layer can apply on its own.
///
/// Safety boundaries, deliberately narrow:
///   - learned trust only widens the fast path AFTER every hard rule ran
///     (sanctions, blacklists, caps, velocity, duplicate claims stay absolute
///     and can never be learned away)
///   - scoped to one (customer, device) pair — no global generalization
///   - entries carry a TTL and a use counter; any later BLOCK of the same
///     pair demotes the entry immediately
///   - Learn() refuses to write when the pair has any BLOCKED history: a
///     learned rule must never contradict a past decision
Class PaymentGuard.Learned.Store
{

/// Days a learned device-trust entry stays valid
Parameter TTLDAYS = 30;

/// True when (pCustomerId, pDeviceId) carries a live learned-trust entry.
ClassMethod Trusted(pCustomerId As %String, pDeviceId As %String) As %Boolean
{
    If (pCustomerId = "") || (pDeviceId = "") Quit 0
    Set node = $GET(^PaymentGuardLearned("DeviceTrust", pCustomerId, pDeviceId))
    Quit:node="" 0
    If $LISTGET(node, 1, 0) < $Piece($Horolog, ",", 1) Quit 0
    Quit 1
}

/// Context object for the enrichment and the agent: an advisory signal for
/// the risk picture, never an instruction.
ClassMethod Info(pCustomerId As %String, pDeviceId As %String) As %DynamicObject
{
    Set o = {"trusted": 0}
    If '..Trusted(pCustomerId, pDeviceId) Quit o
    Set node = $GET(^PaymentGuardLearned("DeviceTrust", pCustomerId, pDeviceId))
    Do o.%Set("trusted", 1)
    Do o.%Set("uses", $LISTGET(node, 2, 0))
    Do o.%Set("learned_by", $LISTGET(node, 4, ""))
    Quit o
}

/// Learn trust for a pair after an approved human review. Returns
/// {"learned": 1} or {"learned": 0, "reason": ...}.
ClassMethod Learn(pCustomerId As %String, pDeviceId As %String, pReviewer As %String) As %DynamicObject
{
    If (pCustomerId = "") || (pDeviceId = "") Quit {"learned": 0, "reason": "missing_customer_or_device"}
    // Gate: a learned rule must never contradict a past decision — any
    // BLOCKED history of this pair vetoes the write.
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT COUNT(*) AS Cnt FROM PaymentGuard_Data.""Transaction"" WHERE CustomerId = ? AND DeviceId = ? AND Status = 'BLOCKED'")
    If $$$ISERR(tSC) Quit {"learned": 0, "reason": "gate_prepare_failed"}
    Set tRS = tStmt.%Execute(pCustomerId, pDeviceId)
    If tRS.%SQLCODE '= 0 Quit {"learned": 0, "reason": ("gate_sql_" _ tRS.%SQLCODE)}
    Do tRS.%Next()
    If tRS.%Get("Cnt") > 0 Quit {"learned": 0, "reason": "prior_blocked_history"}
    Do ..WriteEntry(pCustomerId, pDeviceId, pReviewer, ..#TTLDAYS * 24)
    Quit {"learned": 1, "ttl_days": (..#TTLDAYS)}
}

/// Write a raw entry (pTtlHours may be negative — the ops/test hook for
/// expiry checks). Keeps the previous use counter when the entry exists.
ClassMethod WriteEntry(pCustomerId As %String, pDeviceId As %String, pReviewer As %String, pTtlHours As %Integer) As %Status
{
    Set expiresDay = $Piece($Horolog, ",", 1) + (pTtlHours \ 24)
    Set node = $GET(^PaymentGuardLearned("DeviceTrust", pCustomerId, pDeviceId))
    Set uses = $Select(node = "": 0, 1: $LISTGET(node, 2, 0))
    Set ^PaymentGuardLearned("DeviceTrust", pCustomerId, pDeviceId) = $LISTBUILD(expiresDay, uses, $Piece($Horolog, ",", 1), pReviewer)
    Quit $$$OK
}

/// Count one more application of a learned rule (called by the rule engine
/// when LEARNED_DEVICE_FAST_PATH approves).
ClassMethod Touch(pCustomerId As %String, pDeviceId As %String)
{
    Set node = $GET(^PaymentGuardLearned("DeviceTrust", pCustomerId, pDeviceId))
    Quit:node=""
    Set ^PaymentGuardLearned("DeviceTrust", pCustomerId, pDeviceId) = $LISTBUILD($LISTGET(node, 1, 0), ($LISTGET(node, 2, 0) + 1), $LISTGET(node, 3, 0), $LISTGET(node, 4, ""))
    Quit
}

/// Demote a pair after a BLOCK decision. Returns 1 when an entry existed.
ClassMethod Demote(pCustomerId As %String, pDeviceId As %String) As %Boolean
{
    If '$DATA(^PaymentGuardLearned("DeviceTrust", pCustomerId, pDeviceId)) Quit 0
    Kill ^PaymentGuardLearned("DeviceTrust", pCustomerId, pDeviceId)
    Quit 1
}

/// Drop every learned entry (demo reset and the test suite).
ClassMethod Clear()
{
    Kill ^PaymentGuardLearned
    Quit
}

/// Number of live entries (dashboard/ops convenience).
ClassMethod Count() As %Integer
{
    Set today = $Piece($Horolog, ",", 1)
    Set n = 0, cid = ""
    For {
        Set cid = $ORDER(^PaymentGuardLearned("DeviceTrust", cid))
        Quit:cid=""
        Set did = ""
        For {
            Set did = $ORDER(^PaymentGuardLearned("DeviceTrust", cid, did))
            Quit:did=""
            If $LISTGET($GET(^PaymentGuardLearned("DeviceTrust", cid, did)), 1, 0) >= today Set n = n + 1
        }
    }
    Quit n
}

}
