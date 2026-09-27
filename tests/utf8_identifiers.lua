-- Names written in UTF-8: this is a deliberate extension, so it is the one
-- suite the reference implementation does not also pass.  The reference reads a
-- byte outside ASCII as a symbol and refuses the chunk ("<name> expected near
-- '<\228>'"), because its character table covers 0x00-0x7F only.  Here a well
-- formed code point is a name character, so a source file can name things in
-- the language it is written in.
--
-- What does *not* change is everything around it: a string literal, a comment,
-- a table key in brackets, a field read from a value and the `utf8` library all
-- behave exactly as before, and a byte string that is not valid UTF-8 is still
-- refused rather than read as a name.

local function eq(a, b, what)
  if a ~= b then
    error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2)
  end
end

local function msg(src, ...)
  local f, e = load(src, "=chunk")
  if f then return "loaded" end
  return e
end

-- ------------------------------------------------------------ names
local 中 = 1
local 名字 = "世界"
local 数量_1 = 2
local _下划线 = 3
local 字母A = 4
eq(中, 1, "a one-character name")
eq(名字, "世界", "a value under a Chinese name")
eq(数量_1 + _下划线 + 字母A, 9, "names mixing scripts, digits and underscores")
-- A code point is taken whole: an accented letter is two bytes, an emoji four.
local 😀 = "笑脸"
local café = 5
eq(😀, "笑脸", "an emoji name, four bytes long")
eq(café, 5, "a two byte name")

-- ------------------------------------------------------------ functions
function 打招呼(谁)
  return "你好，" .. 谁
end
eq(打招呼("世界"), "你好，世界", "a function named in Chinese")

local 阶乘
function 阶乘(n)
  if n <= 1 then return 1 end
  return n * 阶乘(n - 1)
end
eq(阶乘(5), 120, "recursion through a Chinese name")

local 上界 = 10
local 加上界 = function(x) return x + 上界 end
eq(加上界(1), 11, "a Chinese name is an ordinary upvalue")

-- ------------------------------------------------------------ tables
local 表 = {键 = "值", 数字 = 1}
eq(表.键, "值", "a field named in Chinese")
eq(表["键"], "值", "the same field through brackets")
表.新键 = 2
eq(表.新键, 2, "assigning to a Chinese field")
local 字段数 = 0
for _ in pairs(表) do 字段数 = 字段数 + 1 end
eq(字段数, 3, "a Chinese key is a key like any other")

local 对象 = {计数 = 0}
function 对象:加一()
  self.计数 = self.计数 + 1
  return self.计数
end
eq(对象:加一(), 1, "a method named in Chinese")
eq(对象:加一(), 2, "and it sees itself")

-- A Chinese name is a string, so what reports the name reports it in Chinese.
eq(select(2, pcall(function() return 表.没有的键.x end))
     :find("field '没有的键'", 1, true) ~= nil, true,
   "an error names the Chinese field it stopped on")
eq(select(2, pcall(对象.加一)):find("(local 'self')", 1, true) ~= nil, true,
   "a method taken out of its table fails on the self it is missing")

-- ------------------------------------------------------------ control flow
do
  local 合计 = 0
  for 序号 = 1, 4 do 合计 = 合计 + 序号 end
  eq(合计, 10, "a for loop variable named in Chinese")
  local 键列表 = {}
  for 键, 值 in pairs({甲 = 1, 乙 = 2}) do 键列表[#键列表 + 1] = 键 .. 值 end
  table.sort(键列表)
  -- Sorted by bytes: 乙 is E4 B9 99 and 甲 is E7 94 B2, so 乙 comes first.
  eq(table.concat(键列表), "乙2甲1", "a generic for over Chinese keys")
  local 次数 = 0
  ::再来::
  次数 = 次数 + 1
  if 次数 < 3 then goto 再来 end
  eq(次数, 3, "a goto label named in Chinese")
end

-- ------------------------------------------------------------ what did not change
eq(msg("return 1a"):find("malformed number", 1, true) ~= nil, true,
   "a numeral touching an ASCII letter is still a malformed number")
-- A non-ASCII character is absorbed whole, so the message names the character
-- the writer typed: `100万` is a malformed number, not `100` and a stray name.
eq(msg("return 100万"):find("malformed number near '100万'", 1, true) ~= nil, true,
   "and one touching a non-ASCII character names that character")
-- A byte string that is not UTF-8 is not a name.  E4 B8 is a three byte lead
-- with one continuation byte and then the end of the chunk; C4 E3 is GBK's 你,
-- which is two lead bytes in a row.
eq(msg("local \xE4\xB8"):find("<name> expected", 1, true) ~= nil, true,
   "a truncated sequence is not a name")
eq(msg("local \xC4\xE3"):find("<name> expected", 1, true) ~= nil, true,
   "and neither is a byte string in another encoding")

-- Chinese in the places that always accepted it.
local 文本 = "中文"
eq(#文本, 6, "a string literal is still bytes")
eq(utf8.len(文本), 2, "and the utf8 library still counts characters")
eq((文本):sub(1, 3), "\xE4\xB8\xAD", "and a substring is still byte oriented")
local 词频 = {}
for 词 in ("中文 中文 测试"):gmatch("%S+") do 词频[词] = (词频[词] or 0) + 1 end
eq(词频["中文"], 2, "Chinese strings still work as table keys")
eq(os.date("%Y年", 0), "1970年", "os.date still copies non-specifier bytes through")

print("utf8 identifiers: ok")
