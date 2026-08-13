# 三端串联 v8 实施记录：群发任务导出 + 内容模板变量 + 多设备队列调度（2026-08-13）

> 对应设计：`docs/design/2026-08-13-wda-farm-three-end-architecture.md`（v6）
> 承接 v7（`2026-08-13-wda-farm-three-end-v7-masssend-joint-debug.md`）：本轮补齐需求 v3
> 2.12「任务历史与明细：逐条结果可查、可导出」、第二步「编辑发送内容（支持模板变量）」
> 与第三步「平台将手机号按设备分配（每台设备一个队列，串行执行）」。

## 结论

- **任务导出**：任务列表/明细弹窗可一键下载 CSV（任务概览 + 逐条明细），UTF-8 BOM 保证
  Excel 直接打开中文不乱码，`=`/`@` 开头单元格加 `'` 前缀防公式注入。
- **内容模板**：租户级模板库（增删改查 + 渲染预览），变量语法 `{{phone}}`/`{{date}}`/
  `{{time}}`/`{{device}}`；创建任务可选模板，内容含变量时**逐条渲染落明细**，
  网关按明细内容逐条发送（不再全任务同文案），任务快照模板 ID/名称便于审计。
- **多设备队列调度**：一次选择多台设备创建「群发组」，手机号按轮转分配到各设备
  （各设备队列长度差 ≤ 1），每台设备一个子任务串行执行；组进度/状态由子任务聚合派生；
  组级取消一键停止全部设备。

## 各端改动

### 云平台 `whatsapp_ai`（feat/broadcast-template-export，已部署 HK 测试服务器）

- 模型/渲染（`internal/model/broadcast_template.go`）：`{{var}}` 提取与渲染纯函数；
  内置变量 phone/date/time/device，未知占位符原样保留。
- 迁移（`internal/store/pg.go` + `docs/database/2026-08-13-broadcast-template-export.sql`）：
  - 新表 `mobile_broadcast_templates`（租户级模板库）；
  - `mobile_broadcast_tasks` 加 `template_id`/`template_name`（模板快照）；
  - `mobile_broadcast_items` 加 `content`（逐条渲染内容，空=沿用任务级内容）。
- store（`mobile_broadcast.go` / `mobile_broadcast_templates.go`）：
  - 模板 CRUD；`CreateMobileBroadcastTask` 支持模板快照 + 逐条渲染（无变量内容不落明细
    content，网关自动回退任务级内容，兼容旧任务/旧网关）。
- handler/路由：
  - `GET /api/ios-devices/:id/broadcast-tasks/:taskId/export`：CSV 下载；
  - `/api/broadcast-templates`（GET/POST/PATCH/DELETE）+ `/render`（渲染预览），
    权限沿用 `ios_devices`；创建任务请求新增可选 `templateId`（快照模板名）。
  - `task:dispatch` 明细载荷携带逐条 `content`（`GatewayTaskDispatchItem.Content`）。
- 前端（`IOSDevicesView.vue` + `templateVars.js` + api `saveBlob`）：
  - 群发弹窗：模板下拉选择/保存为模板/删除模板 + 变量识别与示例渲染预览；
  - 任务列表：新增「模板」列与「导出」按钮；明细弹窗：新增「发送内容」列与「导出明细 CSV」。
- 测试：model 渲染单测、store 模板/渲染集成测试（真实 PG）、handler 路由与 CSV 净化单测、
  前端 templateVars/导出/保存模板单测；存量 Go/前端测试全部通过。
- **多设备队列调度**（同一 feat 分支，提交 f852372）：
  - 模型：`AllocatePhonesRoundRobin` 轮转分配纯函数；`MobileBroadcastGroup`
    （status/total/sent/failed/finishedAt 由子任务聚合派生，不落冗余计数）。
  - 迁移：`mobile_broadcast_groups` 表 + `mobile_broadcast_tasks.group_id`（+组索引）。
  - store：`CreateMobileBroadcastGroup` 单事务建组 + 子任务 + 明细（复用逐条模板渲染）；
    组列表/详情聚合查询；`CancelMobileBroadcastGroup` 级联取消未结束子任务。
  - API：`/api/broadcast-groups`——POST 创建（校验设备归属，逐设备经网关 task:dispatch
    下发、离线保持 pending 补推）/ GET 列表 / GET :id 详情（含子任务）/ POST :id/cancel
    （逐设备推送 task:cancel）；权限沿用 ios_devices。
  - 前端：工具栏「多设备群发」（设备多选 + 轮转提示 + 模板/变量/节奏参数）与「群发组」
    （聚合进度列表 + 组明细逐设备 明细/导出/取消）；WSS broadcast_progress 同步刷新组视图。
  - 测试：轮转分配单测、组生命周期（轮转 3/2 分配 → 部分完成 running → 全终态 done）/
    组取消/多设备无号码拒绝集成测试、路由单测、前端组创建单测。

### 本地网关 `whatsapp_ai_gateway`（main-test，已提交 ad41de5 / 7fc9c5a，本机已重启加载）

- `internal/gateway/executor.go`：
  - `TaskItem` 增加 `Content`；发送时优先用明细内容，空则沿用任务级内容
    （兼容旧平台任务与 v7 已落库任务）。
  - **metrics 落盘聚合**（P1 剩余项）：`metrics.json` 持久化（tmp+rename 原子写），
    跨天把当日分设备计数折入 history 按天归档并重置当日计数；启动加载历史
    （损坏文件仅告警不阻塞）；`MetricsSummary()` 提供网关级聚合视图。
- `internal/gateway/web.go`：新增 `GET /api/metrics`（今日汇总 + 分设备 + 历史按天倒序）。
- `static/index.html`：设备总览新增「今日发送成功/失败」卡片，随 5s 刷新更新。
- 测试：落盘重启不丢、跨天归档、跨天+重启、损坏文件忽略四组单测通过。

### 手机 WDA `WhatsAppDeviceAgent`

- 无代码改动（发送内容由网关透传 WDA，变量渲染全部在平台侧完成）。

## 部署

- 平台：`./deploy-test.sh` 部署 HK 测试服务器（`https://hk.hsddns.com`），
  备份 `/var/backups/whatsapp_ai/20260813T132552Z`，服务 active、`/health/ready` ok。
- 迁移核验（HK psql）：`mobile_broadcast_templates` 表存在（7 列），
  `mobile_broadcast_items.content`、`mobile_broadcast_tasks.template_id/template_name` 均已建。
- 网关：本机 tmux session `gateway` 重启（`:8300`），21:30:45 重连云通道成功，
  收到租户身份（测试租客），executor 空闲；`/api/metrics` 返回聚合视图。

## 验证

- Go：`go test ./...`（含 TEST_DATABASE_URL 集成测试）通过；`go build ./...` 通过。
- 前端：`pnpm test` 190 用例通过；`pnpm build` 成功。
- 集成测试（真实 PG）覆盖：模板 CRUD → 含变量任务创建 → 明细逐条渲染
  （`8613800000001 您好…`）→ 删除模板后任务快照不受影响；无号码明细 `{{phone}}` 置空；
  无变量内容明细 content 保持空（走网关回退）。
- HK 路由冒烟：`/api/broadcast-templates`、`/api/broadcast-templates/render`、
  `…/broadcast-tasks/:taskId/export` 均返回 401（鉴权正常挂载，非 404）。
- 端到端真机发送：本轮为后台运营能力（导出/模板），不新增发送路径；发送链路沿用
  v7 已验证路径（平台 → 网关 → WDA），改动点（逐条 content）仅在任务带模板变量时生效，
  建议下次真机联调时用含 `{{phone}}` 的商品类文案复核一次。

## 已知限制 / 后续

- 变量集合当前为 phone/date/time/device；「客户称呼」类变量需先有号码→姓名映射
  （手机联系人/会话备注），后续扩展 `RenderBroadcastTemplate` 的值表即可。
- 渲染发生在任务创建时刻（date/time 为创建时快照）；跨天任务各条日期相同，属预期。
- 导出为单任务 CSV；跨任务/按时段的运营报表（需求 1.18/5.6 类）不在本轮范围。
- 组分配为静态轮转（创建时确定），不感知设备实时负载；多设备并发任务各自排队、
  网关按 UDID 串行执行，天然隔离。按设备余量动态分配留待后续。
- 多设备群发要求指定手机号（「发送当前/最近会话」仅单设备语义）。
- 网关 metrics 为网关本地按天聚合；「今日」为网关本地时区日期，与平台时区一致（同机）。
- 网关未推送 GitHub（历史 29+2 个提交同样仅本地），如需远程备份可 `git push origin main-test`。
- P1 剩余：**普通 WhatsApp 真机校准**（Business 已校准，普通版选择器待真机复核）。
