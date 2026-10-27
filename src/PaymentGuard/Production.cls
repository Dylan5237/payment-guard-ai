/// The PaymentGuard interoperability production.
///
/// REST callers enter through the PaymentGuard REST service; the decision
/// process orchestrates rules, the AI Hub risk agent and the downstream
/// operations. Every hop is visible in the Management Portal message viewer.
Class PaymentGuard.Production Extends Ens.Production
{

XData ProductionDefinition
{
<Production Name="PaymentGuard.Production" LogGeneralTraceEvents="false">
  <Description>AI Hub agent decisioning for payment risk</Description>
  <ActorPoolSize>2</ActorPoolSize>
  <Item Name="PaymentGuard REST" Category="" ClassName="PaymentGuard.REST.BS" PoolSize="1" Enabled="true" Foreground="false" Comment="" LogTraceEvents="false" Schedule="">
  </Item>
  <Item Name="PaymentGuard Decision" Category="" ClassName="PaymentGuard.Interop.DecisionBP" PoolSize="1" Enabled="true" Foreground="false" Comment="" LogTraceEvents="false" Schedule="">
  </Item>
  <Item Name="PaymentGuard AI Risk Agent" Category="AI" ClassName="PaymentGuard.Interop.AgentOperation" PoolSize="1" Enabled="true" Foreground="false" Comment="AI Hub agent operation - see also MockMode" LogTraceEvents="false" Schedule="">
    <Setting Target="Host" Name="MockMode">0</Setting>
  </Item>
  <Item Name="PaymentGuard Settlement" Category="" ClassName="PaymentGuard.Interop.SettleBO" PoolSize="1" Enabled="true" Foreground="false" Comment="" LogTraceEvents="false" Schedule="">
  </Item>
  <Item Name="PaymentGuard Review Queue" Category="" ClassName="PaymentGuard.Interop.ReviewBO" PoolSize="1" Enabled="true" Foreground="false" Comment="" LogTraceEvents="false" Schedule="">
  </Item>
  <Item Name="PaymentGuard Fraud Alerts" Category="" ClassName="PaymentGuard.Interop.AlertBO" PoolSize="1" Enabled="true" Foreground="false" Comment="" LogTraceEvents="false" Schedule="">
  </Item>
</Production>
}

}
