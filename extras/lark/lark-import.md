# 飞书抓取 / 导出手册（lark-cli）

前提：本机已安装 `lark-cli` 并完成 user 身份认证（见 `extras/lark/README.md`）。任何命令的权威用法以 CLI 内嵌 skill 为准：`lark-cli skills read lark-doc`（勿凭记忆猜参数）。

## 抓飞书文档 → 库（Capture）

```bash
lark-cli docs +fetch --api-version v2 --doc "<飞书URL>" --doc-format markdown
```

- 输出为 JSON，正文在 `.data.document.content`。
- 落位：归属明确 → `projects/<id>/sources/<文档名>.md`；未消化 → `inbox/`。
- frontmatter：`source:` 填原始 URL（必填），`project:` 填归属，`kind: source-doc`；原料**不填 `status`**（它没有结论，无所谓可信度，拉下来即结束，不进入任何待处理队列）。
- 文档里嵌的电子表格/多维表格抓不到内容，保留链接即可。
- 文档引用不递归抓取，但要保留可点击入口：把 `<cite type="doc" doc-id="..." file-type="docx|wiki" title="..."></cite>` 转成 `<a href="https://<你的飞书域名>/docx|wiki/...">标题</a>（域名取被抓文档 URL 的域名）`。

## 会议纪要 / 妙记 / 其他

按需查内嵌帮助：`lark-cli minutes --help`、`lark-cli vc --help`、`lark-cli im --help`。产物同样落 `sources/`，`source:` 带原始链接。

## 导出方案到飞书（Express，偶尔用）

```bash
# 写前先读格式规范：
lark-cli skills read lark-doc references/lark-doc-md.md
lark-cli docs +create --api-version v2 --doc-format markdown --content @<相对路径.md>
```

注意：`@file` 只接受相对当前目录的路径；导出前把 vault 专用语法（wikilink、callout、base 块）转成普通 markdown。
