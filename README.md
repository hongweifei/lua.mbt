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

这个移植还支持用中文（以及任何 UTF-8）命名变量、函数和字段：

```
$ moon run cmd/main -- -e 'local 名字 = "世界"; print("你好，" .. 名字)'
你好，世界
```

细节与限制见下面[与参考实现的差异](#与参考实现的差异)里的标识符那一条。

## 预编译好的 chunk

`cmd/luac` 是本项目的 `luac`：把一个或几个 Lua 文件编译成一个预编译 chunk 写到文件里。选项表、默认的 `luac.out`、`-o -` 表示标准输出、`--` 与 `-`、以及每一句报错的话术都照参考实现的 `luac.c`；几个输入会被放进同一个外壳里，按给出的顺序依次运行。

```
moon run cmd/luac -- -o script.luac script.lua   # 编译
moon run cmd/luac -- -l -l script.lua           # 列出原型；两个 -l 再附上常量/局部/上值表
moon run cmd/luac -- -s -p a.lua b.lua          # 去掉调试信息；只解析、不写出
moon run cmd/main -- script.luac                # 运行它
```

写出的 chunk 有整整 31 字节的头部与参考实现逐字节相同（签名、版本、格式、字长和那两个测试常量），**其后是本实现自己的原型编码**，所以两边互不通用——这是实测的：我们写的被参考实现拒为 `bad binary format (integer overflow)`，参考实现写的被我们拒为 `bad binary format (truncated chunk)`，两边的退出码都是 1。`-l` 的排版照 `luac.c`，但指令是本实现的 47 个、操作数是具名的 `a`/`b`/`c`，所以列出的名字与数字是这里的；参考实现用 `%p` 打印每个原型的地址，而这里没有地址可打印，于是 `CLOSURE` 直接点名它构造的那个函数，全列示的三张表也在自己的标题里说明是谁的。

`-o -`（写到标准输出）在 Windows 上拿不到完整的字节：宿主把标准输出当文本流，chunk 里的 `0x0A` 出去时成了 `0D 0A`（实测 222 字节的 chunk 到达时 225 字节，再读就是 `bad binary format (corrupted chunk)`）。参考实现也只用 `"wb"` 打开**文件**，所以这是同一条坑，不是本实现独有的；要正确的字节，就写到文件。

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

每个含 `moon.pkg` 的目录就是一个包。模块根目录既是元数据，也是**面向 MoonBit 嵌入者的公开包**（`hongweifei/lua`）；可执行程序有两个，`cmd/main`（`lua` 命令行界面）与 `cmd/luac`（`luac`），实现分布在 `src` 下的十七个包里。

| 包 | 内容 |
| --- | --- |
| `hongweifei/lua`（根包） | 嵌入用的公开接口：`Lua` 句柄、`Value`/`Table` 别名、`ToLua`、`host_function`、`LuaError`（`embed.mbt`、`values.mbt`、`host_functions.mbt`、`errors.mbt`） |
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
| `cmd/luac` | 把源文件编译成预编译 chunk 的 `luac` |
| `examples/embed` | 嵌入解释器的示例程序；与它并列的 Lua 示例是数据文件，不是包 |

依赖图无环：

```
host
 └ core ─┬─ vm
         ├─ compiler
         ├─ chunk
         ├─ pattern
         ├─ load  ← chunk, compiler, vm
         ├─ lib/* ← load, vm, pattern, chunk
         └─ lua   ← lib/*, load, vm
            └ (根包) ← core, lua
```

宿主边界只有 `host` 一个包，直接依赖它的只有五处：`core`（解释器自己要用到的宿主服务，其余包经它的包装使用）、`src/lua`（启动器与 `package` 的搜索路径）、以及三个本身就是宿主服务包装的标准库——`lib/io`、`lib/os`，和 `lib/math` 的随机数（参考实现里 `liolib.c`/`loslib.c`/`lmathlib.c` 同样是直接调 C 库的薄包装）。

值会跨包边界传递，所以共享声明导出得很宽：类型、struct、enum、trait 与 suberror 都是 `pub(all)`；其他包依赖的 trait 实现是 `pub impl`。方法留在声明其类型的包里。少数包在 `moon.pkg` 中设了 `warnings = "-24"`，因为每个标准库入口都带 `raise LuaRaised` 以匹配内建函数的类型，无论该函数是否真的会抛。

`tests/` 放 `moon test` 会通过解释器执行的 Lua 套件，`examples/` 放上面提到的可运行程序。

## 作为库使用

从 MoonBit 程序里嵌入它只需要 `import { "hongweifei/lua" }`：不必 import 解释器的内部包，也不必碰 `Bytes` 或 C 风格的签名。

```moonbit
let lua = Lua::new()
lua.set("上限", 100)                          // MoonBit 的值直接写进 globals
lua.set_function("平方", fn(args) {           // MoonBit 闭包就是 Lua 函数
  match args[0].as_integer() {
    Some(x) => Ok([Value::VInt(x * x)])
    None => Err(Value::text("integer expected"))
  }
})
let total = lua.eval_int("return 平方(3) + 上限")   // Ok(109)
```

`Lua::new` 打开全部标准库。`run`、`run_file`、`call` 都返回 `Result[Array[Value], LuaError]`：脚本失败不会抛 MoonBit 异常，`LuaError` 同时带着**错误对象本身**（`error({code=42})` 里那个表可以逐字段读）和按语言规则渲染出的文本。`Value` 是解释器自己的值的别名，所以它的读法与语言用的是同一套规则——`as_integer` 就是 `math.tointeger`，`raw_equal` 就是 `==`，`as_bytes` 给的是字符串的原始字节。

数据两个方向都成对：`ToLua` 把 MoonBit 数据搬进 Lua（标量、`Array`（1 起的序列）、`Map`、`Option`（`None` 就是 `nil`）），`FromLua` 搬回来——表可以整个读成 `Map[String, T]` 或 `Array[T]`（序列读到第一个空位为止）。**读取时类型写在注解上**，因为这门语言没有「在调用处写出类型参数」的语法；下面这几个 `eval_*` 的近路不必写，它们就是常用类型的 `FromLua`：

```moonbit
let size : Map[String, Int]? = read_lua(lua.get("配置"))     // 表 → Map
let items : Array[Int64]? = read_lua(lua.get("清单"))        // 表 → 序列
let limit : Result[Int64, LuaError] = lua.get_as("上限")     // Err 里是语言那种话
let vs = lua.run("return '一', '二'").unwrap()
let words : Result[Array[String], LuaError] = lua.values_as(vs)
```

读法的失败说得和库函数一样具体，而且指向真正出错的那个值：把 `{7, 'x'}` 读成 `Array[Int64]` 会说 `number expected, got string`（说的是那一项，不是那个表）。反过来一个 MoonBit 模块可以直接交给脚本：`lua.preload("设置", fn(_) { ... })` 之后脚本里的 `require("设置")` 就能拿到它，宿主这边 `lua.require("设置")` 也拿得到同一个值（`package.loaded` 的缓存照常生效）。不想让脚本看见或改掉的模块交给 `lua.register_module("名字", fn(_) { ... })`：它走参考实现留给原生库的那个搜索器（装载器拿到的第二个参数是 `":native:"`，返回值照常进 `package.loaded`），但它不在任何 Lua 可见的表里，脚本既列不出也清不掉。表的自身字段与序列也可以不经过转换直接取：`table_entries` / `table_sequence`。

再下面一层（`src/lua` 与 `src/core`）也直接可用：命令行界面就是用它们搭起来的。

可运行的完整版本是 `examples/embed/main.mbt`（`moon run examples/embed`，它自己用 `assert` 校验结果）；上面那段代码也在根包的 `embed_test.mbt` 里跑着，那个文件只用公开接口——这正是它要验证的事。

## 实现要点

* **数字。** 整数为 64 位并环绕；浮点是 IEEE 双精度。两种子类型在任何地方都区分对待，包括作为表键时——整数值的浮点会归一化为整数，因此 `t[1]` 与 `t[1.0]` 指向同一格。十六进制整数环绕，装不下的十进制整数变为浮点，与语言规范一致。
* **字符串。** Lua 字符串是字节序列，所以内部一律用 `Bytes` 承载，绝不经过 MoonBit 的 UTF-16 `String` 往返。长度、切片、模式匹配和比较都以字节为单位。
* **UTF-8 无处不在，标识符也可以是中文。** 字符串按字节处理，所以源码里的中文注释、中文字符串字面量和 `utf8` 库都按 Lua 的语义工作；在此之上本实现还允许**标识符**写成 UTF-8：ASCII 之外的一个合法码点就是一个名字字符，于是 `local 中 = 1`、`function 打招呼(谁)`、`表.键`、`对象:加一()`、`::再来::` 都能用，混写（`字母A`、`café`）也可以。这是相对参考实现的**扩展**（它的字符表只覆盖 ASCII，见下方差异），不是移植行为。从**文件**读入的 chunk 还允许带 UTF-8 BOM 和以 `#` 开头的首行（可执行的 `#!` 脚本），两者都会被丢掉，而那一行用一个换行代替——行号因此不动，这正是 `luaL_loadfilex` 的 `skipBOM`/`skipcomment`；作为字符串交给 `load` 的 chunk 不做这件事（那里的 `#` 是长度运算符）。`os.date` 也按参考实现那样**逐个转换说明符**交给宿主 `strftime`、其余字节原样穿过，所以 `os.date("%Y年")` 得到 `1970年`——整串交给 `strftime` 会把多字节字符旁边那段文字吞掉。文件名同样是字节：能按 UTF-8 读的名字就按 UTF-8 交给宿主，因此中文文件名在 Windows 上可用（见下方差异）；不是 UTF-8 的名字原样传递，宿主自己的单字节编码照旧。
* **执行。** 解释器循环是迭代式的：运行中函数的全部可变状态都放在一个 frame 记录里，因此协程的挂起就是从循环返回，恢复就是重新进入循环。原生函数也是 frame，这正是 `pcall` 与 `coroutine.yield` 无论守护的调用写在 Lua 里还是宿主语言里都表现一致的原因。
* **代码生成** 是对语法树的一遍扫描，带表达式描述符和空闲寄存器窗口，沿用参考编译器的形态。比较和短路运算符编译为一个值加一条显式条件跳转；调用和 `...` 保持开放，直到消费它们的构造决定要几个结果。
* **错误** 以 MoonBit 异常传递，在解释器安装的保护锚点被捕获：一个被恢复的协程，或一个带 `pcall` 延续的 frame。因为保护放在 frame 而不是宿主栈上，从 `pcall` 里让出（yield）可以工作，嵌套协程也可以。
* **内存。** 对象由宿主运行时管理，它使用引用计数，因此循环垃圾在进程退出时被回收。`collectgarbage` 报告真实的分配数字并遵守常用选项，但它的 "collect" 无法释放环。`step` 的答复也按参考实现的规则给：那个答复读的是「收集器停在暂停状态」，所以只有增量模式会说「一轮结束了」，默认的分代模式一律说没有（实测两边在 模式 × 运行/停止 四格上逐一相同）。

## 状态

`tools/run_official_tests.mbtx` 把官方 5.4.9 套件的每个文件都通过本解释器跑一遍：**31 个中 29 个通过**。未通过的两个，其失败点与本平台构建的参考实现完全相同（用同一个文件跑参考实现验证过）：

* `files` 停在 `files.lua:84`，断言的是 `io.stdin` 上的 seek。C 库允许对标准输入句柄 `fseek` 成功，而测试期望它被拒绝。
* `attrib` 停在 `attrib.lua:154`，是 `try('B', 'B.lua', true, "libs/B.lua")` 里的 `assert(ext == x)`。期望的 loader 数据写死了正斜杠，而 Windows 上 `package.config` 给出的是反斜杠，搜索器构造的每条路径都用它。

两者都是环境差异，而非两种实现之间的差异；套件为此提供了 `_port` 开关：跑不了非可移植测试的移植版会打开它，相应代码块被跳过。本 harness 故意不开，所以那些块**确实**在跑——除了上面两行之外全部通过。

第 31 个文件是 `big.lua`：它的主体在顶层让出协程（`big.lua:56`），所以不能直接调用——`all.lua:177` 也正是用 `coroutine.wrap` 驱动它、再恢复一次的，本 harness 照做（直接 `lua big.lua` 在两种实现里都报错，那不是缺陷）。

每个文件还跑三种形状，因为参考实现自己的驱动就是这么跑的：`all.lua:139-143` 把 `dofile` 重定义成「`loadfile` → `string.dump` → 再 `load` → 运行」，也就是说官方套件的主路径其实是**预编译的 chunk**，而 `all.lua:172` 还要求 `code.lua` 用 strip 过的 dump。`src` 是 `lua file.lua` 那种源码形状（就是上面那 31 项），`dump` 与 `strip` 各再加 31 项，一共 93 格。同一张表也用 `--exe=` 喂给参考实现，两边对照：

* 本实现 **79/93**，参考实现 **77/93**，而本实现红的那 14 格**全部**也是参考实现红的（`literals[dump]`、`literals[strip]`、`calls[strip]`、`constructs[strip]`、`coroutine[strip]`、`errors[strip]`、`locals[strip]`、`db[strip]` 加 `attrib`/`files` 的三种形状）——新增的两个形状没有带来任何「只有我们红」的格子。
* strip 那一批红是必然的：strip 掉了行号与名字，而这些文件断言的正是带位置的报错（`assert(...)` 在 strip 的 chunk 里报出的就是没有前缀的一句，参考实现也一样），这正是 `all.lua` 自己只用 strip 跑 `code.lua`、而把 `strings.lua` 与 `literals.lua` 交回原始 `dofile` 的原因。
* 参考实现另外红两格：`heavy` 与 `heavy[dump]`。`heavy.lua` 的最后一段一直分配到店拒绝为止，用的时间就是这台机器允许一个进程用多少，本机参考实现六分钟还没跑完（超时），本实现在自己的内存预算处几秒内就报 "not enough memory" 并结束。这是环境，不是实现差异。

`files` 停在第 84 行，它后面的内容（含 `files.lua:537`–`550` 那组 BOM 与 `#` 首行的用例）在这条路径上跑不到。第 84 行要求「对 stdin 做一次越界 seek 必须失败」，而 stdin 是不是那样一个句柄由宿主给的东西决定，两种实现在这里都得停。把那一段单独拿出来、两种实现各跑一遍，两边都通过；`tests/language.lua` 里也钉了同样四组用例。同一份 `files.lua` 把 stdin 关掉再跑（`exec 0<&-`），本实现现在能一路跑到 `files.lua:228`：中间 `:192`–`:205` 那组「从 `dofile` 里面让出协程」的用例两边都通过（这正是本轮改掉的缺口，见「可恢复的宿主调用」）；同一条件下参考实现跑到 `:760` 才停。停下来的两处都不是让出：`:228` 要 `f:read("n")` 读出一个十六进制浮点数 `0x1.13Ap+3e`，本实现的词法与 `tonumber` 都认这个写法，只有 `read("n")` 这条数字扫描的路不认（实测返回 `nil` 且不消耗输入，于是后面那句 `read(1)` 读到的是换行）；`:760` 在 `if not _port` 的 POSIX 外壳测试段里（`kill -s HUP $$` 一类的命令与退出码），Windows 上没有那些命令，是环境差异。

套件的最后两个文件需要说明一下。`cstack` 的实质工作会真正运行（只有末尾 `if T then` 段需要参考实现的 C 测试库）并且通过。`api` 测的是 C API，用别的语言实现的解释器无法暴露：它整个主体被 `if T==nil then ... return end` 保护，所以**两种实现**都会跳过它并报告成功。把它列进 harness 是为了让文件清单完整，它不是独立证据。

套件压得最狠的几个方面，本解释器的表现：

* **真正的收集器。** `collectgarbage` 从根开始标记，处理需要可达性的规则——弱表、ephemeron、按参考实现顺序执行的 `__gc` 终结——并随程序分配自行运行。内存属于宿主运行时，靠引用计数回收，所以收集器判定的是*可达性*而不是释放什么；一个环仍然随进程结束。`collectgarbage("count")` 报告活集占用的字节（含字符串），由遍历测出。
* **可恢复的宿主调用。** 协程能穿出哪些宿主调用，按参考实现的规则来。5.4.9 里带**延续**的只有三个：`pcall`/`xpcall`（`finishpcall`）、`pairs`（`pairscont`）、`dofile`（`dofilecont`），只有这三个允许被让出穿过；其余从宿主发起的调用——`table.sort` 的比较器、`string.gsub` 的替换函数与替换表、`tostring` 走的 `__tostring`、`os.time` 读的 `__index`、`require` 的装载器、`load` 的读取函数、`debug` 钩子——都在 `luaD_callnoyield` 覆盖的区间里，下面任何一处让出都会被拒，`coroutine.isyieldable()` 在里面也如实回答 `false`。拒绝的报错不带位置前缀，因为参考实现是从 `coroutine.yield` 自己的帧里报的，那里没有 Lua 行可指。解释器自己发起的调用不是边界（`isLuacode`）：元方法、泛型 `for` 的迭代器、`<close>` 处理器照常能让出。能穿过的让出沿错误通道出去再回来，发起该调用的指令在恢复时是*完成*而不是重跑；带延续的那三个帧在恢复时以内层调用留下的值收尾，`dofile` 要的是 `LUA_MULTRET`，留了几个就取几个。这份标记不越过协程边界：宿主调用里另起的协程可以自己让出——参考实现恢复一个线程时只带走对方的 C 调用*深度*，非让出区间数从 0 开始。
* **`debug` 保真。** 行事件、层数计算、尾调用、回溯的命名与省略、`debug.getinfo` 的各字段，都与参考构建逐指令一致。
* **两个预算。** 未捕获错误带回溯报告；无休止分配的程序会被以参考实现的 "not enough memory" 拒绝，而不是把进程拖垮；经宿主回调的递归在宿主栈快用完时被以 "C stack overflow" 拒绝，而不是把真实栈耗尽（两者都见下方差异）。

## 与参考实现的差异

* **活数据超过 1 GB 的程序会被拒绝**，消息是参考实现的 "not enough memory"（`src/core/state.mbt` 的 `MEMORY_LIMIT`）。参考实现没有这个数字：它的分配器在宿主给不出更多内存时失败，在大机器上那是好几 GB 之后。这里的内存归宿主运行时所有，它无法优雅地拒绝，所以解释器保留自己的预算。它是一个常量。
* **`collectgarbage("setstepmul", m)` 存得像参考实现，方向也像，效果的量级不像。** 参考实现把 gc 参数按 4 的倍数存（`GCPARAM_ADJ`），所以 `setstepmul(50)` 下次回报 48——这里一样；参考实现存它的槽是一个字节，极大的值会回绕，这里保持原值并夹紧。方向也一样：乘数越大，一轮需要的调用越少。量级不同，实测同一个形状（增量模式、收集器开着、造 20000 个嵌套表，然后每步 2 KB 直到它报出「一轮结束」）：参考实现 5000/100/50 → **1385/1403/1452**（相差约 5%），本实现 → **1/11/21**（相差二十倍）。原因是这里一步支付的工作量按乘数缩放，而一轮结束留下的信用不按它缩放。另外，`stepmul` 是 `incstep` 的参数，所以在默认的**分代**模式下它根本不会被问到。

* **`collectgarbage("step")` 的答复照参考实现的规则给。** 参考实现答的不是"一轮结束了"，而是"债务付清了，**并且**收集器正停在暂停态"。这句话有两个后果，都实测过：其一，有尺寸的一步只经由 `luaC_checkGC` 进入收集器，而它只看债务是否为正，所以上一轮留下的信用没还清之前一步**什么都不做**；其二，**分代模式下答复一律是 `false`**，因为分代的一轮不停在暂停态——而分代就是默认模式。"模式 × 收集器开/关"四格与参考实现逐一相同（修好之前，分代那两格我们答 `true`）。账本本身仍是本实现自己的：上面那个形状里 2 KB 一步这里要 11 次、参考实现要 1403 次，因为"一轮值多少工作"是估的（对象数 + 字节/16），不是参考实现那种逐对象计的代价。`count` 报告收集器测出的活集字节，并计入**自上一轮以来库函数创建的对象**，因此随分配上升、随回收下降；绝对数字不同，因为参考的数字是它分配器自己的账。

* **二进制 chunk 与参考实现不通用。** 头部逐字节相同——整整 31 字节：签名、版本、格式、机器字长和两个测试常量——因为那决定了 chunk 是源码还是预编译、以及损坏时如何报错。其后的原型编码是本实现自己的，所以这里写出的 chunk 不能被 `lua` 读取，反之亦然；两边现在都是实测的：同一个程序，本实现写出 222 字节、参考实现写出 113 字节，把任一边交给另一边都报 `bad binary format (...)` 并以退出码 1 结束（我们写的被判为 `integer overflow`，参考写的被判为 `truncated chunk`；两个程序上都量过，相同的部分正好是那 31 字节的头部，第 32 字节起就各读各自的）。
* **特殊浮点值的拼写** 在 `tostring` 中固定为 `nan`、`inf` 和 `-inf`，而不跟随宿主 `printf`（各 C 库拼写不同）。`string.format` 的 `%f`、`%g`、`%e`、`%a`、`%A` 原样交给宿主格式化器，所以它们长成 C 库打印的样子：参考实现的 Windows 构建会打印与本实现相同的结果（`-nan(ind)`、`0x1.0000000000000p+0`），而链接另一个 C 库的构建会打印 `nan` 和 `0x1p+0`。
* **有洞的表的长度可以是另一个边界。** 手册把 `#t` 定义为*任意*满足 `t[b] ~= nil` 且 `t[b+1] == nil` 的 `b`，本解释器给出的数永远是其中之一。参考实现选哪一个，是其数组/散列划分的副产品（它的 `rehash` 会在两部分之间搬移整数键），所以 `{1, nil, 3}` 在那边是 3、这里是 1。建立在 `#` 之上的一切都会继承这点。真正的序列——手册所定义的情形——两者一致。
* **无法取名的参数错误说 `?`**，与参考实现一致：名字来自调用点或对 `package.loaded` 的查找，绝不来自函数注册时用的名字。所以以值的形式拿到的文件方法 `pcall(f.read, f, "x")` 报 `bad argument #2 to '?' (invalid format)`。
* **版本横幅是本实现自己的。** `lua -v` 打印 `Lua 5.4  (MoonBit implementation)`，参考实现打印它的版权行。`_VERSION` 是 `"Lua 5.4"`，只有读取横幅文本的程序才会看到区别。
* **`package.loadlib` 找不到、也调不起 `lua_CFunction`。** 宿主加载器是真的在问（POSIX 的 `dlopen`/`dlsym`，Windows 的 `LoadLibraryExA`/`GetProcAddress`），所以文件打不开答 `"open"`、打开了却没有那个入口答 `"init"`，两边都带加载器自己的原因。唯独**把函数调用起来**做不到：参考实现把一个 `lua_CFunction` 压成值、再由解释器带着自己的 `lua_State` 去调它，而这里既没有在 C 那侧的 `lua_State`（那等于把解释器用 C 再写一遍），也没有让库回调 MoonBit 的办法——原生后端的运行时不导出「调用一个运行时取到的函数指针」这种入口。于是连文件与入口都找到时答案是 `nil, "dynamic libraries cannot be entered by this build", "absent"`。能调的是**普通的 C 函数**，见下一条。要给脚本一个写在 Lua 之下的模块，用宿主侧的 `Lua::register_module`（见「作为库使用」）。
* **`package.loadc` 是本实现独有的扩展**，它按声明的签名调用一个现成的 C 函数：

  ```lua
  local pow = assert(package.loadc("libm.so.6", "double pow(double, double)"))
  print(pow(2, 10))                                    -- 1024.0
  local strcmp = assert(package.loadc("libc.so.6", "int strcmp(string, string)"))
  print(strcmp("abc", "abc"))                          -- 0
  local find = assert(package.loadc("libc.so.6", "string strchr(string, int)"))
  print(find("abcdef", string.byte("c")), find("abcdef", 0))  -- cdef  nil
  ```

  第二个参数不是符号名而是**一整条 C 声明**：里面的名字就是去库里找的入口，类型决定参数与返回值怎么摆。可写的类型是 `int`（C `int`，32 位）、`int64`（C `int64_t`/`long long`/`size_t`／指针的宽度）、`double`、`string`；`string` 作参数是把 Lua 字符串的字节**借给这次调用**（库要留下它就得自己拷，且中间有 NUL 就会被当成结尾），作返回值是拷到 NUL 为止——超过 4096 字节会报错而不是截断，返回 NULL 就是 `nil`。返回值可以是 `void`，那答零个值。**参数最多两个**：每一个能调的形状都得在 C 里编出来（这正是后端不给「按指针调用」的能力的代价），返回类型 × 参数类型的组合已经是 105 个形状，再加一个参数就要 500 个，所以到此为止。`bool`、`float`、结构体、更多参数都不在里面，签名解析会说出是哪一项不行。失败仍是软的，形状与 `loadlib` 一致：`nil, 原因`，或者 `nil, 原因, "open" | "init"`。参考实现没有这个函数，所以 `tests/native_libs.lua` 与 UTF-8 那一套并列为**非可移植套件**。
* **标识符接受非 ASCII 码点，这是本实现独有的扩展。** 参考实现的 `lislalpha` 只认 ASCII（`luai_ctype_` 表覆盖 0x00–0x7F），源码里任何 ≥0x80 的字节都进不了标识符，报 `<name> expected near '<\228>'`（`utf8` 库、字符串、注释与 `os.setlocale` 都改不了这一点：它不用 C 库的 `isalpha`）。这里一个**合法且可见**的 UTF-8 码点就算一个名字字符，所以 `local 中 = 1`、`function 打招呼(谁) end`、`表.键`、`对象:加一()`、`::再来::` 都能写，名字可以是二字节（`café`）、三字节（汉字）、四字节（emoji）。约束有四条：只认 **UTF-8**（GBK 的 `你` 是 `C4 E3`，两个前导字节，仍然报 `<name> expected`）；码点必须**合法**（截断序列、overlong、代理区、超过 U+10FFFF 都不算，退回 ASCII 读法）；**不可见的码点不算**——BOM（U+FEFF）、零宽连接符与零宽空格、双向控制符、行分隔符、C1 控制符、U+_FFFE/U+_FFFF 这类非字符都不进名字，所以作为字符串交给 `load` 的 chunk 里那个 BOM 仍旧按参考实现报 `unexpected symbol near '<\239>'`（只有从**文件**读入的 chunk 才由 `luaL_loadfile*` 剥掉它）；数字后面紧跟的非 ASCII 字符也**会被数字吸收**，报参考实现那种 `malformed number near '100万'`，而不是把 `100` 和一个游离的名字拼在一起（ASCII 字母的旧行为逐字节不变）。**合法程序的含义不受影响**：真 Lua 里 ASCII 之外的字节出现在字符串/注释之外本来就是语法错误，因此这只把「原来报错的输入」变得可用（而且不会把原来报错的 BOM 悄悄变成合法标识符），`load`/`require`/文件名的行为不变。要参考实现那种严格性（比如做移植性检查），跑参考实现自己的 `lua` 即可——本实现没有关掉它的开关。词法热路径上 ASCII 名字只多一次比较，进程内 A/B（同一进程内用无名字的对照用例除以自身漂移）测得比值 0.431 → 0.429，在噪声之内。
* **文件名按 UTF-8 交给宿主，因此能打开参考实现打不开的名字。** Windows 的文件名是 UTF-16，而 Lua 字符串是字节。这里在文件名是合法 UTF-8 时把它转成宽字符再调 `_wfopen`/`_wremove`/`_wrename`，于是源码里写 `io.open("中文.txt")`、`dofile("脚本.lua")`、`require("模块")` 都能打开真正的中文文件名；参考实现的 Windows 构建用窄字符 API，同样的代码会报 "No such file or directory"。不是合法 UTF-8 的名字**原样**交给窄字符 API（宿主自己的编码照旧可用——用 `io.open` 建出来的名字，`loadfile` 能用同一个名字找到它），所以这只会让原先打不开的名字能打开，不会让原先能打开的失效。名字一律以**字节**在内部传递、不再经过 MoonBit 的 String，因此不会被有损解码换成另一个名字。非 Windows 平台没有这层转换（那里的文件名本来就是字节）。
* **性能比参考实现慢，倍数取决于在做什么。** `tools/run_bench.mbtx` 在本机度量：两边跑同一批用例、校验和必须一致，`--repeat=N` 决定每个用例重复几次（默认 3）并取最快一次——同一份二进制在两次运行之间的绝对值能差到 2 倍，所以**只有比值可信**，绝对值只能给区间。下面这组数字取 `--repeat=5`。现在的比值：协程 0.8–1.0x（本实现更快）、纯模式搜索 0.7–1.5x、分配密集的 `table-small` 2.7x 与 `string-build` 5.3x、表操作 6.7–8.4x、字符串 11–15x、算术与位运算 9–23x（`calls` 16x 仍是最差的一项）；小数值一侧（参考实现常在 2–4 ms）的比值摆动较大，所以上面给的是区间。最近这一轮把解释器循环里**由指令操作数定界的栈访问改成不查边界**（`base + inst.a/b/c` 这些索引由原型的 `maxstack` 保证在帧窗口内，`push_frame` 已经为整个原型预留了空间；凡是值可能回调进 Lua、因而可能让栈重新分配的地方，都是先算出值再写回，写法上不留求值顺序的疑问）。同一会话交错 A/B 测得：MOVE **14.3 → 12.1 ns**（−15%）、整数加法 **24.4 → 19.7**（−19%）、整数键取表 **28.7 → 25.3**（−12%）；字符串键取表只降 3%（它的钱在哈希探测上）、`call0` 只降 3%（调用路径不吃栈访问）。整机安静时的端到端：`calls` 0.058→**0.048 s**、`arith-int` 0.094→**0.084**、`arith-float` 0.029→**0.026**、`table-hash` 0.062→**0.059**、`string-rep` 0.051→**0.045**、`coroutine-switch` 0.087→**0.078**，多数用例 −8…−19%。这一轮把 `+`/`-`/`*` 的整数与浮点情形**内联进了派发循环**，其余情况（字符串操作数要强制转换、元方法、报错）仍交给 `arith`，语义只有一处定义：`arith-int` 背靠背 **−12%…−15%**、`arith-float` −6%…−9%，`arith-bits` 不动（位运算没内联，正好是对照组），其余用例在 ±9% 内来回，属于代码布局噪声。每指令的固定开销仍是瓶颈（实测：MOVE 约 10–17 ns、整数加法 25 ns、整数键读表 27–31 ns），字符串键查表那一块已经动过一刀：一次全局名读取原来要 180–215 ns，而整数键读取只要 27–31 ns；成分探针拆开看，其中约 55 ns 像是每次查找新建 `Key` 箱子、约 20 ns 是算 hash。**当时试的路是把 `Key` 变成 `#valtype`，那条路不通**——`Key` 的载荷里有 `Value`，装不进 `#valtype`，于是只是把一种箱子换成另一种，还多了一层分支（不造 Key 的收益要等后来换一个形状才拿到，见后）；真正可省的是 `Hasher`：它是带 `mut` 字段的堆对象，**每算一次 key 的 hash 就分配一次**。所以最后的改法是让 `key_hash` 对字符串直接用 `LStr` 已经算好并缓存的 `hash` 字段（所有表都走这一个函数，槽位因此仍然一致）。进程内 A/B/A 交错计时（同一会话、各跑 3 次、取最小）：`get_lstr` **105–113 → 67–90 ns**、`set_lstr` **115 → 72–78 ns**，而整数键的对照纹丝不动（100–110 ns 两臂相同）。端到端 bench 这一轮没给出可用的数——跑的时候整机繁忙，连参考实现一侧都慢了 30–50%，那种绝对值不能引用。与上一版**背靠背**（同一轮、同一台机器、取最快一次）相比，这一轮把算术循环加快了 2.2–4.7x（`arith-float` 4.7x）、`calls` 2.5x、表操作 1.1–1.6x，办法是把每次运算与每次调用里的堆分配去掉：`Value` 现在是 `#valtype`（宿主后端把它编成真正的 C 带标签联合，16 字节、不装箱，槽位读写不再分配），算术与比较直接读操作数而不再经过返回 `Option` 的辅助函数（`Option` 的载荷在原生后端会被装箱），一次普通返回不再为结果建临时数组（`Results` 把"值就在寄存器里"也表达出来），帧也不再为自己不会用到的两张表（保护与待关闭变量）分配空数组。随后一轮把 `string.gsub` 从最差的一项（25–36x）拉到 16x：替换文本直接写进结果缓冲（参考实现的 `add_s` 就是这个形状），不再为每次匹配建一个中间字符串，也不再在替换文本用不到捕获时先攒一个捕获数组——背靠背 A/B 是 **2x**；取子串则改成一次分配加一次 `memcpy`（此前经 `Buffer` 往返，要分配三次、拷贝两遍）。再往前一轮给表访问加了快速路径（参考实现 `luaV_fastget`/`luaV_fastset` 的形状）：整数与字符串键按原样读写、不再先归一化成一个 `Key`，无元表的表直接写入（同一笔里不再先查一次键、也不再每次为表的大小记账）。数组部分的存与取因此快 1.6–3x（bench 的 `table-array` 从 ~16x 降到 7.5x），`table.insert`/`remove` 的搬移段快约 3.5x。最近一轮把内建调用的 ABI 换掉了——前面说的"参数数组"和"结果数组"两次分配就是它的形状：参数不再复制成一个数组（交给内建体的是寄存器窗口的 `ArrayView`，`Frame` 只多记一个参数个数），结果也不再为每次调用建数组（`BuiltinResult` 的 `Nothing`/`One`/`Two` 直接写回该帧自己的寄存器——参数原来占的地方，参考实现的 C 函数也是这么压结果的——只有多值才带列表）。一次内建调用因此快 **39%**（`math.abs`）、**44%**（`next`，两个结果）、**14%**（`string.sub`，三个参数），端到端在这些 bench 里是 0–10%（大半时间花在循环与字节码上，不在这类调用里）。剩下的差距仍然是结构性的，而且不在分配器上：后端是一次性 C 编译器，不内联也不做寄存器分配，所以每个辅助函数调用、每次槽位搬移都是真调用。最新一轮轮到整数键，也就是数组部分接不住的那些下标的查找：它原先要**两次堆分配**——一个 `Hasher`（带 `mut` 字段，所以是堆对象）和一个 `KInt` 箱子。前者改成直接用 core 里已经内联了一版、累加器放在栈上的 `Hash::hash`；后者靠一个新的探针 `probe_int`——它只吃 `Int64`，不再为了搜一个整数而建 `Key`，`get_int`/`set_int`/`next`/`raw_len`/`migrate_following` 都走它，只有真要插入时才建箱子。进程内白盒 A/B（同一会话、每用例 9 轮取最小；数组部分的对照 2 ns 纹丝不动）：整数键查表 **103 → 41 ns（−60%）**，拆开看是 `Hasher` 约 31 ns 加 `KInt` 箱子约 32 ns，而纯哈希算术（`hash_nobox`）只有 1 ns——**这一枪打掉的全是分配，不是哈希**。改动是逐构造器比对过的：`KInt`/`KNum`/`KBool`/`KObj`/`KNil`/`KEmpty` 的新旧哈希值**完全相等**，所以槽位与 `next` 的遍历顺序一个字节都没变；两种探针的等价性另有一条常驻白盒测试钉住（含删除留下的死槽、以及 `next` 要用的 `for_next` 语义）。端到端 bench 那五个用例里没有整数哈希键的形状，因此只当回归对照用：与上一版二进制背靠背跑 5 轮，全部落在 0.8–1.2 且没有一致方向（连这轮碰不到的 `calls` 都读到过 1.2），即无可测回归。
* **宿主递归的深度上限由宿主还剩多少栈决定，而不是一个固定层数。** 参考实现用固定层数（`LUAI_MAXCCALLS` = 200）挡住"经宿主回调的递归"（`string.gsub` 的替换函数、`__index` 里再调回来），它假设一层 C 层只花几百字节。这里一层要花约 5 KB——同样的后端原因——于是那个层数在 1 MB 的默认栈上刚好卡在边缘：`cstack.lua` 的元表用例会真把栈耗尽（不是报错，是段错误）。所以 `call_value` 在参考实现的层数（190）之外还检查宿主剩多少栈（`MIN_HOST_STACK` = 256 KB，由 `stub.c` 的 `lua_mbt_stack_left` 给出，Windows 读线程栈边界、POSIX 读 `pthread_getattr_np`/`pthread_get_stackaddr_np`），拒绝时给参考实现的消息 "C stack overflow"。代价是**能递归的深度比参考实现浅**（本机 1 MB 栈上约 140–190 层，参考实现约 197 层），并且随宿主栈与调用处的环境深度变化；参考实现自己的测试文件也说这个数字取决于 `LUAI_MAXCCALLS` 与为程序保留的栈。
* **环不会被释放。** 内存由宿主运行时的引用计数回收；收集器判定可达性（这正是弱表、ephemeron 和 `__gc` 需要的），但它不做清扫。因此一个环会留到进程结束。

## 测试

```
moon test
```

* `tests/language.lua`、`tests/stdlib.lua`、`tests/require_test.lua`、`tests/examples.lua`、`tests/utf8_identifiers.lua` 和 `tests/native_libs.lua` 是由 `src/lua/suite_test.mbt` 通过解释器执行的 Lua 程序——和嵌入者使用的方式同形（黑盒），所以失败会带着出错的 Lua 行号报出来。前四个在参考实现下也通过（这次是实测：用 `zig cc` 现建的 5.4.9 参考二进制，四个文件当脚本各跑一遍）；**后两个不会**，它们跑的正是上面那两条本实现独有的扩展（`local 中 = 1` 参考实现就拒绝，`package.loadc` 它根本没有），分开成文件就是为了让「一致性套件」与「扩展套件」互不污染。这条「前四个也通过」的说法此前已经不成立了，是这一轮才修回去的三处：`language.lua` 里 `repeat ... until collectgarbage("step", n)` 那个循环在参考实现下永不结束（默认是**分代**模式，那里的 step 从不报告「一轮收集结束」），现在那段显式在增量模式下跑并给循环加了上限；`stdlib.lua` 断言 `load` 的 reader 报错原文的那条，在命令行下会多带一段 traceback（`lua` 为脚本装了消息处理器，`load` 读文件时它还在），现在只比第一行；`require_test.lua` 里「库开到了、入口也找到了、但不能进去」那一格是本实现独有的答案（参考实现此处交回一个可调用的函数），已搬进 `native_libs.lua`。
* 其余测试就放在它们所钉住的代码旁边：代码生成器产出的寄存器布局（`src/compiler/codegen_wbtest.mbt`）、`printf` 各转换、数字解析与名字字符的码点判定（`src/core/number_wbtest.mbt`）、chunk 前缀（BOM 与 `#` 首行）的剥离（`src/load/load_test.mbt`）、命令行的选项表、`-l name=module` 拆分与脚本 varargs（`cmd/main/main_wbtest.mbt`）、`luac` 的选项表与组合外壳和它的列示（`cmd/luac/main_wbtest.mbt`）、被启动的脚本看到的报错形态（`src/lua/launcher_test.mbt`）、以及宿主边界（`src/host/ffi_wbtest.mbt`）。
* 官方 Lua 5.4 测试套件是一致性的裁判。它不在本仓库分发——`tools/run_official_tests.mbtx` 需要 `lua-5.4.9-tests/` 下有一份拷贝；当前数字见上面 `## 状态`。
* 性能由 `bench/` 与 `tools/run_bench.mbtx` 度量：每个用例自带断言，打印一行 `bench <名字> <秒> <校验和>`；传入第二个解释器即可得到比值，`--repeat=N` 决定每个用例重复几次（默认 3，取最快一次）。改动前后要背靠背跑、比较**比值**，不要与上一轮的旧数字比较。

```
moon run --target native tools/run_bench.mbtx /path/to/reference/lua
```

## 许可证与来源

Apache-2.0，见 `LICENSE`。`NOTICE` 载有随之而来的署名，因为这里实现的行为是 Lua 的，是在其 MIT 许可下从参考实现移植的（`NOTICE` 中的许可原文保持英文原样）。

移植是依照以下来源写成的：

* **Lua 5.4.9**（参考实现），一切可观察行为都以它为准：`lparser.c`/`lcode.c`（单遍编译器的形态与语法错误消息）、`lvm.c`/`ldo.c`（指令语义、保护调用与 yield 的排布、展开时关闭变量的顺序）、`lgc.c`（收集规则及其执行顺序）、`lauxlib.c` 与 `l*baselib.c`/`lstrlib.c`/`ltablib.c`/`lmathlib.c`/`loslib.c`/`liolib.c`/`lcorolib.c`/`ldblib.c`/`lutf8lib.c`（参数检查与消息），以及 `lua.c`/`luac.c`/`loadlib.c`/`luaconf.h`（启动器、编译驱动程序、搜索路径与 `package`）。
* **Lua 5.4 参考手册**，用于明确语言承诺——当手册与实现不一致时，以实现为准。
* **官方测试套件**，作为裁判（见 `## 测试`）。
* **在本机用上述源码构建的 Lua 5.4.9 二进制**，用作差分对照：每一条被移植的行为，都是把同一个文件在两种实现下各跑一遍、比对整份日志得出的，而不是只读源码。
