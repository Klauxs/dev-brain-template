---
project: 项目id
status: draft
kind: hub
---

# 项目名

> [!info] 目标
> 一两句：这个专项要达成什么、怎么算完成。

## 涉及仓库

> [!tip] 列出本项目涉及的代码仓库；代码笔记的 source 统一写 `仓库名@commit:路径`

- ...

## 当前状态 / 决策 / 阻塞

> [!note] 活记录：AI 会话后往这里追加，旧内容折叠不删

- ...

## 本项目笔记（自动聚合，勿手工维护）

```base
filters:
  and:
    - file.inFolder("projects/项目id")
    - file.ext == "md"
    - note.kind != "hub"
properties:
  file.name:
    displayName: 笔记
  note.kind:
    displayName: 类型
  note.status:
    displayName: 状态
views:
  - type: table
    name: 全部
    order:
      - file.name
      - kind
      - status
    sort:
      - property: file.name
        direction: ASC
    columnSize:
      file.name: 420
  - type: table
    name: 库内反链
    filters:
      and:
        - file.hasLink(this.file)
    order:
      - file.name
      - kind
      - status
```
