// Serialising a function into a binary chunk.

///|
/// `LUA_SIGNATURE`.  A chunk is recognised by its first byte alone, as in the
/// reference: that byte is what tells source from precompiled code, so even a
/// chunk cut short after it counts as binary.
pub let chunk_signature : Bytes = b"\x1bLua"

///|
/// `LUAC_VERSION`.  The header is the Lua 5.4 header; what follows it is this
/// interpreter's own encoding of the prototype.
pub const CHUNK_VERSION : Int = 0x54

///|
/// `LUAC_FORMAT`.
pub const CHUNK_FORMAT : Int = 0

///|
/// `LUAC_DATA`: bytes that no translation of this file is expected to survive,
/// which is what makes a chunk written by another build be refused.
pub let chunk_data : Bytes = b"\x19\x93\x0d\x0a\x1a\x0a"

///|
/// The three sizes the header records, and the two numbers that show how a
/// 64 bit integer and a 64 bit float are stored.  They say "this is a Lua 5.4
/// header written by this build"; what follows the header is this interpreter's
/// own encoding of the prototype, which these sizes do not describe.
pub const SIZEOF_INSTRUCTION : Int = 4

///|
pub const SIZEOF_INTEGER : Int = 8

///|
pub const SIZEOF_NUMBER : Int = 8

///|
pub const LUAC_INT : Int64 = 0x5678L

///|
pub const LUAC_NUM : Double = 370.5

///|----------------------------------------------------------------
/// Writing

///|----------------------------------------------------------------

///|
/// A little endian binary writer.
pub(all) struct BinWriter {
  buf : Buffer
}

///|
pub fn BinWriter::new() -> BinWriter {
  { buf: Buffer::Buffer(size_hint=256), }
}

///|
pub fn BinWriter::u8(self : BinWriter, v : Int) -> Unit {
  self.buf.write_byte((v & 0xff).to_byte())
}

///|
pub fn BinWriter::u32(self : BinWriter, v : Int) -> Unit {
  let mut n = v
  let mut i = 0
  while i < 4 {
    self.buf.write_byte((n & 0xff).to_byte())
    n = n >> 8
    i = i + 1
  }
}

///|
pub fn BinWriter::i64(self : BinWriter, v : Int64) -> Unit {
  let mut n = v.reinterpret_as_uint64()
  let mut i = 0
  while i < 8 {
    self.buf.write_byte((n.to_int() & 0xff).to_byte())
    n = n >> 8
    i = i + 1
  }
}

///|
pub fn BinWriter::f64(self : BinWriter, v : Double) -> Unit {
  self.i64(v.reinterpret_as_int64())
}

///|
pub fn BinWriter::bytes(self : BinWriter, b : Bytes) -> Unit {
  self.u32(b.length())
  if b.length() > 0 {
    self.buf.write_bytes(b.view())
  }
}

///|
pub fn BinWriter::string(self : BinWriter, s : @core.LStr) -> Unit {
  self.bytes(s.data())
}

///|
/// The header every chunk this interpreter writes begins with.
pub fn BinWriter::header(self : BinWriter) -> Unit {
  self.buf.write_bytes(chunk_signature.view())
  self.u8(CHUNK_VERSION)
  self.u8(CHUNK_FORMAT)
  self.buf.write_bytes(chunk_data.view())
  self.u8(SIZEOF_INSTRUCTION)
  self.u8(SIZEOF_INTEGER)
  self.u8(SIZEOF_NUMBER)
  self.i64(LUAC_INT)
  self.f64(LUAC_NUM)
}

///|
pub fn BinWriter::proto(
  self : BinWriter,
  p : @core.LProto,
  strip : Bool,
  top : Bool,
) -> Unit {
  self.u8(p.numparams)
  self.u8(if p.is_vararg { 1 } else { 0 })
  self.u32(p.maxstack)
  self.u32(p.line_defined)
  self.u32(p.last_line_defined)
  // The source is written once, for the outermost function: the nested ones
  // inherit it, which is what keeps a dump of a long-named chunk small.  A
  // stripped chunk carries no source at all -- a state the loader keeps apart
  // from a source that happens to be the empty string.
  if strip || !top {
    self.u8(0)
  } else {
    self.u8(1)
    self.string(p.source)
  }
  if strip {
    self.bytes(@core.bytes_of(""))
  } else {
    self.bytes(@core.bytes_of(p.name))
  }
  self.u32(p.code.length())
  for ins in p.code {
    self.u8(ins.op)
    self.u32(ins.a)
    self.u32(ins.b)
    self.u32(ins.c)
  }
  if strip {
    self.u32(0)
  } else {
    self.u32(p.lines.length())
    for l in p.lines {
      self.u32(l)
    }
  }
  if strip {
    self.u32(0)
  } else {
    self.u32(p.locvars.length())
    for v in p.locvars {
      self.string(v.name)
      self.u32(v.start_pc)
      self.u32(v.end_pc)
      self.u8(v.attrib)
    }
  }
  self.u32(p.upvals.length())
  for u in p.upvals {
    if strip {
      self.string(@core.LStr::empty())
    } else {
      self.string(u.name)
    }
    self.u8(if u.in_stack { 1 } else { 0 })
    self.u32(u.index)
    self.u8(u.attrib)
  }
  self.u32(p.constants.length())
  for c in p.constants {
    match c {
      @core.VNil => self.u8(0)
      @core.VBool(b) => {
        self.u8(1)
        self.u8(if b { 1 } else { 0 })
      }
      @core.VInt(i) => {
        self.u8(2)
        self.i64(i)
      }
      @core.VNum(d) => {
        self.u8(3)
        self.f64(d)
      }
      @core.VStr(s) => {
        self.u8(4)
        self.string(s)
      }
      _ => self.u8(0)
    }
  }
  self.u32(p.protos.length())
  for sub in p.protos {
    self.proto(sub, strip, false)
  }
}

///|
/// `string.dump`.
pub fn str_dump(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  // A missing argument reports "no value" here, like every other typed check.
  let v = @core.check_present(state, args, 1, "dump", "function")
  let cl = match v {
    @core.VFunc(f) => f
    _ =>
      @core.arg_error(
        state,
        1,
        "dump",
        "function expected, got " + @core.type_error_name(state, v),
      )
  }
  let strip = @core.is_truthy_arg(state, args, 2)
  let w = BinWriter::new()
  w.header()
  w.proto(cl.proto, strip, true)
  [@core.VStr(@core.LStr::of_bytes(w.buf.to_bytes()))]
}

///|
pub fn BinReader::new(data : Bytes) -> BinReader {
  { data, pos: 0, failed: false, }
}

///|
pub fn BinReader::u8(self : BinReader) -> Int {
  if self.pos >= self.data.length() {
    self.failed = true
    return 0
  }
  let v = @core.ubyte_at(self.data, self.pos)
  self.pos = self.pos + 1
  v
}

///|
pub fn BinReader::u32(self : BinReader) -> Int {
  let mut acc = 0
  let mut shift = 0
  let mut i = 0
  while i < 4 {
    acc = acc | (self.u8() << shift)
    shift = shift + 8
    i = i + 1
  }
  acc
}

///|
pub fn BinReader::i64(self : BinReader) -> Int64 {
  let mut acc : UInt64 = 0UL
  let mut shift = 0
  let mut i = 0
  while i < 8 {
    acc = acc | (self.u8().to_uint64() << shift)
    shift = shift + 8
    i = i + 1
  }
  acc.reinterpret_as_int64()
}

///|
pub fn BinReader::f64(self : BinReader) -> Double {
  self.i64().reinterpret_as_double()
}

///|
pub fn BinReader::bytes(self : BinReader) -> Bytes {
  let n = self.u32()
  if self.failed || n < 0 || self.pos + n > self.data.length() {
    self.failed = true
    return Bytes::new(0)
  }
  let out = @core.bytes_slice(self.data, self.pos, n)
  self.pos = self.pos + n
  out
}

///|
pub fn BinReader::string(self : BinReader) -> @core.LStr {
  @core.LStr::of_bytes(self.bytes())
}

///|
pub fn BinReader::proto(
  self : BinReader,
  parent_source : @core.LStr,
) -> @core.LProto {
  let numparams = self.u8()
  let is_vararg = self.u8() != 0
  let maxstack = self.u32()
  let line_defined = self.u32()
  let last_line = self.u32()
  // No source of its own means the chunk was stripped, or that this is a
  // nested function: either way the enclosing source stands, and the outermost
  // one has none at all.
  let has_own_source = self.u8() != 0
  let source = if has_own_source { self.string() } else { parent_source }
  let proto_name = @core.text_of(self.bytes())
  let code : Array[@core.Instr] = []
  let ncode = self.u32()
  let mut i = 0
  while i < ncode && !self.failed {
    let op = self.u8()
    let a = self.u32()
    let b = self.u32()
    let c = self.u32()
    code.push(@core.instr(op, a, b, c))
    i = i + 1
  }
  let lines : Array[Int] = []
  let nlines = self.u32()
  let mut i2 = 0
  while i2 < nlines && !self.failed {
    lines.push(self.u32())
    i2 = i2 + 1
  }
  let locvars : Array[@core.LocVar] = []
  let nloc = self.u32()
  let mut i3 = 0
  while i3 < nloc && !self.failed {
    let nm = self.string()
    let start_pc = self.u32()
    let end_pc = self.u32()
    let attrib = self.u8()
    locvars.push({ name: nm, start_pc, end_pc, attrib, })
    i3 = i3 + 1
  }
  let upvals : Array[@core.UpvalDesc] = []
  let nup = self.u32()
  let mut i4 = 0
  while i4 < nup && !self.failed {
    let nm = self.string()
    let in_stack = self.u8() != 0
    let index = self.u32()
    let attrib = self.u8()
    upvals.push({ name: nm, in_stack, index, attrib, })
    i4 = i4 + 1
  }
  let constants : Array[@core.Value] = []
  let nk = self.u32()
  let mut i5 = 0
  while i5 < nk && !self.failed {
    let tag = self.u8()
    match tag {
      0 => constants.push(@core.VNil)
      1 => constants.push(@core.VBool(self.u8() != 0))
      2 => constants.push(@core.VInt(self.i64()))
      3 => constants.push(@core.VNum(self.f64()))
      4 => constants.push(@core.VStr(self.string()))
      _ => {
        self.failed = true
        constants.push(@core.VNil)
      }
    }
    i5 = i5 + 1
  }
  let protos : Array[@core.LProto] = []
  let nsub = self.u32()
  let mut i6 = 0
  while i6 < nsub && !self.failed {
    protos.push(self.proto(source))
    i6 = i6 + 1
  }
  {
    code,
    lines,
    constants,
    protos,
    upvals,
    numparams,
    is_vararg,
    maxstack,
    source,
    line_defined,
    last_line_defined: last_line,
    locvars,
    name: proto_name,
  }
}
