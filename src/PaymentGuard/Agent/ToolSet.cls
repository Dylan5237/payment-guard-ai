/// ToolSet packaging the risk intelligence tools for the agent.
Class PaymentGuard.Agent.ToolSet Extends %AI.ToolSet [ DependsOn = PaymentGuard.Agent.Tools ]
{

XData Definition [ MimeType = application/xml ]
{
<ToolSet Name="PaymentGuard">
  <Description>Read-only risk intelligence tools over payment platform data stored in IRIS: customer profiles, transaction history, velocity, device reputation, merchant statistics and health-insurance claim fields (member, provider, procedure, city).</Description>
  <Include Class="PaymentGuard.Agent.Tools"/>
</ToolSet>
}

}
