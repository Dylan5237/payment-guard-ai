Include (%occStatus)

/// Builds the risk context for a payment: customer profile, velocity counters,
/// recent history, device and merchant intelligence. Used by the decision
/// process before the rule engine runs, and shipped to the AI Hub agent.
Class PaymentGuard.Data.Enricher
{

/// Build the enrichment context for a payment request.
/// pCust may be "" (unknown customer) — the context then reflects that fact.
ClassMethod BuildContext(pReq As PaymentGuard.Request.Payment, pCust As PaymentGuard.Data.Customer) As %DynamicObject
{
    Set ctx = {}
    Do ctx.%Set("customer", ..CustomerObject(pCust, pReq.CustomerId))
    Do ctx.%Set("velocity_1h", ..Velocity(pReq.CustomerId, 1))
    Do ctx.%Set("velocity_24h", ..Velocity(pReq.CustomerId, 24))
    Do ctx.%Set("recent_transactions", ..RecentTransactions(pReq.CustomerId, 5))
    Do ctx.%Set("device", ..DeviceHistory(pReq.DeviceId))
    Do ctx.%Set("merchant", ..MerchantProfile(pReq.Merchant))
    Quit ctx
}

ClassMethod CustomerObject(pCust As PaymentGuard.Data.Customer, pCustomerId As %String) As %DynamicObject
{
    Set o = {}
    If '$IsObject(pCust) {
        Do o.%Set("customer_id", pCustomerId)
        Do o.%Set("known", 0)
        Do o.%Set("note", "Customer not found in platform records")
        Quit o
    }
    Do o.%Set("customer_id", pCust.CustomerId)
    Do o.%Set("name", pCust.Name)
    Do o.%Set("known", 1)
    Do o.%Set("segment", pCust.Segment)
    Do o.%Set("country", pCust.Country)
    Do o.%Set("risk_rating", pCust.RiskRating)
    Do o.%Set("kyc_status", pCust.KycStatus)
    Do o.%Set("blacklisted", pCust.Blacklisted, "boolean")
    Do o.%Set("account_age_days", pCust.AccountAgeDays)
    Do o.%Set("avg_monthly_usd", pCust.AvgMonthlyUsd)
    Do o.%Set("trust_score", pCust.TrustScore)
    Quit o
}

/// %TimeStamp exactly pHours hours ago (safe for any lookback window).
ClassMethod HoursAgo(pHours As %Integer) As %String
{
    Set day = $Piece($Horolog, ",", 1)
    Set sec = $Piece($Horolog, ",", 2) - (pHours * 3600)
    Set day = day + (sec \ 86400)
    Set sec = sec # 86400
    If sec < 0 Set day = day - 1, sec = sec + 86400
    Quit $ZDateTime(day_","_sec, 3, 1)
}

/// Count/sum of payment attempts in the last pHours hours (blocked attempts
/// included — they matter for velocity).
ClassMethod Velocity(pCustomerId As %String, pHours As %Integer) As %DynamicObject
{
    Set o = {"count": 0, "total_usd": 0, "avg_usd": 0, "distinct_merchants": 0}
    If pCustomerId = "" Quit o
    Set cutoff = ..HoursAgo(pHours)
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT COUNT(*) AS Cnt, COALESCE(SUM(Amount),0) AS Total, COUNT(DISTINCT Merchant) AS Merch FROM PaymentGuard_Data.""Transaction"" WHERE CustomerId = ? AND TxnTime > ?")
    If $$$ISERR(tSC) Quit o
    Set tRS = tStmt.%Execute(pCustomerId, cutoff)
    If tRS.%Next() {
        Do o.%Set("count", tRS.%Get("Cnt"))
        Do o.%Set("total_usd", tRS.%Get("Total"))
        Do o.%Set("avg_usd", $Select(tRS.%Get("Cnt") > 0: tRS.%Get("Total") / tRS.%Get("Cnt"), 1: 0))
        Do o.%Set("distinct_merchants", tRS.%Get("Merch"))
    }
    Quit o
}

ClassMethod RecentTransactions(pCustomerId As %String, pLimit As %Integer) As %DynamicArray
{
    Set arr = []
    If pCustomerId = "" Quit arr
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT TOP ? Amount, Currency, Merchant, MerchantCategory, GeoCountry, Channel, TxnTime, Status, ""Procedure"", Diagnosis, City FROM PaymentGuard_Data.""Transaction"" WHERE CustomerId = ? ORDER BY TxnTime DESC")
    If $$$ISERR(tSC) Quit arr
    Set tRS = tStmt.%Execute(pLimit, pCustomerId)
    While tRS.%Next() {
        Set row = {}
        Do row.%Set("amount", tRS.%Get("Amount"))
        Do row.%Set("currency", tRS.%Get("Currency"))
        Do row.%Set("merchant", tRS.%Get("Merchant"))
        Do row.%Set("merchant_category", tRS.%Get("MerchantCategory"))
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

/// Reputation of the device seen on this payment. A device shared across
/// customers, or seen in many countries, is a classic fraud signal.
ClassMethod DeviceHistory(pDeviceId As %String) As %DynamicObject
{
    Set o = {"known": 0, "txn_count": 0, "customer_count": 0, "country_count": 0, "first_seen": ""}
    If pDeviceId = "" {
        Do o.%Set("note", "No device id supplied")
        Quit o
    }
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT COUNT(*) AS Cnt, MIN(TxnTime) AS FirstSeen, COUNT(DISTINCT CustomerId) AS Custs, COUNT(DISTINCT GeoCountry) AS Countries FROM PaymentGuard_Data.""Transaction"" WHERE DeviceId = ?")
    If $$$ISERR(tSC) Quit o
    Set tRS = tStmt.%Execute(pDeviceId)
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

/// 30-day profile of the merchant.
ClassMethod MerchantProfile(pMerchant As %String) As %DynamicObject
{
    Set o = {"merchant": (pMerchant), "txn_count_30d": 0, "avg_amount_30d": 0, "blocked_30d": 0}
    If pMerchant = "" Quit o
    Set cutoff = ..HoursAgo(720)
    Set tStmt = ##class(%SQL.Statement).%New()
    Set tSC = tStmt.%Prepare("SELECT COUNT(*) AS Cnt, COALESCE(AVG(Amount),0) AS AvgAmt, SUM(CASE WHEN Status = 'BLOCKED' THEN 1 ELSE 0 END) AS Blocked FROM PaymentGuard_Data.""Transaction"" WHERE Merchant = ? AND TxnTime > ?")
    If $$$ISERR(tSC) Quit o
    Set tRS = tStmt.%Execute(pMerchant, cutoff)
    If tRS.%Next() {
        Set cnt = tRS.%Get("Cnt")
        Do o.%Set("txn_count_30d", cnt)
        Do o.%Set("avg_amount_30d", tRS.%Get("AvgAmt"))
        Do o.%Set("blocked_30d", tRS.%Get("Blocked"))
        If cnt > 0 Do o.%Set("block_rate_30d", tRS.%Get("Blocked") / cnt)
    }
    Quit o
}

}
