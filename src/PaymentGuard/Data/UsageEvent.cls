Include (%occStatus)

/// Anonymous usage beacons from the demo dashboard. No raw IP or personal
/// data is stored; VisitorId and SessionId are random ids generated in the
/// browser.
Class PaymentGuard.Data.UsageEvent Extends %Persistent
{

/// page_view | flow_open | decision_open
Property Event As %String(MAXLEN = 40) [ Required ];

Property EventTime As %TimeStamp [ InitialExpression = {$ZDATETIME($HOROLOG,3,1)} ];

Property Path As %String(MAXLEN = 200);

/// Random id persisted in the browser's localStorage
Property VisitorId As %String(MAXLEN = 64);

/// Random id persisted in sessionStorage (one browsing session)
Property SessionId As %String(MAXLEN = 64);

Property Referrer As %String(MAXLEN = 300);

Property UserAgent As %String(MAXLEN = 300);

Index EventTimeIdx On EventTime;

Index EventIdx On (Event, EventTime);

Index VisitorIdx On VisitorId;

}
