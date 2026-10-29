# PaymentGuard AI：让 AI Hub Agent 在 IRIS 互操作生产里管支付风控

*本文是[英文参赛文章](https://community.intersystems.com/post/paymentguard-ai-ai-hub-agent-fraud-decision-maker-inside-iris-interoperability-production)的中文版。源码：[github.com/Dylan5237/payment-guard-ai](https://github.com/Dylan5237/payment-guard-ai)*

支付授权，本质上是个决策问题。

大多数支付没什么可纠结的：老客户、熟悉的金额、常用的设备，几条确定性规则微秒级就能放行或拦下。真正难的是中间那片灰区——新设备、不常见的国家、比平时高出一截的金额、KYC 还没过审的客户。人工分析师的时间基本都耗在这里，而这恰恰是大模型 Agent 能帮上忙的地方——前提是它手里有真工具，查得到真数据。

PaymentGuard AI 做的事就这么直接：把一个真实的 IRIS AI Hub Agent（`%AI.Agent`）当成一个业务操作，塞进一条普通的互操作生产里。Agent 不瞎猜——它通过 AI Hub 的 SQL 工具直接查支付平台自己的 IRIS 库，查完按严格的 JSON 格式给结论；剩下的路由、审计、算 token 成本，生产全接管。

## 混合决策：规则打头，Agent 收尾

每笔支付进生产后走三段：

- **确定性规则先上。** 制裁地区、黑名单、硬性限额、速率尖峰，命中即拦；完全可信的客户加小额加常用设备加本地，直接放行。这一段一个 token 都不花。
- **灰区才轮到 AI。** 真实的 `%AI.Agent`（生产里叫 "AI Risk Agent"），带六个只读 SQL 工具：客户画像、近期交易、支付速率、设备信誉、商户统计、语义相似检索。查什么由 Agent 自己决定，最后给出 APPROVE / REVIEW / BLOCK。
- **AI 出错也兜得住。** Agent 报错、超时、输出格式不对，支付一律降级进人工审核队列——绝不静默放行，也绝不无脑拦截。

不管决策来自规则、Agent、mock 还是兜底路径，每一条都落成不可变的审计记录：prompt/completion token 数、工具调用次数、延迟、模型，还有可回放的 AI Hub 会话 id（`%AI.Agent.Session` 随时重放）。

## 演示视频

<https://youtu.be/ZcotKFBElKM>

四分钟看完全流程：规则秒断、零 token 成本；灰区交给 AI Hub Agent 和它的 SQL 工具；医保理赔场景（跨城重复报销、Agent 关联理赔、黑名单机构）；一组爆发式支付里 Agent 自己把三笔关联起来，认出账户盗用模式；最后是审计链路——token、延迟、可回放会话 id 一应俱全。

## 架构

请求从 PaymentGuard REST 业务服务进来，Decision 业务流程负责编排：先做数据补全（实时 SQL），再跑规则，只有灰区才发给 AI Hub Agent，然后按结果路由到结算、人工审核或欺诈告警。每一跳都是管理门户消息查看器里查得到的消息。

整个作品的核心是生产里那个 **"PaymentGuard AI Risk Agent"**：一个标准的 `Ens.BusinessOperation`，在进程内把 AI Hub Agent 跑起来。对业务流程来说，调 AI 和调其他任何操作没有区别——一样排队、可追溯、可重试；操作内部则负责运行 `%AI.Agent`、保存会话、把 token 用量带回消息流。

上图中是一次真实的灰区决策（截自演示视频）：Agent 查完实时数据，用严格 JSON 作答——action、risk_score、有据可查的 reasons，加上 token 和延迟。

## Agent 长什么样

`PaymentGuard.Agent.RiskAgent` 继承 `%AI.Agent`：

- **INSTRUCTIONS**：支付核审员人设，决策策略写得明明白白——多信号汇拢才 BLOCK，异常但说得通给 REVIEW，与既有画像一致才 APPROVE；输出必须是单个 JSON 对象：`action`、`risk_score`、`confidence`、snake_case 的 `reasons[]`，加一段人话 `summary`。
- **工具**：六个只读工具（`%AI.Tool` 方法），全是对生产自有表的实时 SQL——客户画像、近期交易、速率、设备、商户，加上语义相似检索。查哪个、查几次，Agent 自己定。
- **换模型不用改代码**：默认 DeepSeek（`.env` 里配 `AI_PROVIDER` / `AI_MODEL` / `<PROVIDER>_API_KEY`），AI Hub 支持的供应商随便换。

对 Agent 的输出，决策流程按"不可靠依赖"对待：裸 JSON、围栏 JSON、正文里夹的 JSON，三种姿势都防御性解析，按契约校验，任何一步失败就带着原因码降级人工——AI 挂了可以，但绝不静默放行，也不断人营收。

## 真实决策长什么样

一次 12 笔的演示爆发，分布相当理想：7 笔 APPROVE（规则 2、Agent 5）、4 笔 REVIEW、1 笔 BLOCK。挑两条真实运行的结果：

> **BLOCK，风险分 88**——"9 秒内连刷三笔高额电商支付，来自香港和阿联酋，设备今天才第一次出现；而 Alice Tanaka 平时是美国的小额网购，一个月也就 900 美元上下——典型的账户盗用后测卡。"
> reasons：`burst_velocity_3_txns_9s`、`geo_mismatch_hk_ae_vs_us_home`、`amount_above_baseline_710_vs_avg_monthly_900`、`brand_new_device_first_seen_today`

> **REVIEW，风险分 45**——"这位客户的历史消费都在德国，买的是 AWS、西门子这类电商服务；这笔却是新设备在土耳其一家奢侈品腕表商户刷卡。金额不大，也没有连刷……说重了不至于，直接放也不敢——转人工。"

第一条是亮点：Agent 用速率工具把同一波爆发里的三笔独立支付关联了起来，还点明了欺诈模式。每条决策记录都带 token 数、工具调用数、延迟、模型和会话 id——想复盘，`##class(%AI.Agent.Session).%OpenId(id)` 一键回放。实测每次灰区决策约 3,000 prompt + 350 completion token、2–3 秒；规则和快速路径，零成本。

## 医保理赔：同一台引擎，再战一个欺诈领域

医保理赔结算说穿了就是带行话的支付：参保人是客户，医院/机构是商户，理赔单上多出 `procedure`（术式）、`diagnosis`（诊断）和 `city`（城市）三个字段。这些字段原样跑完整条管线——规则、补全、Agent 上下文、审计——生产就这么"顺手"学会了第二个反欺诈领域。规则引擎加了两条确定性规则：同一参保人 7 天内在**另一座城市**结算同一术式，直接拦（`DUPLICATE_CROSS_CITY_CLAIM`）；机构侧复用商户黑名单（`BLACKLISTED_MERCHANT`）。Agent 的指令里写明了理赔词汇表和重复报销模式的判法，灰区理赔会被拿去和该参保人的结算历史对碰。

演示场景：参保人 `memb_001` 三天前在上海瑞金医院全额结算过一台白内障手术（12,800 元）。三笔理赔（`POST /api/claims`）、三种机制。

同一台手术改在北京报——规则毫秒级出结果，零 token：

```bash
curl -s -X POST localhost:8082/paymentguard/api/claims -H "Content-Type: application/json" \
  -d '{"member_id":"memb_001","provider":"Beijing Union Medical College Hospital","procedure":"CATARACT_SURGERY","diagnosis":"H25.9","amount":12800,"city":"Beijing","currency":"CNY"}'
```

> **BLOCK · 规则**——`DUPLICATE_CROSS_CITY_CLAIM`——"参保人 7 天内已在上海结算过术式 CATARACT_SURGERY（结算单 claimhist_memb_001_CATARACT_SURGERY_3，2026-10-25）——跨城重复报销"

还是那台手术回到上海报——同城，规则不响。灰区交给 Agent，它把已结算的手术和当天被拦的北京尝试关联了起来：

```bash
curl -s -X POST localhost:8082/paymentguard/api/claims -H "Content-Type: application/json" \
  -d '{"member_id":"memb_001","provider":"Shanghai Renji Hospital","procedure":"CATARACT_SURGERY","diagnosis":"H25.9","amount":12800,"city":"Shanghai","currency":"CNY"}'
```

> **BLOCK · AGENT（deepseek-chat）**，风险分 92，置信度 0.9——reasons `duplicate_reimbursement`、`same_procedure_multiple_cities`、`same_procedure_settled_3_days_ago`、`prior_attempt_blocked_today`、`amount_matches_duplicate_exactly`——"张伟已于 2026-10-25 在上海瑞金医院结算过 CATARACT_SURGERY（H25.9，12,800 元）；今天已有一笔同样的理赔在北京协和医院被拦，现在同一术式、同一金额又在上海出现。这是跨机构/跨城市的重复报销，应拒付并上报。"——1,985 prompt + 154 completion token，1.8 秒。

黑名单机构的理赔根本到不了大模型：`BLACKLISTED_MERCHANT`，秒拦，零 token。种子数据自带四名参保人、四家医院和血液透析/手术/影像历史；%UnitTest 套件随医保场景长到 24——理赔端点映射、跨城重复规则、机构黑名单、Agent 关联理赔流全覆盖。

## 相似交易检索：Embedded Python 玩转 IRIS 向量搜索

决策链路里最新的一感是"记忆"——*这笔支付像不像我们见过的某一笔*。两个 Embedded Python 组件负责这一感，都是 `[Language = python]` 方法、只用标准库——不装包、不调外部 API：

- **逻辑回归风险先验**——`PaymentGuard.Rules.PyModel` 离线给补全上下文打分（金额对基线、速率、设备共享、地理错配、KYC），以 `ml_model` 身份进 Agent 上下文：只作参考信号，绝不当圣旨——Python 不可用时主流程照跑。
- **向量相似交易**——`PaymentGuard.Vector.Embedder` 把交易的结构化特征（术式、诊断、机构、城市、渠道、币种、金额档）哈希成 256 维 L2 归一化向量。确定性、离线：同样的输入永远得到同一个向量，查询向量可以直接从行的特征复算，根本不用把存量向量读回来。

生产落库的每笔交易都带 `VECTOR(double, 256)` 向量列，`VECTOR_COSINE` top-K 检索喂两条路：灰区风险上下文里预计算好的 `similar_transactions` 段，加上第六个 Agent 工具 `SearchSimilarTransactions`——核审员可以在推理中途随时拉语义近邻。人类也有同款视图，`GET /api/similar?txn_id=…`：

```bash
curl -s "localhost:8082/paymentguard/api/similar?txn_id=claimhist_memb_001_CATARACT_SURGERY_3&limit=3"

{"query_txn_id":"claimhist_memb_001_CATARACT_SURGERY_3","results":[
 {"txn_id":"…北京白内障尝试…","procedure":"CATARACT_SURGERY","city":"Beijing","similarity":0.818},
 {"txn_id":"…MRI_BRAIN 理赔…","procedure":"MRI_BRAIN","city":"Shanghai","similarity":0.307}]}
```

重复报销模式直接浮出成一张相似度排行榜：异城同术式 0.82，不相关的影像检查 0.31。Agent 也会引用这份证据——一笔同城的白内障理赔（灰区，跨城规则不响）回来时，既关联上了已结算的手术，也关联上了几十秒前刚被拦的同一笔：

> **BLOCK · AGENT（deepseek-chat）**，风险分 88，置信度 0.85——reasons `duplicate_reimbursement`、`same_procedure_settled_3_days_ago`、`same_procedure_attempted_in_second_city_same_hour`、`provider_hopping_beijing_shanghai`、`identical_amount_and_diagnosis_h25_9`——"memb_001 已于 2026-10-25 在上海瑞金结算过 CATARACT_SURGERY（H25.9，12,800 元）；本请求之前 30 秒，同一笔理赔刚在北京协和医院被拦。两天内跨两城重复报销同一术式——拦截，并转核审员核查前一笔是否需要作废。"——5,353 prompt + 313 completion token，3.8 秒。

%UnitTest 套件随向量检索长到 30：嵌入确定性与单位范数、种子理赔检索、上下文注入、自排除、每笔落库交易的端到端嵌入。

## NoPWS：这个 EAP 构建里没有 Web 服务器

2026.3 AI Hub EAP 是 NoPWS 构建——52773 私有 Web 服务器整个被砍掉，容器里没有门户、没有 REST，任何 HTTP 都没有。所以 PaymentGuard 自带一套标准的 InterSystems **Web Gateway 边车**。趟出来的三个坑，记录如下：

1. **凭据要写进 CSP.ini。** 这版网关不认 `ISC_CSP_IRIS_*` 那套环境变量，`[LOCAL]` 段里得写 `Username=CSPSystem` / `Password=SYS`；EAP 构建又不再自带 CSPSystem 用户——得自己建用户、开 `%Service_WebGateway`。
2. **Apache 模块只认扩展名。** `CSPFileTypes csp cls zen cxw`——不带扩展名的 REST URL 根本到不了 IRIS。我们在栈内做重写，把这些 URL 转到 `.csp` 孪生路由（mod_rewrite + 双份 UrlMap），`POST /payments` 这样的地址才能原样工作。
3. **匿名访问要授权。** 演示环境不开鉴权，就得把 Web 应用角色授给 UnknownUser——不然每个请求都在半路以 `<PROTECT>`/403 挂掉。

仪表盘是纯静态 HTML，Apache 直接伺服（挂载的 `web/` 目录），前端轮询 API——没有构建步骤，不用 npm。

## 部署与分发

整个栈全容器化——`docker compose up -d --build` 一条命令拉起 IRIS（AI Hub EAP community 镜像）加上文说的 Web Gateway 边车。源码和一键启动：[github.com/Dylan5237/payment-guard-ai](https://github.com/Dylan5237/payment-guard-ai)。**在线演示：[43.139.159.100:8082/paymentguard](http://43.139.159.100:8082/paymentguard/)**——仪表盘、REST API（`/paymentguard/api`）和背后的生产都在线上跑，DeepSeek live 模式实时决策；管理门户 `43.139.159.100:8082/csp/sys/UtilHome.csp`（`SuperUser` / `SYS`）。

也按 IPM 包交付（模块名 `paymentguard`）：`zpm "install paymentguard"` 一装即用，类、REST 应用、仪表盘全在里面；Open Exchange 上就是 PaymentGuard AI。

没有 API key 也能完整体验：mock 模式下端到端可跑，确定性引擎用同样的 JSON 契约作答——流程、仪表盘、审计链路、整套 %UnitTest（30 个测试）全部离线可用、全绿。

## 下一步

- 再做一个争议处理 Agent，配受限的写权限工具（挂起、调单），专门消化 REVIEW 队列；
- 给 Agent 调用加 OpenTelemetry span 导出——%AI 栈本来就 OTel-ready，审计表先交了，span 随后就到；
- 拿分析师的历史处置记录做 RAG，让 Agent 越用越懂行。

---

*PaymentGuard AI，基于 InterSystems IRIS 2026.3 AI Hub 早期访问构建的开源演示。感谢 AI Hub 团队的 EAP 计划和 %AI SDK——解决了容器里缺失 Web 服务器的问题之后更看得分明：Agent 和互操作生产之间的这条边界，设计得真漂亮。*
