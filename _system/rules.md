# dev-brain 库规则

## 声明

本文件是 dev-brain 的执行细则。工作会话从 dev-brain skill（`_system/skills/dev-brain/SKILL.md`，Codex 与 Claude 共用）进入，按需读取本文件；curator 每次运行先完整读取本文件和 `_system/curator-session.md`。全局配置只保留一行指向 skill 的路由。目的：把工作产出沉淀为可检索、可溯源的原子笔记，全程不需要人工审批。

## 输入（库的既定事实，不要现场推断）

**目录含义**

| 目录 | 放什么 | 谁写 |
|---|---|---|
| `inbox/` | 未消化原料，只进不改，被消化后可删 | curator |
| `projects/<id>/` | 一事一夹。`_hub.md` 是项目主页；`sources/` 放该项目的外部原料；其余正式笔记平铺 | curator |
| `projects/<id>/tasks/` | 任务记录。一任务一夹：主记录写目标、验收、当前状态、交接和证据，过程产物放同一夹的 `artifacts/`、`logs/`、`patches/` | 执行该任务的会话；curator 只引用不改写 |
| `projects/<id>/issues/` | 问题排查工作台。一问题一夹，放现场、证据清单、假设和中间材料 | 执行排查的会话；curator 只引用不改写 |
| `projects/<id>/diagrams/` | 项目长期参考的图：answer-me-with-html 生成的单文件 HTML（源稿嵌在页面里）；旧的 archify 图连同规格保留 | 出图的会话或 curator |
| `knowledge/` | 跨项目复用的机制、概念、坑 | curator |
| `archive/` | 结束的项目整夹移入；wikilink 按名解析不断链 | curator |
| `_system/` | 本规则、curator 说明、dev-brain skill（`skills/dev-brain/`）、脚本（`bin/`）、模板（`templates/` 下的 hub、note、design、issue、task）、接入文档（`bootstrap.md`） | 用户明确要求维护规则时的会话 |
| `extras/` | 可选扩展（例如 `extras/lark/` 飞书抓取手册），默认不启用；启用方式见各自说明 | 用户明确要求维护规则时的会话 |

**frontmatter（3 个必备 + 1 个可选，不加别的字段）**

```yaml
project: <项目id 或 knowledge>
source: <文档URL 或 仓库名@commit:路径>   # 外部信息、代码结论必填
status: draft | ok | verify-needed        # 仅结论性笔记需要；原料文档和任务记录不填（见「状态」）
kind: <可选：hub/code/decision/pitfall/research/design/issue/task/source-doc/...>
```

`status` 描述的是**结论的可信度**。抓取的原料文档（`sources/`、`inbox/`）没有结论，不填 `status`，也永远不需要"处理"——它们是检索底仓，用到即可。任务记录是过程记录，同样不填 `status`；任务进度写在正文「当前状态」的 `- 状态：` 行。

**其他事实**：`[[wikilink]]` 按笔记名解析、与目录无关，因此笔记名必须全库唯一；根目录 `Dashboard.base` 和 hub 内嵌的 base 查询是 Obsidian 自动聚合视图，禁止手工维护任何笔记列表。

## 分工

每台机器只有一个整理者：curator（运行方式见 `_system/curator-session.md`）。工作会话负责产出和交接，不整理知识。

- **工作会话**（Codex 或 Claude）：开工检索；维护自己的任务记录或 issue 工作台；把产出的报告、草稿、过程材料放进任务目录，作为项目长期参考的图放 `projects/<id>/diagrams/`；把值得长期保存的东西写成 handoff 入队。不写正式笔记、hub、`sources/`、`inbox/`、`knowledge/`，不改 `status`，不做上升、提炼、合并和归档。
- **curator**：唯一写正式笔记、hub、`sources/`、`inbox/`、`knowledge/`、`archive/` 的角色；负责查重、成文、建链、状态变更、上升、提炼、合并、归档和 Git 同步。入队即被触发，另有每小时一次兜底。
- **用户要求立刻落库**：会话照常入队，再运行 `_system/bin/dev-brain-curator run`，等它结束后把结果告诉用户。会话自己仍不写正式笔记。
- **维护规则本身**：用户明确要求修改 `_system/` 下的规则、skill、模板或脚本时，当前会话直接改。
- **同一工作区的并发写**：每个写者只提交自己写的路径（`git add -- <路径>` 后 `git commit -- <路径>`），不用 `add -A`，不提交别人的改动；遇到 `index.lock` 稍等重试，不删锁。

### dev-brain handoff 模板

```markdown
dev-brain handoff
project: <项目id 或 knowledge>
kind: <source-doc/code/decision/pitfall/research/design/issue>
source: <文档URL 或 仓库@commit:路径>
keywords: <用于查重的项目名/模块名/类名/中文关键词>
summary: <1-3 句结论或需要沉淀的原料说明>
suggested_path: <可选，建议落位>
status_hint: <draft/ok/verify-needed，可选>
links_or_assets: <可选，需要保留的链接、附件、草稿；有任务记录时带上其路径>
feedback: <可选，收尾时写：用到的哪条旧知识帮上了忙（依据是什么）、哪条与现实冲突、缺了什么>
notes: <可选，边界、待确认项、不要递归抓取等>
```

内容多的（例如一次梳理要拆成好几篇笔记）：把草稿写在任务目录 `artifacts/` 里，`summary` 写要点，`links_or_assets` 指向草稿，由 curator 查重、拆分、落位。

## 任务

### 检索（接任务先做）

1. `rg -il "<关键词>" <库根> --glob '*.md'`（curator 的工作目录就是库根，写 `.` 即可），多组关键词：项目名、模块名、类名、中英文同义词。写前去重用这个文件列表即可；开工时按 dev-brain skill「开工」逐步展开（标题 → 片段 → 全文 → 链接），不要整篇读大文件。
2. 命中 → 读对应 `_hub.md` 开头（目标、最近状态）和相关笔记；`draft`、`verify-needed` 的内容当线索不当结论。
3. 无命中不硬找，继续往下做；动手前先按 dev-brain skill「动手前对齐」与用户确认思路。

### 什么值得长期保存（curator 判断）

- **值得**：稳定的事实；带理由的决定；可复用的步骤（排查流程、配置方法）；明确的失败条件（坑）；持续影响工作的用户偏好。
- **不值得**：临时进度（留在任务记录）；对已有结论的复述（只给原笔记补来源）；没有长期价值的过程细节。不追求笔记数量。

### 写入动作（curator）

| 动作 | 什么时候 | 怎么做 |
|---|---|---|
| 新建 | 库里没有同一主题，且值得保存 | 按下面「创建」写原子笔记 |
| 佐证 | 已有结论又被一次独立的真实使用验证 | 在原笔记末尾「使用记录」追加一行：日期、来源（任务记录或 commit）、结果；够条件就升 `ok`（见「状态」） |
| 补充 | 新增前提、适用范围、步骤或反例 | 在原笔记相应位置追加，不改原结论句 |
| 纠错 | 新证据与原结论矛盾 | 保留旧文，追加 `## <日期> 新证据` 小节，`status` 改 `verify-needed` |
| 跳过 | 不值得保存或纯重复 | 在运行结果里写明理由 |

同一份材料重复入队只处理一次；同一任务分几次交来的材料一起处理，不各建一篇。

### 创建（curator）

1. **写前去重**：先按上面检索。命中活跃笔记 → 改走佐证、补充或纠错；命中 `archive/` → 移回原目录复活并刷新，不重建。
2. **落位**：只对当前项目有意义 → `projects/<id>/`；跨项目复用 → `knowledge/`；还没消化的原料 → `inbox/`。新项目先按 `_system/templates/hub.md` 建 `_hub.md`（base 查询块里的项目 id 要替换）。
3. **成文**：按 `_system/templates/note.md`，结论先行（1-3 句），frontmatter 填全；「详情」按下面的 kind 写作指引组织。技术方案用 `_system/templates/design.md`。排查经验和操作步骤类笔记写明：什么情况下用、先检查什么、步骤、如何验证、何时不适用；一次偶然成功不写成通用流程。
4. **建链**：正文中引用相关笔记 `[[名字]]`，链接任务记录和图；在 hub「当前状态」追加一行，写明新建或修改了什么。

### 状态（curator 自主维护）

| status | 含义 | 读者怎么用 |
|---|---|---|
| `draft` | 写下了，但还没在真实工作中验证过；新写和导入的默认值 | 当线索 |
| `ok` | 在一次真实工作中被用到且与现实吻合，或用户确认过 | 当结论，仍以当前代码和现场为准 |
| `verify-needed` | 出现与结论矛盾的新证据，或代码变化可能使结论失效；稀有信号，Dashboard「待核实」应接近空 | 当线索，先核实 |

转换规则（不需要人确认，升错了后续使用会暴露，git 有完整轨迹）：

- **draft → ok**：有一条独立的真实使用证据——任务记录「用到的知识」或 handoff `feedback` 写明它帮上了忙、与现实吻合，并给出具体依据（测试结果、可观察行为、对照的代码版本）。只是被检索到、被模型复述、被多个会话引用，都不算。升级时在「使用记录」写明依据。
- **draft / ok → verify-needed**：新证据与结论矛盾，或 `source` 指向的代码已变化并影响结论。按「纠错」追加新证据。
- **verify-needed → ok**：新证据确认了其中一方；追加说明哪一方成立，旧文保留。

### 上升与提炼（curator 自主）

- **上升**：`projects/<A>/` 的笔记被第二个项目实际用到（第二个项目的任务记录或 handoff 把它列为帮上忙，或第二个项目的正式笔记依赖它的结论），且内容不依赖 A 项目特有的路径、配置或代码 → 移到 `knowledge/`，`project` 改为 `knowledge`，末尾追加「上升记录」：日期、原位置、涉及的两个项目。wikilink 按名解析，不用留占位。只被一个项目用到 → 不动。
- **提炼**：三篇以上笔记（至少来自两个项目）反复出现同一机制、同一类坑或同一决策模式 → 在 `knowledge/` 新建一篇综合笔记：结论先行，每条结论链接出处，写明适用条件和反例，`status: draft`，直到被真实使用验证。原笔记只追加一行「见 [[综合笔记]]」，不改原文。
- **合并**：两篇笔记明显是同一主题 → 保留较完整的一篇，把另一篇独有的内容连同出处追加进去；另一篇只留一行指向保留篇，文件名不变，旧链接不断。
- **归档**：hub 写明项目已结束 → 整夹移到 `archive/`。其他情况不归档。
- **边界**：只处理这次交来的材料及其直接相关的笔记，不重新总结全库；`decision` 只记录用户已经做出的决定，不替用户决定、不改写已定的决定；拿不准就不做，在运行结果里写明。每次上升、提炼、合并、归档都写进提交信息和对应 hub 的「当前状态」。

### 问题排查工作台（会话直接写）

1. **触发**：有明确问题现场时才开，例如失败报告、崩溃、日志窗口、回归现象、线上事故、具体测试失败；普通代码理解和稳定结论不要放这里。具体故障排查用 issue 工作台代替任务记录，不重复建两份。
2. **路径**：`projects/<id>/issues/<YYYY-MM-DD>-<短主题>/`。主记录用全库唯一文件名，例如 `2026-07-22 Curator 投递队列排查.md`；相关材料按需放同目录下的 `artifacts/`、`logs/`、`repro/`、`patches/`。
3. **模板**：主记录用 `_system/templates/issue.md`，frontmatter 写 `kind: issue`、`status: draft`。`source` 优先填触发问题的文档 URL、报告 URL 或 `仓库@commit:路径`；本地日志、截图、zip 等原始材料在正文「证据清单」用本库相对路径列出。
4. **边界**：issue 记录可以追加现场和被否决假设，但不要覆盖既有证据；不要把未经验证的阶段性判断写成 `ok` 结论；不要修改业务代码仓库文件来服务知识管理。
5. **收束**：问题定位完成后，把稳定结论写进 handoff，`links_or_assets` 带上 issue 路径，由 curator 拆成 `code`、`pitfall`、`decision`、`research` 等正式笔记；issue 保留完整过程。

### kind 写作指引（骨架同 note.md，差别在「详情」要回答的问题）

| kind | 必须回答的问题 | 写法要点 |
|---|---|---|
| `code` 代码梳理 | 这块代码在干什么（一句话）？关键路径怎么走？为什么这么设计？哪里存疑？ | 调用链、数据流、线程模型、生命周期按需写；分层或流转关系复杂时按「画图」出图并链接；`source` 必须是 `仓库@commit:路径`；类名函数名写全便于 rg 命中 |
| `decision` 决策 | 决定了什么？为什么？**否决了哪些备选、各因为什么？**影响哪些模块？ | 一屏以内；结论由人拍板，AI 只记录；否决理由是未来最值钱的部分，不许省 |
| `pitfall` 坑 | 现象是什么？根因是什么？怎么规避/修复？如何复现（可选）？ | 现象和根因分开写，不要混；关联修复 commit/PR 和相关 `[[code]]` 笔记 |
| `research` 调研 | 问题是什么？结论是什么？证据来自哪？置信度和适用边界？ | 每条结论可溯源到 `source`；查不到就写"未找到依据"，不许编 |
| `design` 技术方案 | → 用 `_system/templates/design.md`，人主导、AI 起草 | 起草前先检索库内相关 decision/pitfall/research 作素材 |
| `issue` 问题排查 | 现象是什么？证据在哪里？验证过哪些假设？当前卡点/后续是什么？ | 用 `_system/templates/issue.md`；过程和证据优先，结论保持 `draft`，收束后再链到正式笔记 |
| `task` 任务记录 | 目标和验收是什么？现在到哪一步、谁在做？依据哪个版本？证据在哪里？用到的旧知识是否成立？ | 用 `_system/templates/task.md`；过程记录不填 `status`；稳定结论走 handoff，由 curator 写成正式笔记 |

### 画图（answer-me-with-html）

架构分层、调用链、数据流、状态机、时序、多方案对比——这类结构信息优先出图，不要用长文硬扛。

1. **生成**：默认用 answer-me-with-html skill。写 Markdown 草稿（`flow`、`sequence`、`tree`、`er`、`timeline` 等组件），由它的 `am` CLI 生成单文件 HTML，不手写 HTML/SVG。渲染时用 `-o` 把输出直接指到本库，加 `--no-open`；STE 或代码警告修掉再交付。
2. **存放**：作为项目长期参考的图放 `projects/<id>/diagrams/<主题>.html`；只服务一次任务的图放任务目录 `artifacts/`。一张图一个 HTML 文件，源稿就嵌在页面里，不另存。
3. **修改**：改一个面板用 `am patch <页面> --panel <标题>`；整体重画用同一个 `-o` 路径重新渲染覆盖。不手改 HTML。
4. **引用**：笔记里链接 HTML（`[[<名字>.html]]` 或相对路径）。
5. **其他工具**：需要可交互的大型架构图、或用户点名时可以用 archify（规格放 `src/`，视觉校验截图不提交）。已有的 archify 图和 `.drawio.svg` 保留原样。

### 产物落位（文档、图、报告）

讨论、调研、梳理、学习和开发中产出的文档、图、报告——包括 answer-me-with-html、archify 等其他 skill 或工具的输出——都存进本库，不放在代码目录旁、`~/Documents/Codex/...` 之类的输出目录或临时目录。调用工具时直接把输出路径指到本库。

1. **项目长期参考的图**：按上节放 `projects/<id>/diagrams/`，配套说明由 curator 写成正式笔记并链接。
2. **其他产物**（报告、草稿、抓取的原料、实验输出）：放该任务目录的 `artifacts/`、`logs/`、`patches/`；值得长期保存的部分写进 handoff，由 curator 决定落位。
3. **提交什么**：交付物和可编辑源（HTML、JSON 规格、Markdown、补丁）入库；可再生的中间产物（视觉校验截图、构建缓存、`node_modules`）不提交，在记录里写生成命令。单个文件明显偏大时，先在回复里说明再决定是否入库。

### 收尾（每次写入后）

- **curator**：由执行器按 curator 报告的改动路径提交（前缀 `curator:`）并同步，见 `_system/curator-session.md`。
- **工作会话**：在收尾、停下等用户判断、已完成的任务又改动时提交（换机器交接或跨机领取时另外提交并 `dev-brain-curator sync`），只提交自己的任务目录、issue 目录或图目录：`git -C <库根> add -- <路径…>`，再 `git -C <库根> commit -m "<codex|claude>: <一句话>" -- <路径…>`。工作区里别人的未提交改动不混入。

### 同步（跨机 Git）

两种交接分开：本机 handoff 只把材料交给本机 curator；跨机靠 Git 交换已经提交的笔记和任务记录。handoff 队列、锁、索引、会话凭据和机器配置留在各机，不进 Git。

1. **谁同步**：只有 curator 执行器做 `pull --rebase` 和 `push`——每次运行结束时、每小时兜底时各一次。工作会话开工时只在工作区干净时 `git pull --ff-only`；要把任务交给另一台机器时运行 `_system/bin/dev-brain-curator sync`，成功后再结束。
2. **先看状态**：有进行中的 rebase 或 merge 时推迟同步。远端没有新提交时直接推送，工作区里会话未提交的文件不影响；远端有新提交、需要 rebase 时，已跟踪文件有未提交修改就推迟，并在 status 里列出这些文件。未跟踪的新文件不影响。
3. **推送**：`pull --rebase` 后 `push`；因远端有新提交被拒时重复，最多 3 次，仍失败就记录并停下。
4. **冲突**：`_hub.md` 用 Git 的 union 合并（见 `.gitattributes`），两台机器同时往「当前状态」追加不会冲突。其他文件冲突时放弃本次 rebase（`git rebase --abort`），在 `dev-brain-curator status` 里标出冲突文件，等用户或会话按「追加不覆盖」解决：两边新增的内容都保留；结论矛盾时保留双方，追加 `## <日期> 新证据` 并标 `verify-needed`。
5. **禁止**：force push；用 `reset --hard`、`checkout --`、`clean` 等丢弃任何一方的提交或修改；删除别的进程持有的 `index.lock`。

## 准则

- 只写有依据的内容：库内事实或带 `source` 的外部信息，不编造、不无源下结论。
- 绝不删除或改写既有结论段落；绝不动当前代码仓库的文件。
- 笔记名即主题名（中文可），全库唯一；一个笔记一个主题，大主题拆多篇互链。
- 结论先行，短笔记优于长文；宁可留空待补，不要注水。
- 模板里的 callout 引导块（`> [!info]` 等）保留在成文里，是人与 AI 共用的填写指引。
- 拿不准落位或该不该合并 → 按最保守方式做（放 `projects/`、不合并），并在运行结果里写明理由。
- 本规则的迭代方式：往「准则」里加行，不推翻结构。
