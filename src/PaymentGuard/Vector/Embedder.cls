Include (%occStatus)

/// Transaction embeddings and IRIS Vector Search similarity.
///
/// EmbedPy is a [Language = python] method that turns the structured
/// transaction features (procedure, provider, city, channel, amount band...)
/// into a 256-dimension L2-normalized embedding via signed feature hashing.
/// Pure standard library: no external embedding API, deterministic, and
/// identical inputs always produce the identical vector — so a query
/// embedding can be recomputed from the row's features without ever reading
/// a stored vector back. Cosine similarity between two embeddings measures
/// how much two transactions share, which powers two things: the
/// `similar_transactions` section of the risk context, and the agent's
/// SearchSimilarTransactions tool. If Embedded Python or the vector column
/// is unavailable the search quietly returns no rows — it is evidence, never
/// a load-bearing input.
Class PaymentGuard.Vector.Embedder
{

/// Embed a feature JSON object. Returns the vector as a JSON array string,
/// or "" when embedding is not possible (caller skips the evidence).
ClassMethod Embed(pFeatureJson As %String) As %String
{
    Set vec = ""
    Try {
        Set vec = ..EmbedPy(pFeatureJson)
    } Catch ex {
        Set vec = ""
    }
    If vec'[ """error""" Quit vec
    Quit ""
}

ClassMethod EmbedPy(pFeatureJson As %String) As %String [ Language = python ]
{
import json, hashlib, math

DIMS = 256
FEATS = [
    ("procedure", 3.0),
    ("diagnosis", 2.5),
    ("merchant", 2.0),
    ("merchant_category", 1.2),
    ("city", 1.5),
    ("channel", 0.8),
    ("geo_country", 0.8),
    ("currency", 0.4),
]

try:
    f = json.loads(pFeatureJson)
except Exception:
    return json.dumps({"error": "parse_failed"})

vec = [0.0] * DIMS

def slot(name):
    d = hashlib.sha256(name.encode("utf-8")).digest()
    idx = ((d[0] << 8) | d[1]) % DIMS
    sign = 1.0 if (d[2] & 1) == 0 else -1.0
    return idx, sign

for name, weight in FEATS:
    v = str(f.get(name) or "").strip().upper()
    if v:
        idx, sign = slot(name + "=" + v)
        vec[idx] += sign * weight

try:
    amt = float(f.get("amount") or 0)
except (TypeError, ValueError):
    amt = 0.0
if amt > 0:
    band = int(math.log10(amt) * 4.0)
    for off, kernel in ((-1, 0.6), (0, 1.0), (1, 0.6)):
        idx, sign = slot("amount_band=" + str(band + off))
        vec[idx] += sign * 1.5 * kernel

norm = math.sqrt(sum(x * x for x in vec))
if norm == 0.0:
    return json.dumps({"error": "no_features"})

return json.dumps([round(x / norm, 5) for x in vec])
}

/// Feature JSON of a stored transaction row (same shape RequestFeatures
/// builds for a live request). "" when the row does not exist.
ClassMethod TxnFeatures(pTxnId As %String) As %String
{
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT Amount, Currency, Merchant, MerchantCategory, Channel, GeoCountry, ""Procedure"", Diagnosis, City FROM PaymentGuard_Data.""Transaction"" WHERE TxnId = ?")
    If $$$ISERR(tSC) Quit ""
    Set tRS = tStmt.%Execute(pTxnId)
    If 'tRS.%Next() Quit ""
    Quit ..RowToFeatures(tRS)
}

/// Feature JSON of a live payment request (currency defaults like the BP).
ClassMethod RequestFeatures(pReq As PaymentGuard.Request.Payment) As %String
{
    Set o = {}
    Do o.%Set("amount", pReq.Amount)
    Do o.%Set("currency", $Select(pReq.Currency '="": pReq.Currency, 1: "USD"))
    Do o.%Set("merchant", pReq.Merchant)
    Do o.%Set("merchant_category", pReq.MerchantCategory)
    Do o.%Set("channel", pReq.Channel)
    Do o.%Set("geo_country", pReq.GeoCountry)
    Do o.%Set("procedure", pReq.Procedure)
    Do o.%Set("diagnosis", pReq.Diagnosis)
    Do o.%Set("city", pReq.City)
    Quit o.%ToJSON()
}

ClassMethod RowToFeatures(pRS As %SQL.StatementResult) As %String
{
    Set o = {}
    Do o.%Set("amount", pRS.%Get("Amount"))
    Do o.%Set("currency", pRS.%Get("Currency"))
    Do o.%Set("merchant", pRS.%Get("Merchant"))
    Do o.%Set("merchant_category", pRS.%Get("MerchantCategory"))
    Do o.%Set("channel", pRS.%Get("Channel"))
    Do o.%Set("geo_country", pRS.%Get("GeoCountry"))
    Do o.%Set("procedure", pRS.%Get("Procedure"))
    Do o.%Set("diagnosis", pRS.%Get("Diagnosis"))
    Do o.%Set("city", pRS.%Get("City"))
    Quit o.%ToJSON()
}

/// Compute and persist the embedding of one stored row.
ClassMethod EmbedAndStore(pTxnId As %String) As %Status
{
    Set feat = ..TxnFeatures(pTxnId)
    If feat = "" Quit $$$ERROR($$$GeneralError, "transaction not found: "_pTxnId)
    Set vec = ..Embed(feat)
    If vec = "" Quit $$$ERROR($$$GeneralError, "embedding failed for "_pTxnId)
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("UPDATE PaymentGuard_Data.""Transaction"" SET Embedding = TO_VECTOR(?, DOUBLE) WHERE TxnId = ?")
    If $$$ISERR(tSC) Quit tSC
    Set tRS = tStmt.%Execute(vec, pTxnId)
    If tRS.%SQLCODE < 0 Quit $$$ERROR($$$GeneralError, "embedding update failed sqlcode="_tRS.%SQLCODE)
    Quit $$$OK
}

/// Embed every stored transaction that has no vector yet — seed history and
/// databases created before this feature. Returns the number of rows stored.
ClassMethod Backfill() As %Integer
{
    Set count = 0
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT TxnId FROM PaymentGuard_Data.""Transaction"" WHERE Embedding IS NULL")
    If $$$ISERR(tSC) Quit 0
    Set tRS = tStmt.%Execute()
    While tRS.%Next() {
        If $$$ISOK(..EmbedAndStore(tRS.%Get("TxnId"))) Set count = count + 1
    }
    Quit count
}

/// Top-K cosine neighbors of a feature JSON. IRIS Vector Search over the
/// Embedding column; pExcludeTxnId skips the query row itself. Rows below
/// pMinSim are dropped — they are noise, not evidence.
ClassMethod Search(pFeatureJson As %String, pLimit As %Integer = 5, pMinSim As %Float = 0.35, pExcludeTxnId As %String = "") As %DynamicArray
{
    Set arr = []
    Set vec = ..Embed(pFeatureJson)
    If vec = "" Quit arr
    // an empty-string ? binds as NULL and TxnId <> NULL is never true, so
    // the exclusion clause is only added when there is an id to exclude
    Set sql = "SELECT TOP ? TxnId, CustomerId, Amount, Currency, Merchant, ""Procedure"", Diagnosis, City, Status, TxnTime, VECTOR_COSINE(Embedding, TO_VECTOR(?, DOUBLE)) AS similarity FROM PaymentGuard_Data.""Transaction"" WHERE Embedding IS NOT NULL"
    If pExcludeTxnId '= "" Set sql = sql_" AND TxnId <> ?"
    Set sql = sql_" ORDER BY similarity DESC"
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare(sql)
    If $$$ISERR(tSC) Quit arr
    If pExcludeTxnId '= "" {
        Set tRS = tStmt.%Execute(pLimit, vec, pExcludeTxnId)
    } Else {
        Set tRS = tStmt.%Execute(pLimit, vec)
    }
    While tRS.%Next() {
        Set sim = tRS.%Get("similarity")
        If sim < pMinSim Quit
        Set row = {}
        Do row.%Set("txn_id", tRS.%Get("TxnId"))
        Do row.%Set("customer_id", tRS.%Get("CustomerId"))
        Do row.%Set("amount", tRS.%Get("Amount"))
        Do row.%Set("currency", tRS.%Get("Currency"))
        Do row.%Set("merchant", tRS.%Get("Merchant"))
        If tRS.%Get("Procedure") '= "" {
            Do row.%Set("procedure", tRS.%Get("Procedure"))
            Do row.%Set("diagnosis", tRS.%Get("Diagnosis"))
            Do row.%Set("city", tRS.%Get("City"))
        }
        Do row.%Set("status", tRS.%Get("Status"))
        Do row.%Set("time", tRS.%Get("TxnTime"))
        Do row.%Set("similarity", +$Justify(sim, 0, 3))
        Do arr.%Push(row)
    }
    Quit arr
}

}
