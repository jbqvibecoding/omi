# Omi Copilot：「No Chatbot + Proactive Agent」产品设计与落地路线

> 状态：设计定稿（2026-07）。目标：在 Omi macOS 桌面端之上组装一个「实时主动副驾驶」——捕获真实世界（音频对话）与数字世界（屏幕）的多模态 context，在用户需要时把最相关的答案、笔记和下一步建议主动推到面前，而不是等用户去问。
>
> 核心结论：**Omi 已具备「感官」（截屏循环、OCR 历史、实时转写、记忆体系）和「嘴巴」（悬浮 HUD、通知卡、agent 执行），本设计新增的是按场景融合音频+屏幕上下文、主动推送答案的「副驾大脑」。约 80% 依赖复用现有代码组装。**

---

## 1. 产品理念与交互模型

### 1.1 把提问成本降为零

Chatbot 范式要求用户：(a) 意识到自己需要帮助 → (b) 切换窗口 → (c) 组织语言描述上下文。在销售通话、面试、会议这类实时对话场景中，这三步根本来不及。No-chatbot 的答案：

> **上下文由系统持续采集，意图由 agent 预测，用户唯一的动作是「接受 / 忽略」。**

### 1.2 三档交互（按用户主动性递减）

| 档位 | 名称 | 触发 | 行为 |
|---|---|---|---|
| 半主动 | **Copilot Snap** | 专用全局快捷键（默认 ⌃Return，可自定义；⌥ 组合与 PTT 按住 ⌥ 冲突故不作默认） | 「就是现在，看一眼帮我」：截取关键帧 + 近 2 分钟转写 + 近期 OCR + 个人记忆，agent 预测你此刻最需要的东西并直接给出（答案/话术/解释/下一步），绝不反问 |
| 场景激活 | **Live Copilot** | 检测到会议/通话（MeetingDetector）或手动开启 | 实时笔记 + 实时建议双车道并行：话术提示、异议处理、行动项、"你答应过…"回调 |
| 全被动 | **Screen-Op Assist** | 录屏模式常驻低频后台分析 | 检测「卡住」信号（报错反复出现、同界面停留过久、文档来回切换），高置信才浮出操作建议 |

三档共享同一个上下文引擎、同一个建议门控、同一个 HUD 投递面。

### 1.3 与传统笔记/会议工具的区别

不只「记录」，而是在对话过程中直接帮你**做决定和行动**：实时答复、提示、总结、跟进执行。像一个隐形的实时副驾：后台看屏幕、听对话，在需要时把最相关的信息推到面前。

---

## 2. 场景 Profile 体系（产品核心创新）

同一引擎，不同 prompt / 触发规则 / 输出形态 / 节奏参数。Profile 是 struct 而非 enum，为将来用户自定义和第三方开放留口：

```swift
struct CopilotScenarioProfile {
    let id, displayName: String
    let systemPromptBlock: String        // 角色定义 + 什么算高价值建议
    let triggerVocabulary: [String]      // 廉价预过滤词表
    let outputStyle: OutputStyle         // talkTrack / notes / factLookup / hint
    let postSessionArtifacts: [Artifact] // followUpEmail / summary / questionsAsked
}
```

| Profile | 激活方式 | 建议类型 | 触发节奏 |
|---|---|---|---|
| 销售通话 | 手动 / 日历 / 会议检测 | 异议处理话术、竞品对比卡、报价谈判提示、**会后跟进邮件草稿** | 触发词（价格/竞品/顾虑）+ 说话人切换后 1-2s |
| 会议（默认） | 会议检测自动 | 实时笔记（LiveNotes 现成）、决议、行动项、"你被 @ 了" | 50 词阈值（沿用 LiveNotes 节奏） |
| 面试（双向） | 手动 | 候选人：答题提示、STAR 框架；面试官：追问建议、简历对照 | 问句检测后即时 |
| 客户支持 | 手动 / app 检测 | KB/记忆检索卡（RAG 现成）、标准回复草稿 | 客户消息出现在屏幕时 |
| 演示/路演 | 屏幕共享检测 | 当前 slide 相关背景数据、预判 Q&A | 页面切换时预取 |
| 软件操作 | 默认兜底 | 报错解释、操作路径、代码建议 | Snap 为主 + 卡顿检测 |

Profile 选择：`MeetingDetector.isMeetingActive` 时默认 `meeting`；HUD 上场景 chip 一键切换；Phase 3 由日历事件标题自动建议（`CalendarReaderService`）。

Profile 体系天然对应后端已有的 Apps/插件 proactive prompt 模板（`{{user_facts}}` / `{{user_context}}` 替换），未来可开放给第三方开发者做垂直场景副驾。

---

## 3. 噪音控制（第一产品风险）

主动式产品死于打扰。分层防御，全部复用已验证模式：

1. **置信度阶梯呈现**：低置信 → 悬浮条小圆点（"我有想法，点我看"）；中置信 → 滑出一行建议卡；高置信 + 时间敏感（对方刚抛出异议）→ 卡片展开 + Glow 边框脉冲。**永不弹系统通知打断。**
2. **三段式门控**：复用后端 `utils/llm/proactive_notification.py` 已验证的 evaluate → generate → validate 形态，本地压缩为两次调用；Gate 预期 80-90% 说"不"，这是成本阀和噪音阀。
3. **硬置信度下限 0.75**（同 `InsightAssistantSettings.minConfidence` 旋钮）。
4. **节奏预算**：每 90s 最多 1 条、每场上限 12 条、45s 评估冷却（后端 `MENTOR_RATE_LIMIT_SECONDS` 模式按 live 场景缩放）。
5. **去重**：会话内建议历史 + InsightAssistant 的 "previously provided, do not repeat" prompt 块。
6. **可学习抑制**：同类建议连续 dismiss → 该类别自动提高阈值（`ProactiveExtractionRecord.isDismissed` 字段已存在，作为训练信号）。
7. **单一声音原则**：Copilot 开启时，旧 InsightAssistant 通知默认关闭，避免多个助手同时说话。

---

## 4. 输出可执行性分级

不止给信息，给**可以直接用的东西**：

- **L1 提示卡**：一句话话术/事实，一键复制。
- **L2 草稿**：跟进邮件、回复文本，一键复制/插入剪贴板。
- **L3 委托执行**：转给 desktop agent 跑完整任务——复用 `ProactiveTaskExecute` + agent VM + 后端 CORE_TOOLS（~25 个工具：日历、Gmail、记忆、屏幕活动、web 检索等）。
- **会后交付包**：摘要 + 行动项 + 跟进草稿——复用后端 conversation 处理管线（`get_transcript_structure` + `extract_action_items`）。

## 5. 记忆飞轮（对 Cluely 类竞品的差异点）

副驾建议不是通用 LLM 输出，而是**带着"你上次和这个客户聊过什么、你的目标是什么、你看过什么文档"的建议**：

- 个人事实/记忆：`get_prompt_memories(uid)`（后端）+ `AIUserProfileService` 画像（本地）。
- 历史对话语义检索：Pinecone `query_vectors_by_metadata`。
- 屏幕历史：Rewind SQLite（OCR FTS5 全文索引），agent 可 `execute_sql` 查询用户看过的一切。
- 知识图谱：Neo4j `traverse_knowledge_graph_tool`。

每一场会话又产出新的 memories/action items 回流体系——用得越久，副驾越懂你。

## 6. 隐私与信任

- 复用全部现有隐私机制：app 排除列表、截图类 app 前台时暂停、视频通话降频、`ScreenRecordingPermissionPolicy`。
- **排除规则必须同样作用于 OCR 拉取**——上下文引擎绝不把被排除 app 的 OCR 行注入 prompt（不只是不截帧）。
- 副驾激活必须有明确可见状态灯（悬浮条常驻小点）。
- 屏幕共享时抑制 Glow 脉冲（复用 `ConferencingApps` 检测），避免建议内容被投到共享屏幕上。
- 建议内容本地优先（Rewind DB）；后端同步走既有 memory 同意面。
- 面试/考试场景伦理边界：产品定位"准备与复盘为主、实时为辅"，不主打实时作弊。

---

## 7. 统一架构

### 7.1 三条延迟车道

| 车道 | 通道 | 延迟 | 用途 |
|---|---|---|---|
| **Lane A** 亚秒级 | `RealtimeHubSession`（Gemini Live / OpenAI Realtime 持久 WS，`sendVideoFrame` 推屏幕帧，Rust 后端 mint 临时 token） | <1s | Phase 2 "hot mode"：双击 Snap 升级为语音互动。太贵太有状态，不做默认主动车道 |
| **Lane B** 事件驱动（主力） | 客户端直连 `GeminiClient.sendRequest(prompt:imageData:systemPrompt:responseSchema:)` | 1-5s | 三个入口全部走这条。LiveNotesMonitor 已验证此模式在录音期间可行 |
| **Lane C** 持久/后台 | Python 后端三段式 proactive 管线 + Firestore/Pinecone | 分钟级 | app 关闭时 FCM 兜底、跨设备历史；Phase 2 新增 `/v4/listen` 会话内 `ProactiveSuggestionEvent`，手机端免费获得同款副驾 |

原则：**用户正在看的东西走客户端；需要跨会话/跨设备存续的走后端。**

### 7.2 新增模块（`Desktop/Sources/Copilot/`）

```
CopilotOrchestrator.swift      # 入口路由（hotkey / meeting / screen-op）
CopilotContextEngine.swift     # 统一上下文快照组装器
CopilotScenarioProfile.swift   # 场景 Profile
CopilotSuggestionGate.swift    # 本地 gate→generate→critic + 频控 + 去重
CopilotSuggestionStore.swift   # 持久化（包装 ProactiveExtractionRecord）
CopilotPrompts.swift           # 全部 prompt 集中一处（交叉引用后端 proactive_notification.py）
LiveSuggestionsMonitor.swift   # 会议建议车道（LiveNotesMonitor 的兄弟）
```

### 7.3 关键架构决策

1. **不改 `AssistantCoordinator` 加音频通道。** 它是调好背压的屏幕帧分发机（`isAnalyzing` 集合、`distributeFrame`）。转写在**分析时刻由 `CopilotContextEngine` pull-side 拼入**（`LiveTranscriptMonitor.shared.segments` 是 `@Published`，MainActor 免费读取）。代价是转写上下文最多落后一次发布——可接受，避免破坏调好的背压机制。
2. **三入口三形态，一处汇聚**：
   - Screen-Op = 新 `ScreenOpAssistant` actor 注册进 `AssistantCoordinator`（免费获得省电捕获循环 / 视频通话 1/5 降频 / 隐私排除 / 背压）。
   - Live Copilot = Combine 订阅 `LiveTranscriptMonitor.$segments`（转写驱动，不进 coordinator）。
   - Snap = `CopilotOrchestrator` 一次性命令式调用，无需注册。
   - 三者汇聚到同一个 `CopilotSuggestionGate`（质量控制）和同一个 HUD 投递面。
3. **MVP 建议生成放客户端而非后端**：后端 mentor 管线节奏不对（≥10 段缓冲、5 分钟频控、日上限 9——为"导师时刻"调的，不适合异议处理）；投递今天只有 FCM；屏幕上下文只在客户端。后端管线保持不动，作为会话外车道。

### 7.4 上下文快照复用映射

```swift
@MainActor final class CopilotContextEngine {
    struct Snapshot {
        let activeApp: String?; let windowTitle: String?
        let keyframeJPEG: Data?          // 调用方决定是否截帧
        let transcriptWindow: String     // 近 N 秒转写
        let isMeetingActive: Bool
        let activitySummary: String      // Rewind 活动摘要
        let recentOCR: String            // 当前 app 近 5 分钟 OCR
        let userProfile: String?
        let scenario: CopilotScenarioProfile
        let recentSuggestions: [String]  // 去重上下文
    }
    func snapshot(transcriptSeconds: TimeInterval, includeKeyframe: Bool, maxOCRChars: Int) async -> Snapshot
}
```

| 字段 | 来源（现成代码） |
|---|---|
| transcriptWindow | `LiveTranscriptMonitor.shared.segments`（+ `savedSegments`） |
| keyframeJPEG | `ScreenCaptureManager.captureScreenJPEG()`（RealtimeHub 同款路径，鼠标所在显示器） |
| activitySummary | 提取 `InsightAssistant.buildActivitySummary(from:to:)` 为共享 `ActivityContextBuilder`；`compressForGemini`（1280px, q0.4）同样提升为共享工具 |
| recentOCR | 一条 SQL 查 Rewind `screenshots` 表（当前 app、近 5 分钟，**应用隐私排除**） |
| isMeetingActive | `AppState.meetingDetector`（带迟滞防抖） |
| userProfile | `AIUserProfileService.shared.getLatestProfile()` |
| recentSuggestions | `ProactiveExtractionRecord` 查询 |

---

## 8. 三个入口的实现要点

### 8.1 Copilot Snap（快捷键关键帧）

1. **快捷键注册**：`ShortcutSettings.swift` 加 `copilotShortcut`（默认 ⌃Return = keyCode 36 + control——⌥ 组合与 PTT 默认"按住 ⌥"冲突，⌥Return 仅作可选预设；模式照抄 `askOmiShortcut` 的持久化/变更通知/预设）；`GlobalShortcutManager.swift` 加 `HotKeyID.copilot = 3` + `registerCopilot()`，`handleHotKeyEvent` 派发 `CopilotOrchestrator.shared.triggerPredictiveResponse(source: .hotkey)`。
2. **即时反馈**：任何网络请求之前，悬浮条 <100ms 内弹 "Reading your screen…" 思考态（复用 `routeQuery` 的 shimmer）。感知即时性是"魔法"与"坏了"的分界线。
3. **并行组装**：`captureScreenJPEG()` 降采样至 ~100-200KB ∥ `CopilotContextEngine.snapshot(transcriptSeconds: 120, includeKeyframe: true, maxOCRChars: 4000)`。
4. **一次结构化 vision 调用**（Gemini Flash，`thinkingBudget: 0`）。预测性 prompt 核心：

   > 你是隐形副驾。用户按下了副驾键——他们**没有**输入问题。从截图、近期对话、近期活动推断他们此刻需要什么，直接回答那个需要。绝不反问。在通话中：接下来该说什么/该知道什么。在阅读：关键答案/摘要/背景。在操作软件或代码：具体的下一步或修复。确实歧义时给最可能的答案 + 一个备选，120 词以内。

   输出 schema：`{intent_guess, headline≤8词, response_markdown, confidence, suggested_actions[{label, agent_prompt}]}`。
5. **呈现**：显式意图 → 走完整 AI 响应面板（`showAIConversation` + `AIResponseView`），follow-up 输入框聚焦（打字或 PTT 均可细化）；`suggested_actions` 按钮经 `routeQuery` + `ProactiveTaskExecute.systemPromptSuffix` 语义派发给 agent。
6. **持久化**：`ProactiveExtractionRecord`（category: `copilot_snap`）+ 复用 InsightAssistant 的后端同步路径。
7. **Phase 2 双击升级**：3s 内二次按键 → 挂上 RealtimeHub warm session，`sendVideoFrame` 同一关键帧，进入语音互动（≈ PTT 的 `startRealtimeHubCapture` 去掉按住麦克风）。

### 8.2 Live Copilot（会议/通话实时副驾）

- **会话接线**：`AppState+Transcription.swift` 中 `LiveNotesMonitor.startSession` 的两处调用点旁并列加 `LiveSuggestionsMonitor.startSession(sessionId:scenario:)`。采集（mic + 系统音频混音）、转写（`/v4/listen` WS）、segments 发布全部现成——**零新增采集代码**。
- **`LiveSuggestionsMonitor`**（镜像 LiveNotesMonitor）：段末尾时间游标增量处理；触发 = ~35 新词 或 触发词/问句廉价启发式命中；45s 评估冷却；`isGenerating` 单飞行 guard。
- **两段式调用**：
  1. **Gate**（Flash-lite `sendTextRequest`，~400ms）：转写窗口 + 最近 5 条建议 → `{should_speak, reason, type: objection|question|action_item|factual_gap|next_step}`。
  2. **Generate+critic**（Flash 结构化）：90s 转写 + 会议窗口 OCR（共享屏幕/deck 上的内容）+ 用户画像 + Profile prompt + 历史建议去重 → `{headline≤8词, suggestion≤50词, talk_track?, confidence, category}`；`confidence < 0.75` 丢弃。
- **时效保护**：生成用 `withThrowingTimeout` 15s 截断；显示前比对转写游标，话题已经翻篇的建议直接丢弃（晚 5s 的异议提示仍有价值，晚 40s 的没有）。
- **会后交付**：挂 `ConversationFinalizationService`——Profile 声明的 artifacts（销售跟进邮件等）以通知形式出现，Execute 按钮经 `ProactiveTaskExecute.buildQuery` 由 agent 端到端执行（Gmail/Slack/Telegram 已打通）。

### 8.3 Screen-Op Assist（屏幕操作辅助）

- 新 `ScreenOpAssistant` actor（`Assistants/Copilot/`），结构克隆 InsightAssistant（注册、enabled 门控、pendingFrame + AsyncStream + 间隔循环、app 排除——90% 机制现成）。
- **不同的任务书**：Insight 找回顾式"有趣的洞察"；ScreenOp 回答 *"用户此刻在这个 app 里想做什么？卡住了吗？"* 两段式复用：Phase 1 文本 `execute_sql` 查**当前 app 近 10 分钟** OCR，检测卡住信号——报错文本跨截图重复、同窗口标题 >N 分钟、文档/StackOverflow 来回切换 → `request_screenshot` → Phase 2 vision → `provide_suggestion`（新增 `action_prompt` 参数供 Execute 转交 agent 修复）。
- 节奏 90-120s 默认 + 快路径：`onContextSwitch` 进入终端/IDE 且 OCR 含报错样文本时允许立即评估一次。
- 设置克隆 `InsightAssistantSettings`（间隔/置信度/排除/prompt 可编辑，复用 `PromptEditorWindow` 模式）。
- 跨助手去重：与 Insight 共享 "previously provided" prompt 块来源（tag `tips` + 新 tag `screen_op`）。

### 8.4 UI：单一表面，三档强度

全部走 FloatingControlBar HUD，不开新窗，**不用紫色**（品牌规则，用白/中性色）：

1. **建议卡**（未经请求：Live + Screen-Op）：扩展 `FloatingBarNotification` 渲染（字段已够用：title/message/assistantId/context/screenshotData），`assistantId: "copilot"` 样式——headline + 正文 + 场景 chip，置信度只在展开态显示；动作 **Dismiss / Copy / Execute / Expand**（Execute 走 `routeQuery` execute-mode，Expand 打开 AIResponseView 带上下文续问）；遵守现有 snooze 与 `pendingNotifications` 队列。
2. **完整响应面板**（Snap 触发）：AI conversation surface + `AIResponseView`，follow-up 输入即时可用。
3. **环境信号**：Glow 短脉冲提示新建议（屏幕共享时抑制）+ 会话期间悬浮条常驻 copilot 小点/pill（复用 `AgentPill` 视觉语言），带 live-notes/suggestions 切换。

每张卡的 shown/dismissed/executed/expanded 记 PostHog + `ProactiveExtractionRecord`（isRead/isDismissed 字段现成）——Phase 3 阈值自适应的训练信号。

### 8.5 后端改动（Phase 2）

- `backend/models/message_event.py` 加 `ProactiveSuggestionEvent`（`event_type: "proactive_suggestion"`，字段 suggestion/headline/category/confidence/scenario）。
- `backend/routers/transcribe.py`：会话存活时，mentor 管线输出经 `_send_message_event` 在 `/v4/listen` 上投递（FCM 之外）；为 live 会话加独立频控 key。
- 桌面 `TranscriptionService.parseBackendResponse` 加 case，喂入同一个 `CopilotSuggestionGate` 与本地建议去重。**手机端由此免费获得同款副驾**，也为无 BYOK/Gemini 的用户提供服务端兜底。
- 转写管线变更需同 PR 更新 `docs/doc/developer/backend/listen_pusher_pipeline.mdx`。

---

## 9. 分阶段路线图

### Phase 0 — Copilot Snap（~3-5 天，性价比最高）
- 新建：`Copilot/CopilotOrchestrator.swift`、`CopilotContextEngine.swift`、`CopilotPrompts.swift`。
- 修改：`ShortcutSettings.swift`（+copilotShortcut）、`GlobalShortcutManager.swift`（+HotKeyID.copilot）、`FloatingControlBarWindow.swift`（copilot 响应入口方法）、快捷键设置 UI、`InsightAssistant.swift`（提取 `buildActivitySummary`/`compressForGemini` 为共享工具）。

### Phase 1 — MVP：会议实时副驾 + 建议卡（~2-3 周）
- 新建：`LiveSuggestionsMonitor.swift`、`CopilotScenarioProfile.swift`、`CopilotSuggestionGate.swift`、`CopilotSuggestionStore.swift`、建议卡 SwiftUI 视图、copilot 设置面板。
- 修改：`AppState+Transcription.swift`（挂 session 生命周期）、`FloatingControlBarWindow/State.swift`（卡片动作）。
- 复用：LiveTranscriptMonitor、MeetingDetector、GeminiClient、NotificationService、ProactiveTaskExecute、InsightAssistant 去重/置信模式、`APIClient.createMemory` 同步。

### Phase 2 — Screen-Op + 后端车道 + hot mode（~3-4 周）
- `ScreenOpAssistant` 全套（克隆 Insight 文件组）；后端 `ProactiveSuggestionEvent` + 会话内投递；支持/KB 场景接检索工具（memories semantic_search、screen activity、files）；双击升级 RealtimeHub；会后交付物（销售跟进邮件走 execute 车道）。

### Phase 3 — 学习与打磨
- dismiss 驱动的按场景阈值自适应；日历自动选 Profile；自定义 Profile；演示背景资料模式；持续录制 UX 整合。

---

## 10. 验证方式

- **命名 bundle 端到端**：`cd desktop/macos && OMI_APP_NAME="omi-copilot-snap" ./run.sh`（auth 自动 seed）；`./scripts/omi-ctl action` 加 debug 动作触发 Snap；`agent-swift connect --bundle-id com.omi.omi-copilot-snap` + `wait text` 断言响应 headline；`screenshot` 留证据。
- **转写回放 harness**：向 `LiveTranscriptMonitor.updateSegments` 喂预制 `SpeakerSegment` 数组，断言 gate 决策/建议数/频控；场景 prompt 回归以 `InsightTestRunnerWindow` 为模板建 `CopilotTestRunnerWindow`。
- **真实会议冒烟**：命名 bundle 上开一场 Zoom 通话，验证会议检测 → 建议 → dismiss/execute 全链路。
- 触及悬浮条必跑 `./scripts/agent-logic-harness.sh`；编译检查 `xcrun swift build -c debug --package-path Desktop`；合并前 clean release build。
- Phase 2 后端改动：`backend/test.sh` + 同 PR 更新 listen/pusher 管线文档。

## 11. 风险与权衡速览

| 风险 | 缓解 |
|---|---|
| 噪音（第一产品风险） | 分层门控（gate 多数说不 + 0.75 置信下限 + 节奏预算 + 去重 + snooze）、单一声音原则、dismiss 学习抑制 |
| 成本 | Live 按转写词数驱动而非帧驱动（1 小时通话 ≈ 几十次 Flash-lite gate + 5-12 次 Flash 生成，分钱量级）；Screen-Op 继承帧节流；Snap 用户自发自限 |
| 延迟 | Snap p50 2.5s（并行组装 + thinkingBudget 0 + 即时思考态兜底感知）；live 建议 3-8s 可接受，15s 超时 + 转写游标过期丢弃 |
| 隐私 | 现有排除机制全复用，且**延伸到 OCR 拉取**；屏幕共享抑制 Glow；建议本地优先 |
| 双栈漂移 | 客户端 prompt 集中 `CopilotPrompts.swift` + 交叉引用后端 `proactive_notification.py`；Phase 2 经 `SettingsSyncManager` 同步门控阈值 |
| 并发 | coordinator 保持 screen-only，音频 pull-side 拼入（最多落后一次发布）；帧+话语对齐需求留给 Lane A |

## 12. 关键文件索引

| 文件 | 角色 |
|---|---|
| `Desktop/Sources/ProactiveAssistants/Assistants/Insight/InsightAssistant.swift` | 首要模板：两段式调查、activity summary、置信门控 |
| `Desktop/Sources/FloatingControlBar/FloatingControlBarWindow.swift` | 唯一投递面：presentNotification / routeQuery / AI surface |
| `Desktop/Sources/LiveNotes/LiveNotesMonitor.swift` | 转写驱动 monitor 模板 |
| `Desktop/Sources/FloatingControlBar/GlobalShortcutManager.swift` + `ShortcutSettings.swift` | 快捷键入口 |
| `Desktop/Sources/AppState/AppState+Transcription.swift` | 会话生命周期挂接点 |
| `Desktop/Sources/FloatingControlBar/RealtimeHubController.swift` | Lane A hot mode |
| `backend/models/message_event.py` + `backend/routers/transcribe.py` | Phase 2 会话内建议事件 |
| `backend/utils/llm/proactive_notification.py` + `utils/mentor_notifications.py` | 门控/去抖参考实现（Lane C） |
