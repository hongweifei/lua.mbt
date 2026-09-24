# hongweifei/lua — `src/lua` 包

本解释器对外的入口：命令行界面就是由它们搭起来的，嵌入者也用它们。项目的整体情况（如何构建、可运行示例、一致性状态、移植来源）见[仓库根目录的 README](../../README.md)。

## 嵌入

`create` 构造一个已打开全部标准库的状态。`run_string`、`run_bytes` 和 `run_file` 从不抛异常：它们返回 chunk 是否成功，以及结果或错误对象。

```mbt check
///|
test "embedding" {
  let state = create()
  let (ok, results) = run_string(state, "return 6 * 7", "=example")
  assert_true(ok)
  assert_eq(results.length(), 1)
}
```

值可以双向传递：`set_global` 把一个 MoonBit 值放到 chunk 能读到的地方，`global_field` 把它读回来。

```mbt check
///|
test "sharing values" {
  let state = create()
  set_global(state, "limit", value_int(3))
  let (ok, _) = run_string(state, "seen = limit * 2", "=example")
  assert_true(ok)
  match global_field(state, "seen") {
    VInt(v) => assert_eq(v, 6L)
    _ => fail("expected an integer")
  }
}
```

失败是错误*对象*，不是异常：`error_text` 按 `tostring` 的方式渲染它，`last_load_error` 保存编译失败的 chunk 的消息。

```mbt check
///|
test "reporting a failure" {
  let state = create()
  let (ok, err) = run_string(state, "error('deliberate')", "=example")
  assert_false(ok)
  assert_true(@core.text_of(error_text(state, err[0])).contains("deliberate"))
  let loaded = try_load(state, @core.bytes_of("return +"), "=example")
  assert_true(loaded is None)
}
```

更下面一层是 `try_load`（把源码或二进制 chunk 编译成可调用的值）、`pcall_value`（在保护下调用一个值）、`call_printed`（以零参数调用并把结果交给 Lua 的 `print`——交互式循环就是这么做的）和 `disassemble`（打印代码生成器的产物）。`open_libraries` 由 `create` 调用，也可以用于一个未曾打开标准库的状态。
