# Symphony Fork 功能合并 Todolist

> 状态:待办清单 v1.0(2026-11-26)。范围:**kingzeus/symphony fork 侧**的改进,逐项从上游 fork 网络吸收。
> 与 [Linear兼容tracker需求与技术框架.md](Linear兼容tracker需求与技术框架.md) 是两条线:后者约束「symphony 零改、只切 endpoint」,指 tracker 替换本身;本清单是本仓库(kingzeus/symphony)自身的演进。

## 1. 背景与约束

- 上游 `openai/symphony`(28k stars / 2905 forks)自 2026-09-15 起停止推送,活跃演进全在 fork 侧。已调研 17 个代表性 fork 的 README、commit 流与相对上游差异。
- **合并约束**:不偏离上游形状。排除语言重写(fifony/TS、cc-symphony/Rust)、架构重构(sympp、VikingMew/Phoenix+Postgres)、多 tracker 适配(crescendo/signapse/sapsaldog 的 Jira/Asana/GitLab 面)、Plane 切换(Carpe-Diem)。本项目只用 Linear 兼容后端 + 已有 Claude Code 后端。
- 本地 fork 现状:AgentServer 共享合同 + ClaudeCodeBackend(`--resume` 续会话、进程树清理、密钥剥离、类型化错误、受限 Linear MCP)已领先对比过的 fork;Codex.AppServer 实现同一合同,orchestrator 生命周期所有权未变。

## 2. Todolist(按优先级)

| # | 事项 | 来源 | 形状 | 工作量 |
|---|------|------|------|--------|
| P0-1 | Linear 反 introspection skill 模式 | odysseus0 `6d423256` | 纯 markdown | 小 |
| P0-2 | WORKFLOW.md sandbox 默认值对照检查 | odysseus0 `d90560a3` | 配置级 | 小 |
| P1-1 | Claude result 事件提取 rate_limits | philipdaquin `2d8ae5f9` | 补已有字段 | 小 |
| P1-2 | workpad 文件式同步移植到受限 Linear MCP | odysseus0 `e812909d` | 思路移植 | 中 |
| P2-1 | label 路由 effort/后端 | OpenSymphony | 只摘 label 路由片 | 中 |
| P3-1 | tracker 错误分类合同对齐 dash 后端 | crescendo | 后端验收清单 | 中 |

### P0-1 Linear 反 introspection skill 模式

> 已完成:`57fa5ad`(skill 重写)+ `0174094`(workpad 中文标记兼容),2026-11-26。

- **来源**:odysseus0/symphony `6d423256`(linear SKILL.md 重写,+179/-388,零核心代码)。
- **问题**:agent 每次 GraphQL 调用前烧 token 做 schema introspection。对自建后端,省的是 Claude 侧 token 与调用次数,两边都受益。
- **做什么**:把反 introspection 模式(预置 schema 形状、禁探查)套用到本 fork 的 linear skill / agent 提示结构。
- **验收**:skill 文本不再引导内省;agent 会话中无 introspection 查询。

### P0-2 sandbox 默认值对照检查

> 已完成:`7e048cc`(2026-11-26)。与参考偏差:参考切 `dangerFullAccess` 全放开;
> 本 fork 默认本地 worker,改为保沙箱——`workspaceWrite` 策略注入 `<workspace>/.git`
> 到 writableRoots(codex 0.172.0 实证 commit/push 全通、沙箱边界保留)。Claude 侧
> `permission_mode: auto`(分类器审查,依赖模型/代理支持)。

- **来源**:odysseus0/symphony `d90560a3`(+16/-11,只动 WORKFLOW.md)。
- **问题**:上游默认 sandbox 挡 `.git/` 写入,git+PR 流程静默断裂。
- **做什么**:对照本 fork WORKFLOW.md 与 Claude 后端的实际权限配置,确认 `.git/` 可写;有挡则修。
- **验收**:git+PR 全流程(commit/push/PR)在默认配置下可走通。

### P1-1 Claude result 事件提取 rate_limits

> 已完成:`c127c37`(2026-11-26)。与参考偏差:参考假设 `requests_limit/tokens_limit` 形状,
> 实测 Claude CLI 2.1.325 真实形状是百分比窗口 `five_hour/seven_day/spend_limit`
> (`used_percentage`/`resets_at`)。适配层规范化为本 fork 看板桶形状
> (`limit_id`+`primary/secondary/credits`),payload 原样无损。

- **来源**:philipdaquin/symphony-claude `2d8ae5f9` 中的 `extract_rate_limits`。
- **问题**:本 fork `AgentServer.Event` 已有 `rate_limits` 字段,但 ClaudeCodeBackend 未从 result 事件填充。
- **做什么**:解析 Claude result payload 的 `rate_limits`(requests/tokens 的 limit/remaining),填入既有事件字段。
- **验收**:事件流与看板可见 rate_limits;限流预警有数据源。

### P1-2 workpad 文件式同步移植

> 已完成:`943af48`(2026-11-26)。不照搬参考(Codex 动态工具层 raw GraphQL+显式 ID);
> 给受限 MCP 既有单一 `tracker_workpad_upsert` 加 `file_path` 模式(与 body 互斥),
> workspace 穿过 capability 链路,读盘限定 issue workspace(越界/symlink fail-closed)。

- **来源**:odysseus0/symphony `e812909d` + `04902e34`(sync_workpad 动态工具,+87/-26)。
- **问题**:workpad 同步靠手写 Linear mutation,调用碎、易错。
- **做什么**:原实现在 Codex 动态工具层,不能直接 cherry-pick;把「文件式 workpad 同步」思路移植到受限 Linear Tracker MCP(Claude 路径),收敛为单一工具。
- **验收**:workpad 同步走单一工具;Linear 写调用次数下降。

### P2-1 label 路由 effort/后端

- **来源**:Swiftyos/OpenSymphony(`thinking/high` 等 label 切 effort,`codex`/`claude` 切后端)。
- **做什么**:只摘 label 路由一片。label 在自建后端是一等公民,加起来便宜;不碰其多后端架构(205 commits 领先,绑多后端)。
- **验收**:issue label 可覆盖 effort/后端选择;无 label 时走配置默认。

### P3-1 tracker 错误分类合同

- **来源**:ahammer/crescendo 的可移植错误分类:`tracker_config / tracker_auth / tracker_transport / tracker_response / tracker_rate_limited / tracker_payload / tracker_pagination`。
- **做什么**:这是给 dash 后端的合同参考,非 symphony 代码。落到 [Linear兼容tracker需求与技术框架.md](Linear兼容tracker需求与技术框架.md) 的深化稿,作为兼容后端错误 responses 的验收清单。
- **验收**:后端错误分类与七类对齐;symphony 侧零改动可消费。

## 3. 已评估、不合并

| Fork / 方向 | 不合并原因 |
|---|---|
| philipdaquin/symphony-claude 整体 | 平行 Behaviour 架构包在上游 Codex 路径外,与本地 AgentServer 合同竞争;无 `--resume`、无进程树清理、全量 env 传子进程、stderr 混流。仅摘 P1-1。 |
| rondo 进程监督 | 本地已覆盖且更强(活动重置 deadline、pgrep/ps 双 fallback 进程树清理)。 |
| VikingMew「先落库再写 tracker」 | 本地 `b9b4ca3` 已实现同语义。 |
| crescendo / signapse / sapsaldog 多 tracker 面 | 本项目不需要 GitHub/Jira/Asana/GitLab。 |
| Carpe-Diem Plane 切换 | 走 Linear 兼容路线,不换 provider。能力合同思路留作后端设计参考。 |
| fifony(TS)/ cc-symphony(Rust)/ sympp | 语言重写或彻底重构,偏离上游。 |
| odysseus0 setup skill / steipete CLI help | 价值低,顺手可摘不单独排期。 |

## 4. 执行备注

- 落点:本仓库,遵循 `elixir/agents.md` 约定(`make all` 门禁、`@spec` 要求、SPEC 同步)。
- 每项独立提交,可单独回退;P0 两项先行,不动核心代码。