# 项目 Agents.md 指南

这是一个 [MoonBit](https://docs.moonbitlang.com) 项目。

额外技能可以在这里浏览与安装：
<https://github.com/moonbitlang/skills>

## 项目结构

- MoonBit 的包按目录组织，每个目录含一个 `moon.pkg` 文件，列出它的依赖。每个包有自己的源码文件、黑盒测试文件（以 `_test.mbt` 结尾）和白盒测试文件（以 `_wbtest.mbt` 结尾）。

- 顶层目录下有 `moon.mod` 文件，列出模块元数据。

- `tests/` 放 `moon test` 会通过解释器执行的 Lua 套件，`examples/` 放可运行的程序。示例用 `assert` 校验自己的结果而不是打印期望输出，所以跑一遍就是测试：`tests/examples.lua` 会运行每一个示例，并且它们都是普通的 Lua 5.4 代码，用参考版 `lua` 二进制跑也同样通过。

## 文档

- `README.md` 是对外发布的项目文档（中文为入口，英文在 `README.en.md`）：快速开始、示例、一致性状态与移植来源。`NOTICE` 载有本移植所遵循的 Lua 行为的署名。行为变化时两者都要同步更新；`README.md` 里一句已不成立的话就是缺陷。

- `src/lua/README.mbt.md` 是那个包的文档，其中的 `mbt check` 代码块由 `moon test` 执行。

## 编码约定

- MoonBit 代码按块组织，每块之间用 `///|` 分隔，各块的顺序无关紧要。某些重构可以逐块独立处理。

- 尽量把废弃的块集中放在每个目录下的 `deprecated.mbt` 文件中。

## 工具链

- `moon fmt` 用于格式化代码。

- `moon ide` 提供项目导航辅助，例如 `peek-def`、`outline` 和 `find-references`。详见 $moonbit-agent-guide。

- `moon info` 用于更新包的生成接口；每个包都有生成的接口文件 `.mbti`，它是该包对外接口的简要形式化描述。如果 `.mbti` 没有任何变化，说明你的改动不会给外部使用者带来可见变化，通常就是一次安全的重构。

- 最后一步运行 `moon info && moon fmt` 更新接口并格式化代码。检查 `.mbti` 文件的差异，确认变化符合预期。

- 运行 `moon test` 确认测试通过。MoonBit 支持快照测试；当改动影响输出时，运行 `moon test --update` 刷新快照。

- 对于稳定或极不可能变化的结果，优先用 `assert_eq` 或 `assert_true(pattern is Pattern(...))`。记录结构化调试输出的快照测试，应派生 `Debug` 并使用 `debug_inspect`，而不是为了调试去派生 `Show`。对于明确、定义良好的结果（例如科学计算），优先用断言测试。可以用 `moon coverage analyze > uncovered.log` 查看哪些代码没有被测试覆盖。
