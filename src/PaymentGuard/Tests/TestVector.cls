Include (%occStatus)

/// IRIS Vector Search similarity over Embedded-Python feature embeddings:
/// determinism of the hasher, seeded-claim retrieval, context injection,
/// self-exclusion and the end-to-end wiring in the decision process.
Class PaymentGuard.Tests.TestVector Extends %UnitTest.TestCase
{

Method OnBeforeAllTests() As %Status
{
    Do ##class(PaymentGuard.Data.Populate).Seed(1)
    Quit ##class(PaymentGuard.Util.Setup).EnsureRunning()
}

/// A Beijing cataract-surgery claim filed at Beijing Union — same surgery as
/// memb_001's seeded Shanghai settlement, same provider as memb_002's
/// dialysis history.
ClassMethod CataractFeatures() As %String
{
    Quit {"amount": 12800, "currency": "CNY", "merchant": "Beijing Union Medical College Hospital", "merchant_category": "HEALTHCARE", "geo_country": "CN", "procedure": "CATARACT_SURGERY", "diagnosis": "H25.9", "city": "Beijing"}.%ToJSON()
}

ClassMethod DialysisFeatures() As %String
{
    Quit {"amount": 820, "currency": "CNY", "merchant": "Beijing Union Medical College Hospital", "merchant_category": "HEALTHCARE", "geo_country": "CN", "procedure": "HEMODIALYSIS", "diagnosis": "N18.5", "city": "Beijing"}.%ToJSON()
}

/// The hasher is deterministic and produces a 256-dim unit vector
Method TestEmbedIsDeterministicUnitVector()
{
    Set v1 = ##class(PaymentGuard.Vector.Embedder).Embed(..CataractFeatures())
    Set v2 = ##class(PaymentGuard.Vector.Embedder).Embed(..CataractFeatures())
    Do $$$AssertNotEquals(v1, "", "embedding produced")
    Do $$$AssertEquals(v1, v2, "identical input embeds identically")
    Set arr = ##class(%DynamicArray).%FromJSON(v1)
    Do $$$AssertEquals(arr.%Size(), 256, "256 dimensions")
    Set sum = 0
    For i = 0:1:arr.%Size() - 1 Set sum = sum + (arr.%Get(i) * arr.%Get(i))
    Do $$$AssertTrue((sum > 0.999) && (sum < 1.001), "L2 norm is 1, got "_sum)
}

/// A cataract claim surfaces the seeded Shanghai cataract settlement as the
/// top neighbor even though provider and city differ
Method TestCataractQueryFindsSeededClaim()
{
    Set arr = ##class(PaymentGuard.Vector.Embedder).Search(..CataractFeatures(), 5, 0.35, "")
    Do $$$AssertTrue(arr.%Size() >= 1, "at least one neighbor above threshold")
    Set top = arr.%Get(0)
    Do $$$AssertEquals(top.%Get("procedure"), "CATARACT_SURGERY", "top neighbor is the seeded cataract settlement")
    Do $$$AssertTrue(top.%Get("similarity") >= 0.6, "strong similarity, got "_top.%Get("similarity"))
}

/// An identical dialysis claim matches the seeded dialysis history at ~1.0
Method TestDialysisQueryRanksDialysisFirst()
{
    Set arr = ##class(PaymentGuard.Vector.Embedder).Search(..DialysisFeatures(), 5, 0.35, "")
    Do $$$AssertTrue(arr.%Size() >= 1, "dialysis history found")
    Set top = arr.%Get(0)
    Do $$$AssertEquals(top.%Get("procedure"), "HEMODIALYSIS", "top neighbor is a dialysis settlement")
    Do $$$AssertTrue(top.%Get("similarity") >= 0.95, "near-identical claim, got "_top.%Get("similarity"))
}

/// The enrichment context ships the vector neighbors to the agent
Method TestContextCarriesSimilarTransactions()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "memb_002", req.Amount = 12800, req.Currency = "CNY", req.GeoCountry = "CN"
    Set req.Merchant = "Beijing Union Medical College Hospital", req.MerchantCategory = "HEALTHCARE"
    Set req.Procedure = "CATARACT_SURGERY", req.Diagnosis = "H25.9", req.City = "Beijing"
    Set ctx = ##class(PaymentGuard.Data.Enricher).BuildContext(req, "", "pending_txn_1")
    Set sim = ctx.%Get("similar_transactions")
    Do $$$AssertTrue($IsObject(sim) && (sim.%Size() >= 1), "context carries similar_transactions")
    Set top = sim.%Get(0)
    Do $$$AssertEquals(top.%Get("procedure"), "CATARACT_SURGERY", "top context neighbor is the cataract settlement")
    Do $$$AssertNotEquals(top.%Get("txn_id"), "pending_txn_1", "the pending attempt itself is excluded")
}

/// The search never returns the query row, even at similarity 1.0
Method TestSelfExclusion()
{
    Set t = ##class(PaymentGuard.Data.Transaction).%New()
    Set t.TxnId = "selftest_vec_1", t.CustomerId = "memb_002", t.Amount = 12800, t.Currency = "CNY"
    Set t.Merchant = "Beijing Union Medical College Hospital", t.MerchantCategory = "HEALTHCARE"
    Set t.GeoCountry = "CN", t.Procedure = "CATARACT_SURGERY", t.Diagnosis = "H25.9", t.City = "Beijing"
    Set t.TxnTime = $ZDATETIME($HOROLOG, 3, 1), t.Status = "PENDING"
    Do $$$AssertStatusOK(t.%Save())
    Do $$$AssertStatusOK(##class(PaymentGuard.Vector.Embedder).EmbedAndStore("selftest_vec_1"))
    Set arr = ##class(PaymentGuard.Vector.Embedder).Search(..CataractFeatures(), 1, 0.0, "selftest_vec_1")
    Do $$$AssertEquals(arr.%Size(), 1, "one neighbor returned")
    Do $$$AssertNotEquals(arr.%Get(0).%Get("txn_id"), "selftest_vec_1", "identical self row excluded from its own search")
}

/// End to end: every payment the production persists gets an embedding
Method TestStoredTxnGetsEmbeddingEndToEnd()
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.CustomerId = "memb_001", req.Amount = 12800, req.Currency = "CNY", req.GeoCountry = "CN"
    Set req.Merchant = "Beijing Union Medical College Hospital", req.MerchantCategory = "HEALTHCARE"
    Set req.Procedure = "CATARACT_SURGERY", req.Diagnosis = "H25.9", req.City = "Beijing"
    Set sc = ##class(Ens.Director).CreateBusinessService("PaymentGuard REST", .tBS)
    Do $$$AssertStatusOK(sc)
    Set sc = tBS.SendRequestSync("PaymentGuard Decision", req, .resp, 60)
    Do $$$AssertStatusOK(sc)
    Set tStmt = ##class(%SQL.Statement).%New()
    Do tStmt.%Prepare("SELECT COUNT(*) AS C FROM PaymentGuard_Data.""Transaction"" WHERE TxnId = ? AND Embedding IS NOT NULL")
    Set tRS = tStmt.%Execute(resp.TxnId)
    Do $$$AssertTrue(tRS.%Next() && (tRS.%Get("C") = 1), "stored transaction carries an embedding")
}

}
