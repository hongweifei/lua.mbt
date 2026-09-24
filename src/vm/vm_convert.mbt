// Conversion to text and other coercions.

///|
pub fn[T] type_error(
  st : @core.LuaState,
  action : String,
  v : @core.Value,
  hint : String,
) -> T raise @core.LuaRaised {
  let name = @core.type_error_name(st, v)
  let suffix = if hint.length() > 0 { " (" + hint + ")" } else { "" }
  @core.raise_fresh(
    st,
    @core.VStr(
      @core.LStr::of_string(
        @core.vm_position(st) +
        "attempt to " +
        action +
        " a " +
        name +
        " value" +
        suffix,
      ),
    ),
  )
}

///|
pub fn[T] invalid_key_error(
  st : @core.LuaState,
  k : @core.Value,
) -> T raise @core.LuaRaised {
  let msg = match k {
    @core.VNil => "table index is nil"
    @core.VNum(d) =>
      if d.is_nan() {
        "table index is NaN"
      } else {
        "invalid table key"
      }
    _ => "invalid table key"
  }
  @core.vm_error(st, msg)
}

///|----------------------------------------------------------------
/// Arithmetic

///|----------------------------------------------------------------

///|
/// The error for using a float where an integer is required.
pub fn[T] no_integer_representation(
  st : @core.LuaState,
  v : @core.Value,
  slot : Int,
) -> T raise @core.LuaRaised {
  let _ = v
  let info = @core.var_info(st, slot)
  let extra = if info.length() > 0 { " (" + info + ")" } else { "" }
  @core.raise_fresh(
    st,
    @core.VStr(
      @core.LStr::of_string(
        @core.vm_position(st) +
        "number" +
        extra +
        " has no integer representation",
      ),
    ),
  )
}

///|
/// The error reported when no metamethod applies.  The caller picks which
/// operand is to blame, as the reference does, and `slot` is where that operand
/// was read from, so the message can name it.
pub fn[T] op_error(
  st : @core.LuaState,
  verb : String,
  blame : @core.Value,
  slot : Int,
) -> T raise @core.LuaRaised {
  type_error(st, verb, blame, @core.var_info(st, slot))
}

///|
/// The error for a metamethod that exists but cannot be called: the reference
/// reports it as a call of the metamethod.
pub fn[T] bad_metamethod_call(
  st : @core.LuaState,
  tm : @core.Value,
  tm_name : String,
) -> T raise @core.LuaRaised {
  type_error(st, "call", tm, @core.metamethod_info(tm_name))
}

///|
/// The default textual form of any value, honouring `__tostring`.  This is the
/// reference's `luaL_tolstring`: a `__tostring` may return a number as well as a
/// string (`lua_isstring` accepts both, and `lua_tolstring` then writes the
/// number out), and only anything else is refused.
pub fn to_string(
  st : @core.LuaState,
  v : @core.Value,
) -> Bytes raise @core.LuaRaised {
  match v {
    @core.VStr(s) => s.data()
    @core.VNil => @core.bytes_of("nil")
    @core.VBool(b) =>
      if b {
        @core.bytes_of("true")
      } else {
        @core.bytes_of("false")
      }
    @core.VInt(_) | @core.VNum(_) => @core.number_to_bytes(v)
    _ => {
      let h = metafield(st, v, "__tostring")
      if is_callable(h) {
        let res = call_metamethod(st, h, [v], 1, "")
        let result = nth_or_nil(res, 0)
        match result {
          @core.VStr(s) => return s.data()
          @core.VInt(_) | @core.VNum(_) => return @core.number_to_bytes(result)
          _ => @core.runtime_error(st, "'__tostring' must return a string")
        }
      }
      let name = match metatable_of(st, v) {
        Some(mt) =>
          match mt.get_str("__name") {
            @core.VStr(s) => @core.text_of(s.data())
            _ => v.type_name()
          }
        None => v.type_name()
      }
      @core.bytes_of(name + ": " + object_address(v))
    }
  }
}

///|
pub fn nth_or_nil(vals : Array[@core.Value], i : Int) -> @core.Value {
  if i < vals.length() {
    vals[i]
  } else {
    @core.VNil
  }
}

///|
/// A stable hexadecimal identity for an object, used in default `tostring`
/// output.  It is derived from the identity the interpreter already assigns to
/// every object.
pub fn object_address(v : @core.Value) -> String {
  @core.hex_address(v.object_id().to_int64())
}
