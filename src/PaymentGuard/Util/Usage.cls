Include (%occStatus)

/// Aggregates the anonymous usage beacons for the admin report.
Class PaymentGuard.Util.Usage
{

ClassMethod Report(pDays As %Integer = 30) As %DynamicObject
{
    If pDays < 1 Set pDays = 1
    If pDays > 365 Set pDays = 365

    Set sinceDay = $ZDate($HOROLOG - (pDays - 1), 3)
    Set today = $ZDate($HOROLOG, 3)

    // Don't render days before usage tracking started: start at the first
    // recorded event (or at the range start if tracking is older than it).
    Set firstDay = ""
    Set fStmt = ##class(%SQL.Statement).%New()
    Set fSC = fStmt.%Prepare("SELECT MIN(EventTime) AS F FROM PaymentGuard_Data.UsageEvent")
    If $$$ISOK(fSC) {
        Set fRS = fStmt.%Execute()
        If fRS.%Next(), fRS.%Get("F") '= "" Set firstDay = $Piece(fRS.%Get("F"), " ", 1)
    }
    If firstDay '= "" {
        Set firstH = $ZDateH(firstDay, 3)
        Set sinceH = $ZDateH(sinceDay, 3)
        If firstH > sinceH Set sinceDay = firstDay
    }
    Set since = sinceDay _ " 00:00:00"

    Set out = {}
    Do out.%Set("days", pDays)
    Do out.%Set("since", sinceDay)
    Do out.%Set("generated_at", $ZDATETIME($HOROLOG, 3, 1))

    Set views = 0, todayViews = 0
    Set stmt = ##class(%SQL.Statement).%New()
    Set sc = stmt.%Prepare("SELECT EventTime, VisitorId, SessionId FROM PaymentGuard_Data.UsageEvent WHERE Event = 'page_view' AND EventTime >= ? ORDER BY EventTime")
    If $$$ISOK(sc) {
        Set rs = stmt.%Execute(since)
        While rs.%Next() {
            Set ts = rs.%Get("EventTime")
            Set d = $Piece(ts, " ", 1)
            Set v = rs.%Get("VisitorId")
            Set s = rs.%Get("SessionId")
            Set views = views + 1
            Set dayViews(d) = $Get(dayViews(d)) + 1
            If d = today Set todayViews = todayViews + 1
            If v '= "" Set allVisitors(v) = 1
            If s '= "" Set allSessions(s) = 1
            If v '= "" Set dayVisitors(d, v) = 1
            If (d = today) && (v '= "") Set todayVisitors(v) = 1
        }
    }

    Set totals = {}
    Do totals.%Set("views", views)
    Do totals.%Set("visitors", ..SetCount(.allVisitors))
    Do totals.%Set("sessions", ..SetCount(.allSessions))
    Do out.%Set("total", totals)

    Set todayObj = {}
    Do todayObj.%Set("views", todayViews)
    Do todayObj.%Set("visitors", ..SetCount(.todayVisitors))
    Do out.%Set("today", todayObj)

    Set daily = []
    If (firstDay '= "") && (views > 0) {
        Set startH = $ZDateH(sinceDay, 3)
        Set endH = $Piece($HOROLOG, ",", 1)
        For i = startH:1:endH {
            Set d = $ZDate(i, 3)
            Set dv = 0
            Set k = ""
            For {
                Set k = $Order(dayVisitors(d, k))
                Quit:k=""
                Set dv = dv + 1
            }
            Do daily.%Push({"date": (d), "views": (+$Get(dayViews(d))), "visitors": (dv)})
        }
    }
    Do out.%Set("daily", daily)

    Set events = []
    Set eStmt = ##class(%SQL.Statement).%New()
    Set eSC = eStmt.%Prepare("SELECT Event, COUNT(*) AS Cnt FROM PaymentGuard_Data.UsageEvent WHERE EventTime >= ? GROUP BY Event ORDER BY Cnt DESC")
    If $$$ISOK(eSC) {
        Set eRS = eStmt.%Execute(since)
        While eRS.%Next() {
            Do events.%Push({"event": ($ZConvert(eRS.%Get("Event"), "L")), "count": (+eRS.%Get("Cnt"))})
        }
    }
    Do out.%Set("events", events)

    Set refMap = {}
    Set rStmt = ##class(%SQL.Statement).%New()
    Set rSC = rStmt.%Prepare("SELECT Referrer, COUNT(*) AS Cnt FROM PaymentGuard_Data.UsageEvent WHERE Event = 'page_view' AND EventTime >= ? GROUP BY Referrer")
    If $$$ISOK(rSC) {
        Set rRS = rStmt.%Execute(since)
        While rRS.%Next() {
            Set host = ..Host(rRS.%Get("Referrer"))
            Do refMap.%Set(host, +refMap.%Get(host) + +rRS.%Get("Cnt"))
        }
    }
    Set byCount = 0
    Set iter = refMap.%GetIterator()
    While iter.%GetNext(.host, .cnt) {
        Set byCount(cnt, host) = ""
    }
    Set referrers = []
    Set n = 0, cnt = ""
    For {
        Set cnt = $Order(byCount(cnt), -1)
        Quit:cnt=""
        Set host = ""
        For {
            Set host = $Order(byCount(cnt, host))
            Quit:host=""
            Do referrers.%Push({"referrer": (host), "count": (+cnt)})
            Set n = n + 1
            Quit:n>=10
        }
        Quit:n>=10
    }
    Do out.%Set("referrers", referrers)

    Set recent = []
    Set recStmt = ##class(%SQL.Statement).%New()
    Set recSC = recStmt.%Prepare("SELECT TOP 30 EventTime, Event, Path, VisitorId, Referrer, UserAgent FROM PaymentGuard_Data.UsageEvent ORDER BY ID DESC")
    If $$$ISOK(recSC) {
        Set recRS = recStmt.%Execute()
        While recRS.%Next() {
            Do recent.%Push({
                "time": (recRS.%Get("EventTime")),
                "event": (recRS.%Get("Event")),
                "path": (recRS.%Get("Path")),
                "visitor": ($Extract(recRS.%Get("VisitorId"), 1, 8)),
                "referrer": (recRS.%Get("Referrer")),
                "ua": ($Extract(recRS.%Get("UserAgent"), 1, 90))
            })
        }
    }
    Do out.%Set("recent", recent)

    Quit out
}

ClassMethod SetCount(ByRef pSet) As %Integer
{
    Set n = 0, k = ""
    For {
        Set k = $Order(pSet(k))
        Quit:k=""
        Set n = n + 1
    }
    Quit n
}

ClassMethod Host(pRef As %String) As %String
{
    Set pRef = $ZStrip(pRef, "<>W")
    If pRef = "" Quit "(direct)"
    Set pos = $Find(pRef, "://")
    If pos Set pRef = $Extract(pRef, pos, $Length(pRef))
    Set pRef = $Piece(pRef, "/", 1)
    Set pRef = $Piece(pRef, "?", 1)
    If pRef = "" Quit "(direct)"
    Quit $ZConvert($Extract(pRef, 1, 120), "L")
}

}
