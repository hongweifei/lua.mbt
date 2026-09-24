# hongweifei/lua

简体中文 | [English](README.en.md)

用 MoonBit 实现的 Lua 5.4 解释器。词法分析、语法分析、单遍代码生成、寄存器式虚拟机和全部标准库都在本仓库内实现；宿主只提供语言运行时无法自己提供的东西——流、文件、时钟、环境变量、进程控制、与 `printf` 兼容的数字格式化和随机数发生器。这条边界就是 `stub.c`，它扮演的正是参考实现里 C 标准库的角色。

## 快速开始

```
moon build --target native --release
```

解释器会被构建到 `_build/native/release/build/cmd/main/main.exe`，它同时就是 `lua` 命令行界面。运行脚本、执行一段代码，或进入交互式循环：

```
moon run cmd/main -- script.lua arg1 arg2
moon run cmd/main -- -e 'print("hello")'
moon run cmd/main                     # 从 stdin 读取；终端下会显示提示符
```

跑测试：

```
moon test
```

## 示例

`examples/` 里是可运行的程序。每个示例都用 `assert` 校验自己的结果，而不是打印一份期望输出，所以**跑一遍就是测试**；它们都是普通的 Lua 5.4 代码，因此用参考版 `lua` 二进制跑也同样通过。

| 示例 | 展示了什么 |
| --- | --- |
| `examples/basics.lua` | 整数与浮点两种数字子类型、字节串、表、闭包、变长参数、尾调用、`pcall`/`xpcall` |
| `examples/coroutines.lua` | `coroutine.wrap` 生成器、在元方法中让出（yield）、`coroutine.close` 触发待处理的 `<close>` 变量 |
| `examples/metatables.lua` | 运算符重载、`__index` 表链、只读代理、to-be-closed 变量 |

```
moon run cmd/main -- examples/basics.lua
```

`examples/embed/` 是把解释器嵌进 MoonBit 程序的示例：运行 chunk、通过全局变量双向传值、调用 Lua 函数、读取失败 chunk 的错误对象。

```
moon run examples/embed
```

## 目录结构

每个含 `moon.pkg` 的目录就是一个包。模块根目录只放元数据；可执行程序在 `cmd/main`，实现分布在 `src` 下的十七个包里。

| 包 | 内容 |
| --- | --- |
| `src/host` | 宿主边界：`ffi.mbt` 里的 `extern "c"` 声明，以及实现它们的 `stub.c` |
| `src/core` | 值模型与状态：`value`、`objects`、`table`、`table_hash`、`thread`、`userdata`、`state`；数字（`number`、`number_format`）、`opcode`、`bytes`、core 直接调用的宿主服务、`names`（错误消息从运行中的代码借用的名字）以及 `binop` / `load_outcome` |
| `src/vm` | 解释器循环及其派发：`vm`、`vm_frame`、`vm_call`、`vm_instr`、`vm_index`、`vm_arith`、`vm_compare`、`vm_convert`、`vm_hook` |
| `src/compiler` | 扫描器（`token`、`lexer`、`lexer_string`）、语法分析（`ast`、`parser`、`parser_expr`、`parser_stat`）与代码生成（`funcstate`、`funcstate_regs`、`compiler_entry`、`compiler_expr`、`compiler_call`、`compiler_stat`、`compiler_scope`） |
| `src/chunk` | `string.dump`（`chunk_dump`）以及加载其产物的 `chunk_undump` |
| `src/pattern` | Lua 模式匹配，以及建立在它之上的库函数 |
| `src/load` | 把源码或二进制 chunk 变成可调用的原型：`state_load`、`base_load` |
| `src/lib/base`、`string`、`math`、`io`、`os`、`table`、`utf8`、`coroutine`、`debug` | 每个标准库一个包 |
| `src/lua` | 对外入口：`lua`、`api`、`stdlib`、`lib_package`，以及 Lua 测试套件（`*_test.mbt`） |
| `cmd/main` | 命令行界面 |
| `examples/embed` | 嵌入解释器的示例程序；与它并列的 Lua 示例是数据文件，不是包 |

依赖图无环：

```
host
 └ core ─┬─ vm
         ├─ compiler
         ├─ chunk
         ├─ pattern
         ├─ load  ← chunk, compiler, host, vm
         ├─ lib/* ← load, vm, pattern, chunk
         └─ lua   ← lib/*, load, vm, host
```

值会跨包边界传递，所以共享声明导出得很宽：类型、struct、enum、trait 与 suberror 都是 `pub(all)`；其他包依赖的 trait 实现是 `pub impl`。方法留在声明其类型的包里。少数包在 `moon.pkg` 中设了 `warnings = "-24"`，因为每个标准库入口都带 `raise LuaRaised` 以匹配内建函数的类型，无论该函数是否真的会抛。

`tests/` 放 `moon test` 会通过解释器执行的 Lua 套件，`examples/` 放上面提到的可运行程序。

## 作为库使用

```mbt check
///|
test "embedding" {
  let state = create()
  let (ok, results) = run_string(state, "return 6 * 7", "=example")
  assert_true(ok)
  assert_eq(results.length(), 1)
}
```

`create` 构造一个已打开全部标准库的状态。`run_string`、`run_bytes` 和 `run_file` 从不抛异常：它们返回 chunk 是否成功，以及结果或错误对象。更下面一层是 `try_load`（把源码或二进制 chunk 编译成可调用的值）、`pcall_here`（在保护下调用一个值）和 `disassemble`（打印代码生成器的产物）。命令行界面就是用这三个搭起来的。

`src/lua/README.mbt.md` 是这个包的文档，其中的 `mbt check` 代码块由 `moon test` 实际执行。

## 实现要点

* **数字。** 整数为 64 位并环绕；浮点是 IEEE 双精度。两种子类型在任何地方都区分对待，包括作为表键时——整数值的浮点会归一化为整数，因此 `t[1]` 与 `t[1.0]` 指向同一格。十六进制整数环绕，装不下的十进制整数变为浮点，与语言规范一致。
* **字符串。** Lua 字符串是字节序列，所以内部一律用 `Bytes` 承载，绝不经过 MoonBit 的 UTF-16 `String` 往返。长度、切片、模式匹配和比较都以字节为单位。
* **执行。** 解释器循环是迭代式的：运行中函数的全部可变状态都放在一个 frame 记录里，因此协程的挂起就是从循环返回，恢复就是重新进入循环。原生函数也是 frame，这正是 `pcall` 与 `coroutine.yield` 无论守护的调用写在 Lua 里还是宿主语言里都表现一致的原因。
* **代码生成** 是对语法树的一遍扫描，带表达式描述符和空闲寄存器窗口，沿用参考编译器的形态。比较和短路运算符编译为一个值加一条显式条件跳转；调用和 `...` 保持开放，直到消费它们的构造决定要几个结果。
* **错误** 以 MoonBit 异常传递，在解释器安装的保护锚点被捕获：一个被恢复的协程，或一个带 `pcall` 延续的 frame。因为保护放在 frame 而不是宿主栈上，从 `pcall` 里让出（yield）可以工作，嵌套协程也可以。
* **内存。** 对象由宿主运行时管理，它使用引用计数，因此循环垃圾在进程退出时被回收。`collectgarbage` 报告真实的分配数字并遵守常用选项，但它的 "collect" 无法释放环。

## 状态

`tools/run_official_tests.mbtx` 把官方 5.4.9 套件的每个文件都通过本解释器跑一遍：**30 个中 28 个通过**。未通过的两个，其失败点与本平台构建的参考实现完全相同（用同一个文件跑参考实现验证过）：

* `files` 停在 `files.lua:84`，断言的是 `io.stdin` 上的 seek。C 库允许对标准输入句柄 `fseek` 成功，而测试期望它被拒绝。
* `attrib` 停在 `attrib.lua:154`，是 `try('B', 'B.lua', true, "libs/B.lua")` 里的 `assert(ext == x)`。期望的 loader 数据写死了正斜杠，而 Windows 上 `package.config` 给出的是反斜杠，搜索器构造的每条路径都用它。

两者都是环境差异，而非两种实现之间的差异；套件为此提供了 `_port` 开关：跑不了非可移植测试的移植版会打开它，相应代码块被跳过。本 harness 故意不开，所以那些块**确实**在跑——除了上面两行之外全部通过。

套件的最后两个文件需要说明一下。`cstack` 的实质工作会真正运行（只有末尾 `if T then` 段需要参考实现的 C 测试库）并且通过。`api` 测的是 C API，用别的语言实现的解释器无法暴露：它整个主体被 `if T==nil then ... return end` 保护，所以**两种实现**都会跳过它并报告成功。把它列进 harness 是为了让文件清单完整，它不是独立证据。

套件压得最狠的几个方面，本解释器的表现：

* **真正的收集器。** `collectgarbage` 从根开始标记，处理需要可达性的规则——弱表、ephemeron、按参考实现顺序执行的 `__gc` 终结——并随程序分配自行运行。内存属于宿主运行时，靠引用计数回收，所以收集器判定的是*可达性*而不是释放什么；一个环仍然随进程结束。`collectgarbage("count")` 报告活集占用的字节（含字符串），由遍历测出。
* **可恢复的宿主调用。** 当宿主函数仍在栈上时发生的 `coroutine.yield`——在 `__pairs` 里、在 `__close` 处理器里、在元方法里——沿着错误通道出去再回来，发起该调用的指令在恢复时是*完成*而不是重跑。
* **`debug` 保真。** 行事件、层数计算、尾调用、回溯的命名与省略、`debug.getinfo` 的各字段，都与参考构建逐指令一致。
* **一个预算。** 未捕获错误带回溯报告；无休止分配的程序会被以参考实现的 "not enough memory" 拒绝，而不是把进程拖垮（见下方差异）。

## 与参考实现的差异

* **活数据超过 1 GB 的程序会被拒绝**，消息是参考实现的 "not enough memory"（`src/core/state.mbt` 的 `MEMORY_LIMIT`）。参考实现没有这个数字：它的分配器在宿主给不出更多内存时失败，在大机器上那是好几 GB 之后。这里的内存归宿主运行时所有，它无法优雅地拒绝，所以解释器保留自己的预算。它是一个常量。
* **`collectgarbage("setstepmul", m)` 会被接受并保存，但没有效果。** 它缩放一次增量步的工作量；这里的收集是原子的，没有步长可缩放，而缩放一步被*计费*的工作量会让 `step` 在"是否刚完成一轮"上与参考实现不一致（参考实现的答案来自步进前的债务，而那个债务在轮次之间是负的）。`setpause` 确实影响阈值；它和步长都被夹紧，使程序设置的极端值无法把它们绕回。
* **`collectgarbage("step")` 的返回值与 `collectgarbage("count")` 的数字是本实现自己的账。** 参考实现的 `step` 报告它所处的*相位机*是否恰好跑完一轮，那是其增量状态的副产品：在同一次运行里，空状态上 `step 0` 答 `true`，而回收过一个大堆之后答 `false`；并且在它默认的 generational 模式下，一个"反复 step 直到某轮结束"的循环可以永远转下去。这里一步是按固定量向一轮计费，所以答案稳定，`dosteps` 那种计数在任何模式下都成立；绝对次数与参考实现不同（这也是 `setstepmul` 无法被兑现的原因）。`count` 报告的是收集器测出的活集字节，而不是参考实现的分配器数字，因此把它与常量比较的程序会看到不同的数——套件只拿它与自己比较。
* **二进制 chunk 与参考实现不通用。** 头部逐字节相同——签名、版本、格式、机器字长和两个测试常量——因为那决定了 chunk 是源码还是预编译、以及损坏时如何报错。其后的原型编码是本实现自己的，所以这里写出的 chunk 不能被 `lua` 读取，反之亦然。
* **特殊浮点值的拼写** 在 `tostring` 中固定为 `nan`、`inf` 和 `-inf`，而不跟随宿主 `printf`（各 C 库拼写不同）。`string.format` 的 `%f`、`%g`、`%e`、`%a`、`%A` 原样交给宿主格式化器，所以它们长成 C 库打印的样子：参考实现的 Windows 构建会打印与本实现相同的结果（`-nan(ind)`、`0x1.0000000000000p+0`），而链接另一个 C 库的构建会打印 `nan` 和 `0x1p+0`。
* **有洞的表的长度可以是另一个边界。** 手册把 `#t` 定义为*任意*满足 `t[b] ~= nil` 且 `t[b+1] == nil` 的 `b`，本解释器给出的数永远是其中之一。参考实现选哪一个，是其数组/散列划分的副产品（它的 `rehash` 会在两部分之间搬移整数键），所以 `{1, nil, 3}` 在那边是 3、这里是 1。建立在 `#` 之上的一切都会继承这点。真正的序列——手册所定义的情形——两者一致。
* **无法取名的参数错误说 `?`**，与参考实现一致：名字来自调用点或对 `package.loaded` 的查找，绝不来自函数注册时用的名字。所以以值的形式拿到的文件方法 `pcall(f.read, f, "x")` 报 `bad argument #2 to '?' (invalid format)`。
* **版本横幅是本实现自己的。** `lua -v` 打印 `Lua 5.4  (MoonBit implementation)`，参考实现打印它的版权行。`_VERSION` 是 `"Lua 5.4"`，只有读取横幅文本的程序才会看到区别。
* **没有共享库加载器**，所以 `package.loadlib` 的行为等同于一个未启用动态加载的 Lua 构建，原生搜索器在找到文件后会报告自己没有加载器。
* **性能比参考实现慢，倍数取决于在做什么。** `tools/run_bench.mbtx` 在本机度量：两边跑同一批用例、校验和必须一致，每个用例默认重复 3 次取最快一次——同一份二进制在两次运行之间的绝对值能差到 2 倍，所以**只有比值可信**，绝对值只能给区间。比值：协程切换约 1.3x，分配密集的负载（`table-small`、`string-build`）3–6x，表与字符串操作 12–46x，算术与派发密集的循环 29–74x（`calls` 最差）。结构性原因是 `Value` 的表示——32 字节 enum、最大载荷 `LStr` 24 字节，每次槽位读写都要拷贝它并付宿主的引用计数；不是分配器，这正是分配密集的用例反而最接近的原因。纯模式搜索曾是最差的一项（每次搜索在每个位置分配一个切片再比较，`0.483s`），改用宿主 `memchr`/`memcmp` 后为 `0.004–0.007s`，与参考实现同量级（约 1.2x）。
* **环不会被释放。** 内存由宿主运行时的引用计数回收；收集器判定可达性（这正是弱表、ephemeron 和 `__gc` 需要的），但它不做清扫。因此一个环会留到进程结束。

## 测试

```
moon test
```

* `tests/language.lua`、`tests/stdlib.lua`、`tests/require_test.lua` 和 `tests/examples.lua` 是由 `src/lua/suite_test.mbt` 通过解释器执行的 Lua 程序——和嵌入者使用的方式同形（黑盒），所以失败会带着出错的 Lua 行号报出来。
* 其余测试就放在它们所钉住的代码旁边：代码生成器产出的寄存器布局（`src/compiler/codegen_wbtest.mbt`）、`printf` 各转换与数字解析（`src/core/number_wbtest.mbt`）、命令行的选项表和 `-l name=module` 拆分（`cmd/main/main_wbtest.mbt`）、被启动的脚本看到的报错形态（`src/lua/launcher_test.mbt`）、以及宿主边界（`src/host/ffi_wbtest.mbt`）。
* 官方 Lua 5.4 测试套件是一致性的裁判。它不在本仓库分发——`tools/run_official_tests.mbtx` 需要 `lua-5.4.9-tests/` 下有一份拷贝；当前数字见上面 `## 状态`。
* 性能由 `bench/` 与 `tools/run_bench.mbtx` 度量：每个用例自带断言，打印一行 `bench <名字> <秒> <校验和>`；传入第二个解释器即可得到比值，`--repeat=N` 决定每个用例重复几次（默认 3，取最快一次）。改动前后要背靠背跑、比较**比值**，不要与上一轮的旧数字比较。

```
moon run --target native tools/run_bench.mbtx /path/to/reference/lua
```

## 许可证与来源

Apache-2.0，见 `LICENSE`。`NOTICE` 载有随之而来的署名，因为这里实现的行为是 Lua 的，是在其 MIT 许可下从参考实现移植的（`NOTICE` 中的许可原文保持英文原样）。

移植是依照以下来源写成的：

* **Lua 5.4.9**（参考实现），一切可观察行为都以它为准：`lparser.c`/`lcode.c`（单遍编译器的形态与语法错误消息）、`lvm.c`/`ldo.c`（指令语义、保护调用与 yield 的排布、展开时关闭变量的顺序）、`lgc.c`（收集规则及其执行顺序）、`lauxlib.c` 与 `l*baselib.c`/`lstrlib.c`/`ltablib.c`/`lmathlib.c`/`loslib.c`/`liolib.c`/`lcorolib.c`/`ldblib.c`/`lutf8lib.c`（参数检查与消息），以及 `lua.c`/`loadlib.c`/`luaconf.h`（启动器、搜索路径与 `package`）。
* **Lua 5.4 参考手册**，用于明确语言承诺——当手册与实现不一致时，以实现为准。
* **官方测试套件**，作为裁判（见 `## 测试`）。
* **在本机用上述源码构建的 Lua 5.4.9 二进制**，用作差分对照：每一条被移植的行为，都是把同一个文件在两种实现下各跑一遍、比对整份日志得出的，而不是只读源码。
