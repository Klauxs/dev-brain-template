# 飞书扩展（可选）

让 dev-brain 能把飞书文档、妙记抓进库，或把方案导出成飞书文档。默认不启用；不用飞书的人可以删掉整个 `extras/lark/`。

## 启用

1. 安装飞书官方 CLI `lark-cli`，按它的说明完成 user 身份认证。
2. 把 `extras/lark/lark-import.md` 移到 `_system/lark-import.md`。
3. 在 `_system/rules.md` 的目录表 `_system/` 一行末尾补上「飞书文档抓取手册（`lark-import.md`）」，并在「准则」里加一行：抓飞书文档、导出方案到飞书时按 `_system/lark-import.md` 操作。
4. `lark-import.md` 里的 `<你的飞书域名>` 不用改：抓取时按被抓文档 URL 的域名生成链接。

handoff 和 frontmatter 的 `source` 写飞书文档 URL 即可，规则里的「文档URL」包含它。
