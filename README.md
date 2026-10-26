# dev-brain — 个人开发知识库

一个 vault 管所有「做的事」与「沉淀的知识」。AI（Codex 或 Claude Code）在工作中检索、记录任务和交接，把值得长期保存的结论作为 handoff 交给本机 curator；curator 统一写正式笔记、提交和同步。结构约束替代人工审批，git 历史即审计轨迹。

**第一次使用：读 `_system/bootstrap.md`**，从这份模板建你自己的私有仓库，并接入 macOS 或 Windows 上的 Codex / Claude Code。

## 结构

- `inbox/` — 未消化原料
- `projects/<id>/` — 一事一夹；`_hub.md` 为项目主页，`tasks/` 放任务记录，`issues/` 放问题排查工作台，`diagrams/` 放图
- `knowledge/` — 跨项目复用知识
- `archive/` — 归档
- `_system/` — dev-brain skill、规则细则、模板、handoff 与 curator 脚本（macOS zsh 版、Windows PowerShell 版）、接入文档
- `extras/` — 可选扩展（飞书抓取手册等），默认不启用

## 约定

- frontmatter 三字段：`project` / `source` / `status`（+ 可选 `kind`）——每个字段都对应一个真实查询，不加别的。
- `[[wikilink]]` 按名解析；`Dashboard.base` 与 hub 内嵌查询（Obsidian）自动聚合，不手工维护列表。
- 规则：全局配置一行路由 → `_system/skills/dev-brain/SKILL.md`（Codex 与 Claude 共用的 skill 入口）→ `_system/rules.md`（细则）。
- 分工：工作会话只写任务记录和产物、把结论作为 handoff 入队；每台机器一个 curator（入队即触发、每小时兜底）统一写正式笔记、提交和同步，见 `_system/curator-session.md`。

## 生命周期

inbox →（被用到时消化进）projects →（被第 2 个项目引用时上升到）knowledge →（项目结束）archive。
