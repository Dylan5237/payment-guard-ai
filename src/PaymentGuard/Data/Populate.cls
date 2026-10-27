Include (%occStatus)

/// Demo data: customers with realistic profiles, 30 days of history, and a
/// transaction generator that mixes benign payments, gray-zone cases and
/// outright fraud patterns.
Class PaymentGuard.Data.Populate
{

/// Seed customers and history. pForce=1 wipes existing demo data first.
ClassMethod Seed(pForce As %Boolean = 0) As %Status
{
    If pForce {
        Do ##class(PaymentGuard.Data.CaseRecord).%KillExtent()
        Do ##class(PaymentGuard.Data.Decision).%KillExtent()
        Do ##class(PaymentGuard.Data.Transaction).%KillExtent()
        Do ##class(PaymentGuard.Data.Customer).%KillExtent()
    } Else {
        Set rs = ##class(%SQL.Statement).%New()
        Do rs.%Prepare("SELECT COUNT(*) AS C FROM PaymentGuard_Data.Customer")
        Set r = rs.%Execute()
        If r.%Next(), r.%Get("C") > 0 Quit $$$OK
    }

    Do ..Customer("cust_vip_001", "Marcus Vella", "VIP", "US", "LOW", "VERIFIED", 0, 2200, 12000, 92, "dev_vip_001")
    Do ..Customer("cust_ret_001", "Alice Tanaka", "RETAIL", "US", "LOW", "VERIFIED", 0, 1100, 900, 81, "dev_ret_001")
    Do ..Customer("cust_ret_002", "Bruno Costa", "RETAIL", "BR", "LOW", "VERIFIED", 0, 800, 700, 68, "dev_ret_002")
    Do ..Customer("cust_ret_003", "Chen Wei", "RETAIL", "CN", "MEDIUM", "PENDING", 0, 300, 500, 55, "dev_ret_003")
    Do ..Customer("cust_sme_001", "SofiaCare Lda", "SME", "PT", "LOW", "VERIFIED", 0, 1500, 9000, 74, "dev_sme_001")
    Do ..Customer("cust_sme_002", "MetroTech GmbH", "SME", "DE", "MEDIUM", "VERIFIED", 0, 900, 15000, 66, "dev_sme_002")
    Do ..Customer("cust_risk_001", "Viktor Sokolov", "RETAIL", "RU", "HIGH", "VERIFIED", 0, 400, 400, 30, "dev_risk_001")
    Do ..Customer("cust_blk_001", "Nigel Pryce", "RETAIL", "GB", "MEDIUM", "VERIFIED", 1, 500, 600, 20, "dev_blk_001")

    Do ..History("cust_vip_001", "dev_vip_001", "US", 12, 800, 4000, "Amazon", "LuxWatch Ltd")
    Do ..History("cust_ret_001", "dev_ret_001", "US", 14, 20, 200, "Amazon", "Uber")
    Do ..History("cust_ret_002", "dev_ret_002", "BR", 10, 15, 180, "AliExpress", "Uber")
    Do ..History("cust_ret_003", "dev_ret_003", "CN", 6, 10, 90, "AliExpress", "Steam")
    Do ..History("cust_sme_001", "dev_sme_001", "PT", 8, 1000, 9000, "AWS", "Dell")
    Do ..History("cust_sme_002", "dev_sme_002", "DE", 9, 2000, 14000, "AWS", "Siemens")
    Do ..History("cust_risk_001", "dev_risk_001", "RU", 5, 30, 300, "Steam", "FastElectronics")

    Quit $$$OK
}

ClassMethod Customer(pId As %String, pName As %String, pSegment As %String, pCountry As %String, pRisk As %String, pKyc As %String, pBlacklist As %Boolean, pAgeDays As %Integer, pAvgMonthly As %Numeric, pTrust As %Integer, pDevice As %String) As %Status
{
    Set c = ##class(PaymentGuard.Data.Customer).%New()
    Set c.CustomerId = pId
    Set c.Name = pName
    Set c.Segment = pSegment
    Set c.Country = pCountry
    Set c.RiskRating = pRisk
    Set c.KycStatus = pKyc
    Set c.Blacklisted = pBlacklist
    Set c.AccountAgeDays = pAgeDays
    Set c.AvgMonthlyUsd = pAvgMonthly
    Set c.TrustScore = pTrust
    Quit c.%Save()
}

/// n settled transactions spread over the last 30 days for one customer
ClassMethod History(pCustomerId As %String, pDeviceId As %String, pCountry As %String, pCount As %Integer, pMinAmt As %Numeric, pMaxAmt As %Numeric, pMerchant1 As %String, pMerchant2 As %String) As %Status
{
    For i = 1:1:pCount {
        Set t = ##class(PaymentGuard.Data.Transaction).%New()
        Set t.TxnId = "hist_"_pCustomerId_"_"_i
        Set t.CustomerId = pCustomerId
        Set t.Amount = pMinAmt + $RANDOM((pMaxAmt - pMinAmt) \ 10 + 1) * 10
        Set t.Currency = "USD"
        Set t.Merchant = $Select($RANDOM(2): pMerchant1, 1: pMerchant2)
        Set t.MerchantCategory = $Select(t.Merchant = "Steam": "GAMING", t.Merchant = "AWS": "CLOUD", t.Merchant = "Uber": "TRANSPORT", 1: "RETAIL")
        Set t.Channel = $Select($RANDOM(2): "ECOM", 1: "CARD")
        Set t.GeoCountry = pCountry
        Set t.DeviceId = pDeviceId
        Set t.TxnTime = $ZDATETIME($ZHOROLOG - $RANDOM(720), 3, 1)
        Set t.Status = "SETTLED"
        Do t.%Save()
    }
    Quit $$$OK
}

/// Generate one random payment request: ~55% benign, ~25% gray zone,
/// ~20% fraud-flavored.
ClassMethod GenTxn() As PaymentGuard.Request.Payment
{
    Set req = ##class(PaymentGuard.Request.Payment).%New()
    Set req.TxnId = "txn_"_$ZDATETIME($ZHOROLOG, 8)_"_"_$RANDOM(999999)
    Set pattern = $RANDOM(100)

    If pattern < 55 {
        // Benign: regular customer, home country, known device, usual amount
        Set ids = $ListBuild("cust_ret_001", "cust_ret_002", "cust_sme_001", "cust_vip_001")
        Set req.CustomerId = $List(ids, $RANDOM(4) + 1)
        Set req.Amount = 10 + $RANDOM(150)
        Set req.GeoCountry = $Select(req.CustomerId = "cust_ret_001": "US", req.CustomerId = "cust_ret_002": "BR", req.CustomerId = "cust_sme_001": "PT", 1: "US")
        Set req.DeviceId = $Select(req.CustomerId = "cust_ret_001": "dev_ret_001", req.CustomerId = "cust_ret_002": "dev_ret_002", req.CustomerId = "cust_sme_001": "dev_sme_001", 1: "dev_vip_001")
        Set req.Merchant = $List($ListBuild("Amazon", "Uber", "Shell", "Steam"), $Random(4) + 1)
        Set req.Channel = "ECOM"
    } ElseIf pattern < 80 {
        // Gray zone: plausible but unusual - new device, odd hours, odd geo
        Set ids = $ListBuild("cust_ret_003", "cust_sme_002", "cust_ret_001", "cust_risk_001")
        Set req.CustomerId = $List(ids, $RANDOM(4) + 1)
        Set req.Amount = 250 + $RANDOM(1200)
        Set req.GeoCountry = $List($ListBuild("SG", "HK", "AE", "TR"), $RANDOM(4) + 1)
        Set req.DeviceId = "dev_new_"_$RANDOM(500)
        Set req.Merchant = $List($ListBuild("FastElectronics", "LuxWatch Ltd", "TravelHub", "GadgetWorld"), $RANDOM(4) + 1)
        Set req.Channel = $List($ListBuild("CARD", "ECOM"), $RANDOM(2) + 1)
    } Else {
        // Fraud flavored: shared device, watchlist geo, high amount, hot merchant
        Set ids = $ListBuild("cust_ret_001", "cust_ret_003", "cust_sme_002")
        Set req.CustomerId = $List(ids, $RANDOM(3) + 1)
        Set req.Amount = 900 + $RANDOM(3500)
        Set req.GeoCountry = $List($ListBuild("NG", "RU", "VE", "PK"), $RANDOM(4) + 1)
        Set req.DeviceId = "dev_shared_7"
        Set req.Merchant = $List($ListBuild("CryptoExchange X", "LuxWatch Ltd", "FastElectronics"), $RANDOM(3) + 1)
        Set req.Channel = "CARD"
    }

    Set req.Currency = "USD"
    Set req.MerchantCategory = $Select(req.Merchant = "CryptoExchange X": "CRYPTO", req.Merchant = "LuxWatch Ltd": "LUXURY", req.Merchant = "FastElectronics": "ELECTRONICS", req.Merchant = "Steam": "GAMING", 1: "RETAIL")
    Quit req
}

}
