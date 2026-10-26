# dev-brain 接入文档

这份文档用来从模板建起你自己的 dev-brain 知识库，并把它接入 Codex 和 Claude Code。工作会话（Codex 或 Claude）都从 `_system/skills/dev-brain` skill 进入；知识整理由每台机器上的 curator 完成，curator 调用 Codex CLI。

- macOS：脚本是 `_system/bin/dev-brain-handoff`、`_system/bin/dev-brain-curator`（zsh），定时靠 launchd。
- Windows：脚本是同目录的 `dev-brain-handoff.ps1`、`dev-brain-curator.ps1`（PowerShell 5.1 或 7），定时靠计划任务。

## 前置条件

| | macOS | Windows |
|---|---|---|
| Git | 自带或 `brew install git` | `winget install Git.Git` |
| ripgrep（检索用） | `brew install ripgrep` | `winget install BurntSushi.ripgrep.MSVC` |
| Codex CLI（curator 必需） | 按 Codex 官方文档安装并登录 | 同左 |
| Python 3（curator 解析结果用） | 系统自带的 `python3` 即可 | 不需要 |
| 允许运行本地脚本 | — | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| Obsidian（可选，浏览和 Dashboard） | 可选 | 可选 |

只用 Claude Code 写代码也可以，但 curator 需要 Codex CLI；没有 Codex 时 handoff 会一直留在队列里，任务记录和检索照常可用。

## 第 0 步：建你自己的仓库（每人一次）

模板只带机制，不带任何人的笔记。把它变成你自己的私有仓库：

```bash
# macOS（Windows 在 PowerShell 里命令相同，路径换成 $HOME\dev-brain）
cp -R <模板目录> ~/dev-brain          # 或从模板仓库 clone 后删掉 .git
cd ~/dev-brain
git init -b main
git add -A && git commit -m "init dev-brain from template"
# 在你自己的 Git 服务上新建一个空的私有仓库，然后：
git remote add origin <你的私有仓库地址>
git push -u origin main
```

要点：

- 仓库必须私有，里面会有工作材料。
- curator 只向当前分支的 upstream 推送，所以 `push -u` 这一步不能省。
- 别的机器直接 `git clone <你的私有仓库地址> ~/dev-brain`，然后从第 1 步开始。

## 第 1 步：让 agent 帮你接入

把下面对应平台的整段 prompt 发给这台机器上的 Codex 或 Claude Code。

### macOS

```text
请帮我在这台电脑上启用 dev-brain 知识库机制。仓库在 ~/dev-brain（如果不在，先问我路径，下面的 ~/dev-brain 都换成实际路径）。
过程中不要修改任何业务代码仓库。

1. 读取 ~/dev-brain/_system/skills/dev-brain/SKILL.md、_system/rules.md、_system/curator-session.md；确认 git -C ~/dev-brain status 正常，并且当前分支有 upstream。

2. 安装 skill（一处一份）：
   - Codex：mkdir -p ~/.agents/skills && ln -sfn ~/dev-brain/_system/skills/dev-brain ~/.agents/skills/dev-brain
     ~/.codex/skills/dev-brain 也存在时删掉它，否则 Codex 会列出两份。
   - Claude Code：skills 目录是 $CLAUDE_CONFIG_DIR/skills，未设置时为 ~/.claude/skills。执行 ln -sfn ~/dev-brain/_system/skills/dev-brain <该目录>/dev-brain
   - 不要执行 ln -sf AGENTS.md agents.md：macOS 默认文件系统不区分大小写，这一步会删掉 AGENTS.md。

3. 写本机配置：
   - 问我给这台机器起一个短名（例如 mac-studio），写入 ~/.config/dev-brain/machine。
   - 把库根绝对路径写入 ~/.config/dev-brain/vault。

4. 在 ~/.codex/AGENTS.md 和 Claude 配置目录下的 CLAUDE.md 末尾各追加下面这段（文件不存在就新建）：

   ## dev-brain

   开发、排查、调研、梳理、学习和方案讨论的开工、交接（暂停／换会话／换机器）与收尾，使用 `dev-brain` skill。这些工作产出的文档、图和报告存进 dev-brain，不放在代码目录旁或临时输出目录。

5. 安装 curator：
   - 先确认 codex 能用一个本账号支持的模型：codex exec --ignore-user-config --ephemeral --skip-git-repo-check --sandbox read-only -m <模型> "Reply with exactly: OK"
     默认模型写在 _system/bin/dev-brain-curator 里；不可用时写 ~/.config/dev-brain/curator.env：
       DEV_BRAIN_CURATOR_MODEL=<可用的模型>
       DEV_BRAIN_CURATOR_EFFORT=medium
   - ~/dev-brain/_system/bin/dev-brain-curator install
   - ~/dev-brain/_system/bin/dev-brain-curator status，确认 launchd: loaded

6. 验证：
   - bash ~/dev-brain/_system/tests/test-dev-brain-handoff.sh && bash ~/dev-brain/_system/tests/test-dev-brain-curator.sh
   - Codex：codex debug prompt-input | grep -o -- '- dev-brain: ' | wc -l 应输出 1
   - Claude：告诉我新开会话输入 /dev-brain 检查

7. 报告：库路径、本机短名、两处 skill 链接与两处路由是否就位、测试结果、dev-brain-curator status 输出。
```

### Windows

```text
请帮我在这台 Windows 电脑上启用 dev-brain 知识库机制。仓库在 $HOME\dev-brain（如果不在，先问我路径，下面的路径都换成实际路径）。
全程用 PowerShell，过程中不要修改任何业务代码仓库。

1. 读取 $HOME\dev-brain\_system\skills\dev-brain\SKILL.md（含「Windows（PowerShell）」一节）、_system\rules.md、_system\curator-session.md；确认 git -C $HOME\dev-brain status 正常，并且当前分支有 upstream。
   确认 Get-ExecutionPolicy -Scope CurrentUser 是 RemoteSigned 或更宽松；不是就问我是否执行 Set-ExecutionPolicy -Scope CurrentUser RemoteSigned。

2. 安装 skill。Windows 上创建符号链接需要管理员或开发者模式，所以用目录联接（junction）：
   - Codex：New-Item -ItemType Directory -Force $HOME\.agents\skills | Out-Null
            New-Item -ItemType Junction -Path $HOME\.agents\skills\dev-brain -Target $HOME\dev-brain\_system\skills\dev-brain
   - Claude Code：skills 目录是 $env:CLAUDE_CONFIG_DIR\skills，未设置时为 $HOME\.claude\skills，同样建 junction 指向 $HOME\dev-brain\_system\skills\dev-brain
   - 同一技能只装一处：$HOME\.codex\skills\dev-brain 也存在时删掉它。

3. 写本机配置（UTF-8，无 BOM）：
   - 问我给这台机器起一个短名（例如 win-desk），写入 $HOME\.config\dev-brain\machine。
   - 把库根绝对路径写入 $HOME\.config\dev-brain\vault（skill 在 junction 下定位不到库根时读它）。
   写法：[IO.File]::WriteAllText("$HOME\.config\dev-brain\machine", "win-desk`n", (New-Object Text.UTF8Encoding $false))

4. 在 $HOME\.codex\AGENTS.md 和 Claude 配置目录下的 CLAUDE.md 末尾各追加下面这段（文件不存在就新建，UTF-8）：

   ## dev-brain

   开发、排查、调研、梳理、学习和方案讨论的开工、交接（暂停／换会话／换机器）与收尾，使用 `dev-brain` skill。这些工作产出的文档、图和报告存进 dev-brain，不放在代码目录旁或临时输出目录。

5. 安装 curator：
   - 确认 codex 能用一个本账号支持的模型：codex exec --ignore-user-config --ephemeral --skip-git-repo-check --sandbox read-only -m <模型> "Reply with exactly: OK"
     默认模型写在 _system\bin\dev-brain-curator.ps1 里；不可用时写 $HOME\.config\dev-brain\curator.env：
       DEV_BRAIN_CURATOR_MODEL=<可用的模型>
       DEV_BRAIN_CURATOR_EFFORT=medium
     计划任务里找不到 codex 时，在同一文件加 CODEX_BIN=<(Get-Command codex -CommandType Application).Source 的输出>
   - & $HOME\dev-brain\_system\bin\dev-brain-curator.ps1 install
   - & $HOME\dev-brain\_system\bin\dev-brain-curator.ps1 status，确认 scheduled task: Ready

6. 验证：
   - & $HOME\dev-brain\_system\tests\test-dev-brain-handoff.ps1
   - & $HOME\dev-brain\_system\tests\test-dev-brain-curator.ps1
   - Codex：codex debug prompt-input | Select-String -SimpleMatch '- dev-brain: ' 应有 1 行
   - Claude：告诉我新开会话输入 /dev-brain 检查

7. 报告：库路径、本机短名、两处 junction 与两处路由是否就位、测试结果、dev-brain-curator.ps1 status 输出。
```

## 第 2 步：真实走一遍

装好 curator 后用一条测试 handoff 走完整流程，curator 应判为 `skipped`：

```bash
# macOS
~/dev-brain/_system/bin/dev-brain-handoff <<'EOF'
dev-brain handoff
project: knowledge
kind: research
source: local-test
keywords: dev-brain handoff smoke
summary: 新机器 handoff 烟测。只是测试，不需要落正式笔记。
EOF
sleep 120; ~/dev-brain/_system/bin/dev-brain-curator status
```

```powershell
# Windows（'@ 必须顶格）
@'
dev-brain handoff
project: knowledge
kind: research
source: local-test
keywords: dev-brain handoff smoke
summary: 新机器 handoff 烟测。只是测试，不需要落正式笔记。
'@ | & $HOME\dev-brain\_system\bin\dev-brain-handoff.ps1
Start-Sleep 120; & $HOME\dev-brain\_system\bin\dev-brain-curator.ps1 status
```

`last run` 里应看到 `skipped=1`。没有动静时看队列目录（默认 `~/.codex/dev-brain-curator-queue/`）下 `logs/` 里最新的 `run-*.log`；macOS 另看 `logs/launchd.log`，Windows 看「任务计划程序」里 `dev-brain-curator` 的历史。

锁残留或 `running/` 里留着任务时，下一次运行会自动恢复；也可以手动执行 `dev-brain-handoff --recover-stale --stale-minutes 0`（Windows：`dev-brain-handoff.ps1 -RecoverStale -StaleMinutes 0`）。

## 可选组件

- **画图**：skill 默认用 answer-me-with-html（Claude Code 插件）出单文件 HTML 图。没装就用 Markdown 里的 Mermaid 代码块画图，规则其余部分不变。
- **飞书**：`extras/lark/` 是用 lark-cli 把飞书文档抓进库、把方案导出到飞书的手册，启用方式见其中的 README。
- **Obsidian**：用 Obsidian 打开库根即可，`Dashboard.base` 和各 hub 的内嵌查询会自动聚合笔记。

## 同步习惯

工作会话只在开工时 `pull --ff-only`；推送由 curator 在每次运行后和每小时兜底时完成。换机器接续前运行 `dev-brain-curator sync`（Windows：`dev-brain-curator.ps1 sync`），看到 `sync: ok` 再走。冲突处理见 `_system/rules.md`「同步（跨机 Git）」。

## 定制

规则、模板和脚本都在 `_system/` 里，是你自己仓库的一部分，可以直接改；改动方式见 `rules.md` 最后的「本规则的迭代方式」。
