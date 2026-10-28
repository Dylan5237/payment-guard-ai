Include (%occStatus)

/// Risk intelligence tools exposed to the AI Hub agent. Every method becomes
/// a callable tool automatically; the agent grounds its decisions in live
/// IRIS SQL through them.
Class PaymentGuard.Agent.Tools Extends %AI.Tool
{

/// Full customer profile by customer id, including segment, KYC status,
/// risk rating, trust score and average monthly spend. Use this first to
/// understand who is paying.
Method GetCustomerProfile(CustomerId As %String) As %DynamicObject
{
    Set o = {"found": 0}
    Set cust = ##class(PaymentGuard.Data.Customer).OpenByCustomerId(CustomerId)
    If '$IsObject(cust) {
        Do o.%Set("note", "Customer "_CustomerId_" is not known to the platform")
        Quit o
    }
    Do o.%Set("found", 1)
    Do o.%Set("name", cust.Name)
    Do o.%Set("segment", cust.Segment)
    Do o.%Set("country", cust.Country)
    Do o.%Set("risk_rating", cust.RiskRating)
    Do o.%Set("kyc_status", cust.KycStatus)
    Do o.%Set("blacklisted", cust.Blacklisted, "boolean")
    Do o.%Set("account_age_days", cust.AccountAgeDays)
    Do o.%Set("avg_monthly_usd", cust.AvgMonthlyUsd)
    Do o.%Set("trust_score", cust.TrustScore)
    Quit o
}

/// Recent payment attempts of a customer, newest first. Use to compare the
/// current payment against established behavior. For health-insurance claims
/// the rows also carry procedure, diagnosis and settlement city — use them to
/// spot the same member settling the same procedure in several cities.
Method GetRecentTransactions(CustomerId As %String, Days As %Integer) As %DynamicArray
{
    Set arr = []
    Set cutoff = ##class(PaymentGuard.Data.Enricher).HoursAgo(Days * 24)
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT TOP 10 Amount, Currency, Merchant, GeoCountry, Channel, TxnTime, Status, ""Procedure"", Diagnosis, City FROM PaymentGuard_Data.""Transaction"" WHERE CustomerId = ? AND TxnTime > ? ORDER BY TxnTime DESC")
    If $$$ISERR(tSC) Quit arr
    Set tRS = tStmt.%Execute(CustomerId, cutoff)
    While tRS.%Next() {
        Set row = {}
        Do row.%Set("amount", tRS.%Get("Amount"))
        Do row.%Set("currency", tRS.%Get("Currency"))
        Do row.%Set("merchant", tRS.%Get("Merchant"))
        Do row.%Set("geo_country", tRS.%Get("GeoCountry"))
        Do row.%Set("channel", tRS.%Get("Channel"))
        Do row.%Set("time", tRS.%Get("TxnTime"))
        Do row.%Set("status", tRS.%Get("Status"))
        If tRS.%Get("Procedure") '= "" {
            Do row.%Set("procedure", tRS.%Get("Procedure"))
            Do row.%Set("diagnosis", tRS.%Get("Diagnosis"))
            Do row.%Set("city", tRS.%Get("City"))
        }
        Do arr.%Push(row)
    }
    Quit arr
}

/// Payment velocity of a customer: how many attempts and how much volume in
/// the given lookback window (hours). Bursts are a classic fraud signal.
Method GetVelocity(CustomerId As %String, Hours As %Integer) As %DynamicObject
{
    Set o = {"count": 0, "total_usd": 0, "distinct_merchants": 0}
    Set cutoff = ##class(PaymentGuard.Data.Enricher).HoursAgo(Hours)
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT COUNT(*) AS Cnt, COALESCE(SUM(Amount),0) AS Total, COUNT(DISTINCT Merchant) AS Merch FROM PaymentGuard_Data.""Transaction"" WHERE CustomerId = ? AND TxnTime > ?")
    If $$$ISERR(tSC) Quit o
    Set tRS = tStmt.%Execute(CustomerId, cutoff)
    If tRS.%Next() {
        Do o.%Set("count", tRS.%Get("Cnt"))
        Do o.%Set("total_usd", tRS.%Get("Total"))
        Do o.%Set("distinct_merchants", tRS.%Get("Merch"))
    }
    Quit o
}

/// Reputation of a device id: how many payments, how many distinct customers
/// and countries it has been seen with, and when it first appeared.
Method GetDeviceHistory(DeviceId As %String) As %DynamicObject
{
    Set o = {"known": 0, "txn_count": 0, "customer_count": 0, "country_count": 0, "first_seen": ""}
    If DeviceId = "" Quit o
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT COUNT(*) AS Cnt, MIN(TxnTime) AS FirstSeen, COUNT(DISTINCT CustomerId) AS Custs, COUNT(DISTINCT GeoCountry) AS Countries FROM PaymentGuard_Data.""Transaction"" WHERE DeviceId = ?")
    If $$$ISERR(tSC) Quit o
    Set tRS = tStmt.%Execute(DeviceId)
    If tRS.%Next() {
        Set cnt = tRS.%Get("Cnt")
        Do o.%Set("txn_count", cnt)
        Do o.%Set("known", cnt > 0, "boolean")
        Do o.%Set("first_seen", tRS.%Get("FirstSeen"))
        Do o.%Set("customer_count", tRS.%Get("Custs"))
        Do o.%Set("country_count", tRS.%Get("Countries"))
    }
    Quit o
}

/// 30-day platform-wide profile of a merchant: volume, average ticket and
/// how often its payments end up blocked.
Method GetMerchantProfile(Merchant As %String) As %DynamicObject
{
    Set o = {"merchant": (Merchant), "txn_count_30d": 0, "avg_amount_30d": 0, "blocked_30d": 0}
    If Merchant = "" Quit o
    Set cutoff = ##class(PaymentGuard.Data.Enricher).HoursAgo(720)
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT COUNT(*) AS Cnt, COALESCE(AVG(Amount),0) AS AvgAmt, SUM(CASE WHEN Status = 'BLOCKED' THEN 1 ELSE 0 END) AS Blocked FROM PaymentGuard_Data.""Transaction"" WHERE Merchant = ? AND TxnTime > ?")
    If $$$ISERR(tSC) Quit o
    Set tRS = tStmt.%Execute(Merchant, cutoff)
    If tRS.%Next() {
        Do o.%Set("txn_count_30d", tRS.%Get("Cnt"))
        Do o.%Set("avg_amount_30d", tRS.%Get("AvgAmt"))
        Do o.%Set("blocked_30d", tRS.%Get("Blocked"))
    }
    Quit o
}

/// Semantic nearest neighbors of a transaction: IRIS Vector Search (cosine)
/// over 256-dimension feature embeddings computed by Embedded Python. Pass
/// the current transaction id to see which historical payments or claims
/// resemble it — the same procedure, provider, city or amount band ranks
/// highest. Use it to correlate a claim with near-identical settlements or
/// to check whether a payment matches a known fraud pattern.
Method SearchSimilarTransactions(TxnId As %String, TopN As %Integer = 5) As %DynamicObject
{
    Set o = {"query_txn_id": (TxnId), "results": []}
    Set feat = ##class(PaymentGuard.Vector.Embedder).TxnFeatures(TxnId)
    If feat = "" {
        Do o.%Set("note", "Transaction "_TxnId_" is not known to the platform")
        Quit o
    }
    Do o.%Set("results", ##class(PaymentGuard.Vector.Embedder).Search(feat, TopN, 0.35, TxnId))
    Quit o
}

}
