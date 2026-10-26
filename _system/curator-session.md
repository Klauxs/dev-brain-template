# dev-brain curator

每台机器只有一个 curator，是唯一整理知识的角色：读 handoff，查重，写正式笔记，改 hub 和状态，做上升、提炼、合并和归档，然后提交并同步。工作会话只产出和交接（见 `rules.md`「分工」）。

## 运行方式

| 项 | 说明 |
|---|---|
| 执行器 | macOS 用 `_system/bin/dev-brain-curator`（zsh），Windows 用 `_system/bin/dev-brain-curator.ps1`（PowerShell），行为一致。每次运行用 `codex exec` 新起一个会话处理一批 handoff，不续接旧会话；需要的上下文都在库和队列里 |
| 触发 | 入队即触发（macOS：launchd 监视队列的 `pending/`；Windows：`dev-brain-handoff.ps1` 入队后启动计划任务）；每小时兜底一次，没有 handoff 时只同步 Git；也可手动 `dev-brain-curator run` |
| 互斥 | 队列目录的 `.worker.lock`。同一台机器同时只有一个运行，后来的触发等锁，拿到后接着处理剩下的 |
| 模型 | 默认 `gpt-6.1-sol`，推理强度 `medium`；账号不支持时换成可用的模型。在 `~/.config/dev-brain/curator.env` 里用 `DEV_BRAIN_CURATOR_MODEL`、`DEV_BRAIN_CURATOR_EFFORT` 覆盖 |
| 权限 | codex 在 `workspace-write` 沙箱里，只能改库里的文件；`.git` 只读，不联网。执行器负责队列流转、按 codex 报告的路径提交（前缀 `curator:`）和同步 |
| 安装 | macOS：`dev-brain-curator install` 写入并加载 `~/Library/LaunchAgents/dev.brain.curator.plist`。Windows：`dev-brain-curator.ps1 install` 注册计划任务 `dev-brain-curator`（每小时一次，入队时按需启动）。`uninstall` 卸载；`status` 看队列、锁、最近一次运行和同步结果 |
| 队列 | `~/.codex/dev-brain-curator-queue/`：`pending/` → `running/` → `done/`（附结果）或 `failed/`。同一内容重复入队按哈希识别，只处理一次；一批失败就退回 `pending/`，同一条连续失败 3 次进 `failed/` |
| 日志 | 队列目录的 `logs/`：`runs.log` 每次运行一行；`run-<时间>.jsonl` 是 codex 事件流，`run-<时间>.result.json` 是结构化结果 |

工作会话用 `_system/bin/dev-brain-handoff`（Windows：`dev-brain-handoff.ps1`）入队；`dev-brain-handoff --status` 看队列，`--recover-stale` 把中断遗留的 `running/` 放回 `pending/`。

## 每次运行的处理流程

curator 会话按这个顺序处理这一批里的每条 handoff：

1. **读材料**：handoff 本身，以及它链接的任务记录、issue 工作台、草稿和图。
2. **判断价值**：按 `rules.md`「什么值得长期保存」。不值得 → `skipped`，写明理由。
3. **查重**：用 keywords、summary 和关键名词检索标题、正文和 hub；同一结论已存在 → 佐证或补充，不新建。
4. **写入**：按 `rules.md`「写入动作」选新建、佐证、补充或纠错；成文按「创建」和 kind 写作指引。
5. **状态**：按 handoff `feedback` 和任务记录「用到的知识」，依 `rules.md`「状态」调整被用到的笔记。
6. **上升与提炼**：依 `rules.md`「上升与提炼」判断，满足条件就做，不需要人确认。
7. **hub**：在对应 hub 的「当前状态」最上面追加一行（日期、做了什么、链接）。
8. **报告**：在最终结构化回复里写明每条 handoff 的结果、动作和理由，列出所有改动路径。

边界：

- 只处理这一批 handoff 和与之直接相关的笔记，不重新总结全库，不改写用户已定的决定。
- 不改任务目录（`projects/*/tasks/`）和 issue 工作台里的文件，只引用。
- 不运行会修改 `.git` 的命令（`git add`、`commit`、`mv`、`rm`、`checkout`、`stash` 等）；移动文件用 `mv`，并在改动路径里同时列出旧路径和新路径。
- 不联网，不碰业务仓库（可以只读查看 `source` 指向的代码）。
- 拿不准的选最保守的做法（放 `projects/`、不合并、保持 `draft`），在理由里写清楚。

## 结构化回复

最终回复必须符合 `_system/curator-output.schema.json`：

- `jobs`：每条 handoff 一项，`id` 原样照抄；`result` 取 `done`（已处理）、`skipped`（不值得保存或纯重复）、`deferred`（缺材料，下次再试）、`failed`（材料有问题，处理不了）；`actions` 列出动作和对应文件；`reason` 一两句。
- `changed_paths`：新建、修改、删除、移动过的全部文件，路径相对库根。
- `commit_message`：一句中文摘要，不带前缀。
- `summary`：给用户看的一两句话。
