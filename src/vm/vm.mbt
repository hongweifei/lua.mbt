// The virtual machine.

///|
pub fn execute(
  st : @core.LuaState,
  thread : @core.LThread,
  floor : Int,
) -> @core.RunStatus raise @core.LuaRaised {
  let mut ci = thread.frames.length() - 1
  if ci < floor {
    return @core.RFinished([])
  }
  let mut fr = thread.frames[ci]
  let mut pc = fr.pc
  let mut base = fr.base
  while true {
    // A frame that was suspended inside a metamethod call finishes the
    // instruction that started it before anything else runs: the result is
    // already on the stack, and taking it is all that instruction has left.
    if fr.pending_finish >= 0 {
      pc = finish_pending(st, thread, fr)
      fr.pc = pc
      base = fr.base
    }
    let closure = fr.closure
    match closure {
      None => {
        // A native frame: run the host function once and return its results.
        let b = match fr.builtin {
          Some(b) => b
          None => @core.vm_error(st, "corrupt frame")
        }
        // A marker whose protected call failed and whose `__close` handlers
        // were interrupted by a yield finishes them here, on the pass that
        // reaches it again, and only then completes with its `false, error`.
        match fr.pending_closes {
          Some(doomed) => {
            let err = close_detached(
              st,
              thread,
              Some(fr),
              doomed,
              fr.pending_err,
            )
            fr.pending_closes = None
            st.err_room = fr.pending_room
            match complete_frame(st, thread, ci, floor, Listed([err]), false) {
              Some(vals) => return @core.RFinished(vals)
              None => ()
            }
            ci = thread.frames.length() - 1
            if ci < floor {
              return @core.RFinished([])
            }
            fr = thread.frames[ci]
            pc = fr.pc
            base = fr.base
            continue
          }
          None => ()
        }
        let resuming = b.kind == @core.BK_YIELD && thread.resume_vals is Some(_)
        // A builtin whose call into Lua was suspended and whose results are
        // already waiting: the resume finishes it with them.
        let resuming_result = fr.pending_result
        if resuming_result is Some(_) {
          fr.pending_result = None
        }
        // The frame a suspended coroutine stopped in, the level a protected
        // call stands for, and a builtin that was interrupted in the Lua it
        // called, are all finished rather than run: the first takes the values
        // a later `resume` passed in, the second collects the ones the
        // protected function already left in its own slot, and the third takes
        // the ones its call produced.
        let finished : Array[@core.Value]? = if fr.protect_frame {
          let count = if fr.nres_wanted < 0 {
            fr.top - fr.func_slot
          } else {
            fr.nres_wanted
          }
          Some(collect_results(thread, fr.func_slot, count))
        } else if resuming_result is Some((slot, count)) {
          Some(collect_results(thread, slot, count))
        } else if resuming {
          match thread.resume_vals {
            Some(vals) => Some(vals)
            None => Some([])
          }
        } else {
          None
        }
        let results = match finished {
          Some(vals) => vals
          None =>
            if b.kind == @core.BK_YIELD {
              // A `yield` that reached a frame of its own instead of being
              // dispatched as the instruction's callee: it stands as the
              // argument of a protected call, as in `xpcall(coroutine.yield,
              // h)`.  It suspends the thread just the same, leaving the
              // protection pending until a later resume lands here again.
              if thread.ny > 0 {
                raise_yield_error(st, thread)
              }
              return @core.RYield(fr.varargs)
            } else {
              (b.body)(st, b.upvals, fr.varargs)
            }
        }
        if resuming {
          thread.resume_vals = None
        }
        let reports = finished is None || resuming_result is Some(_)
        let mask = thread.hook_mask & @core.HOOK_RETURN
        if reports && mask != 0 && !thread.hook_running {
          // A host function returns over its own arguments, which is where
          // the reference's return hook finds them.  The frame is finished
          // from the values themselves, not from these slots.
          thread.ensure_stack(fr.base + results.length())
          let mut i = 0
          while i < results.length() {
            thread.stack[fr.base + i] = results[i]
            i = i + 1
          }
          hook_return_event(st, thread, 1, results.length())
        }
        match complete_frame(st, thread, ci, floor, Listed(results), true) {
          Some(vals) => return @core.RFinished(vals)
          None => ()
        }
        ci = thread.frames.length() - 1
        if ci < floor {
          return @core.RFinished([])
        }
        fr = thread.frames[ci]
        pc = fr.pc
        base = fr.base
      }
      Some(cl) => {
        let proto = cl.proto
        // Automatic collection, checked between two instructions: that is the
        // safe point.  Nothing the running instruction has half-built is
        // looked at, and a `__gc` handler the collection calls runs in frames
        // of its own above this one, so this frame's `pc` and `base` are left
        // alone.
        // The figure the threshold is compared against is the one `count`
        // reports, strings included: a loop that only builds strings has to
        // reach a collection too.
        if st.gc_running && @core.live_size(st) >= st.gc_threshold {
          collect_and_retune(st)
        }
        // Debug hooks: the count event fires every N instructions, the line
        // event fires when the instruction's line differs from the last one
        // reported on this frame.  The current pc is stored in the frame so
        // that a hook inspecting the stack sees this exact position.
        if thread.hook_mask != 0 || thread.hook_base_count > 0 {
          fr.pc = pc
          let saved_base = base
          hook_tick(st, thread, fr, pc)
          fr = thread.frames[ci]
          pc = fr.pc
          base = saved_base
        }
        let inst = proto.code[pc]
        pc = pc + 1
        // Instructions that can raise record their position first, so that the
        // error names the line that actually failed.
        if may_raise(inst.op) {
          fr.pc = pc
        }
        match inst.op {
          @core.OP_MOVE =>
            thread.stack[base + inst.a] = thread.stack[base + inst.b]
          @core.OP_LOADK =>
            thread.stack[base + inst.a] = proto.constants[inst.b]
          @core.OP_LOADNIL => {
            let mut i = 0
            while i < inst.b {
              thread.stack[base + inst.a + i] = @core.VNil
              i = i + 1
            }
          }
          @core.OP_LOADBOOL => {
            thread.stack[base + inst.a] = @core.VBool(inst.b != 0)
            if inst.c != 0 {
              pc = pc + 1
            }
          }
          @core.OP_GETUPVAL =>
            thread.stack[base + inst.a] = cl.upvals[inst.b].get()
          @core.OP_SETUPVAL =>
            cl.upvals[inst.b].set(thread.stack[base + inst.a])
          @core.OP_GETTABLE => {
            let t = thread.stack[base + inst.b]
            let k = rk_value(proto, thread, base, inst.c)
            thread.stack[base + inst.a] = index_get(st, t, k, base + inst.b)
          }
          @core.OP_SETTABLE => {
            let t = thread.stack[base + inst.a]
            let k = rk_value(proto, thread, base, inst.b)
            let v = rk_value(proto, thread, base, inst.c)
            index_set(st, t, k, v, base + inst.a)
          }
          @core.OP_GETTABUP => {
            let t = cl.upvals[inst.b].get()
            let k = rk_value(proto, thread, base, inst.c)
            thread.stack[base + inst.a] = index_get(
              st,
              t,
              k,
              @core.up_src(inst.b),
            )
          }
          @core.OP_SETTABUP => {
            let t = cl.upvals[inst.a].get()
            let k = rk_value(proto, thread, base, inst.b)
            let v = rk_value(proto, thread, base, inst.c)
            index_set(st, t, k, v, @core.up_src(inst.a))
          }
          @core.OP_NEWTABLE => {
            // The reference raises the live limit to the register it is about
            // to fill before allocating, so that a collection this allocation
            // triggers still sees everything the frame holds (`OP_NEWTABLE`'s
            // `L->top.p = ra + 1`).
            fr.top = base + inst.a + 1
            thread.stack[base + inst.a] = @core.VTable(@core.LTable::new())
            // The table's own cost is charged where it is made
            // (`LTable::new`), so that a table a library function builds counts
            // the same way.
          }
          @core.OP_SELF => {
            let t = thread.stack[base + inst.b]
            thread.stack[base + inst.a + 1] = t
            let k = rk_value(proto, thread, base, inst.c)
            thread.stack[base + inst.a] = index_get(st, t, k, base + inst.b)
          }
          @core.OP_ADD
          | @core.OP_SUB
          | @core.OP_MUL
          | @core.OP_DIV
          | @core.OP_MOD
          | @core.OP_POW
          | @core.OP_IDIV
          | @core.OP_BAND
          | @core.OP_BOR
          | @core.OP_BXOR
          | @core.OP_SHL
          | @core.OP_SHR => {
            let x = rk_value(proto, thread, base, inst.b)
            let y = rk_value(proto, thread, base, inst.c)
            st.slot_x = rk_slot(inst.b, base)
            st.slot_y = rk_slot(inst.c, base)
            thread.stack[base + inst.a] = arith(
              st,
              // `OP_ADD`..`OP_SHR` stand in the same order as
              // `BINOP_ADD`..`BINOP_SHR`, so the opcode is already the operator
              // code plus this offset.
              inst.op - @core.OP_ADD,
              x,
              y,
            )
          }
          @core.OP_UNM | @core.OP_BNOT | @core.OP_NOT | @core.OP_LEN => {
            let x = rk_value(proto, thread, base, inst.b)
            st.slot_x = rk_slot(inst.b, base)
            st.slot_y = st.slot_x
            thread.stack[base + inst.a] = unop(st, opcode_to_unop(inst.op), x)
          }
          @core.OP_CONCAT => {
            let first = base + inst.a
            let n = inst.b - inst.a + 1
            // `L->top.p = ra + n` marks the end of the operands, which is the
            // live limit a collection inside the fold has to see.
            fr.top = first + n
            thread.stack[first] = concat_fold(
              st,
              thread,
              fr,
              pc - 1,
              first,
              n - 1,
              thread.stack[first + n - 1],
            )
          }
          @core.OP_JMP => {
            // A jump carries the level it has to close down to: a `goto` or a
            // `break` that leaves the scope of a to-be-closed variable runs its
            // handler here, as `dojump` does with `luaF_close`.
            if inst.a != 0 {
              close_to_level(st, thread, fr, base + inst.a - 1, "close")
            }
            pc = pc + inst.c
          }
          @core.OP_EQ => {
            let x = rk_value(proto, thread, base, inst.b)
            let y = rk_value(proto, thread, base, inst.c)
            let r = equals(st, x, y)
            if r != (inst.a != 0) {
              pc = pc + 1
            }
          }
          @core.OP_LT => {
            let x = rk_value(proto, thread, base, inst.b)
            let y = rk_value(proto, thread, base, inst.c)
            let r = less_than(st, x, y)
            if r != (inst.a != 0) {
              pc = pc + 1
            }
          }
          @core.OP_LE => {
            let x = rk_value(proto, thread, base, inst.b)
            let y = rk_value(proto, thread, base, inst.c)
            let r = less_equal(st, x, y)
            if r != (inst.a != 0) {
              pc = pc + 1
            }
          }
          @core.OP_TEST => {
            let v = thread.stack[base + inst.a]
            if v.is_truthy() != (inst.c != 0) {
              pc = pc + 1
            }
          }
          @core.OP_TESTSET => {
            let v = thread.stack[base + inst.b]
            if v.is_truthy() == (inst.c != 0) {
              thread.stack[base + inst.a] = v
            } else {
              pc = pc + 1
            }
          }
          @core.OP_CALL => {
            let func_slot = base + inst.a
            // `L->top.p = ra + b`: with a fixed count the top signals where the
            // arguments end, and a collection started by the call has to see
            // them.
            if inst.b != 0 {
              fr.top = func_slot + inst.b
            }
            let nargs = if inst.b == 0 {
              fr.top - func_slot - 1
            } else {
              inst.b - 1
            }
            let want = if inst.c == 0 { -1 } else { inst.c - 1 }
            let callee = thread.stack[func_slot]
            let special = match callee {
              @core.VBuiltin(b) => b.kind
              _ => @core.BK_NORMAL
            }
            if special == @core.BK_YIELD {
              if thread.ny > 0 {
                raise_yield_error(st, thread)
              }
              // The yield is a host call like any other, so it reports the
              // events around it: the call event here, the return event when a
              // later resume finishes the call.  Its frame stays on the stack
              // while the thread is suspended, which is what makes it show up
              // as a level of `debug.getinfo` and `debug.traceback`.
              if (thread.hook_mask & @core.HOOK_CALL) != 0 &&
                !thread.hook_running {
                hook_call_event(st, thread, nargs, false)
              }
              fr.pc = pc
              push_frame(
                st, thread, func_slot, nargs, func_slot, want, func_slot, 0,
              )
              return @core.RYield(collect_results(thread, func_slot + 1, nargs))
            }
            fr.pc = pc
            let mut slot = func_slot
            let mut count = nargs
            let mut prot : @core.Cont? = None
            if special == @core.BK_PCALL {
              if nargs < 1 {
                @core.arg_error(st, 1, "pcall", "value expected")
              }
              let target = thread.stack[func_slot + 1]
              slot = thread.stack.length()
              thread.stack.push(target)
              let mut i = 2
              while i <= nargs {
                thread.stack.push(thread.stack[func_slot + i])
                i = i + 1
              }
              count = nargs - 1
              prot = Some(@core.ContPCall)
            } else if special == @core.BK_XPCALL {
              if nargs < 2 {
                @core.arg_error(st, 2, "xpcall", "value expected")
              }
              let target = thread.stack[func_slot + 1]
              let handler = thread.stack[func_slot + 2]
              slot = thread.stack.length()
              thread.stack.push(target)
              let mut i = 3
              while i <= nargs {
                thread.stack.push(thread.stack[func_slot + i])
                i = i + 1
              }
              count = nargs - 2
              prot = Some(@core.ContXPCall(handler))
            }
            // The reference charges one C level for every call that re-enters
            // Lua, which is what stops a chain of `pcall` long before the
            // frames run out.  A protection is counted as it is installed, so
            // that the level it stands for can report the overflow itself.
            // The protected call stands in the stack as a level of its own,
            // with the function it protects as that level's child, so that
            // `debug.getinfo(2)` inside a `__close` handler names `pcall`.
            let mut marker = -1
            if prot is Some(_) {
              marker = push_protection_for(
                st, thread, callee, func_slot, nargs, want,
              )
            }
            // The protection belongs to the marker, not to the frame of the
            // function it protects: that frame is not built yet, and a value
            // that cannot be called never gets one, so `pcall(nil, x)` has to
            // report its error to `pcall`'s caller rather than out of the
            // program.
            match prot {
              Some(p) => {
                if marker >= 0 {
                  thread.frames[marker].push_prot(p)
                  thread.frames[marker].saved_errfunc = thread.errfunc
                  // A protection with no handler still hides the enclosing
                  // one, which is what `luaD_pcall` does by setting the field
                  // to zero for the duration of a plain `pcall`.
                  thread.errfunc = match p {
                    @core.ContXPCall(h) => h
                    @core.ContPCall => @core.VNil
                  }
                }
                enter_protection(st, thread)
              }
              None => ()
            }
            push_frame(st, thread, slot, count, func_slot, want, func_slot, 0)
            let nf = thread.frames.length() - 1
            thread.frames[nf].call_line = @core.line_at(proto, pc - 1)
            ci = nf
            fr = thread.frames[ci]
            pc = fr.pc
            base = fr.base
            if (thread.hook_mask & @core.HOOK_CALL) != 0 && !thread.hook_running {
              fr.pc = pc
              hook_call_event(st, thread, nargs, false)
              fr = thread.frames[ci]
              pc = fr.pc
              base = fr.base
            }
          }
          @core.OP_TAILCALL => {
            let func_slot = base + inst.a
            if inst.b != 0 {
              fr.top = func_slot + inst.b
            }
            let nargs = if inst.b == 0 {
              fr.top - func_slot - 1
            } else {
              inst.b - 1
            }
            let special = match thread.stack[func_slot] {
              @core.VBuiltin(b) => b.kind
              _ => @core.BK_NORMAL
            }
            if special == @core.BK_YIELD {
              // `return coroutine.yield(x)` still yields to this frame's
              // caller: the frame stays where it is and the yield gets one of
              // its own, so the unreachable RETURN after this instruction
              // forwards what a later resume passes in.
              if thread.ny > 0 {
                raise_yield_error(st, thread)
              }
              if (thread.hook_mask & @core.HOOK_CALL) != 0 &&
                !thread.hook_running {
                hook_call_event(st, thread, nargs, false)
              }
              fr.pc = pc
              push_frame(
                st, thread, func_slot, nargs, func_slot, -1, func_slot, 0,
              )
              return @core.RYield(collect_results(thread, func_slot + 1, nargs))
            }
            fr.pc = pc
            let closure_takes_frame = match thread.stack[func_slot] {
              @core.VFunc(_) => true
              _ => false
            }
            if fr.prots.length() > 0 || !closure_takes_frame {
              // Only a Lua closure can take the frame over.  A host function
              // runs in a frame of its own while the tail-calling frame stays
              // where it is, which is what lets that frame still show up as a
              // level of the stack; the unreachable RETURN after this
              // instruction forwards whatever the call produced.
              push_frame(
                st, thread, func_slot, nargs, func_slot, -1, func_slot, 0,
              )
              ci = thread.frames.length() - 1
              thread.frames[ci].call_line = @core.line_at(proto, pc - 1)
              fr = thread.frames[ci]
              pc = fr.pc
              base = fr.base
              if (thread.hook_mask & @core.HOOK_CALL) != 0 &&
                !thread.hook_running {
                fr.pc = pc
                hook_call_event(st, thread, nargs, false)
                fr = thread.frames[ci]
                pc = fr.pc
                base = fr.base
              }
            } else {
              let dst = fr.func_slot
              // The callee takes over this frame's slots, so anything the frame
              // still holds open has to be snapshotted first: an upvalue that
              // points at a local here would otherwise read the argument the
              // tail call copies over it.
              close_upvalues(thread, fr.base)
              thread.stack[dst] = thread.stack[func_slot]
              let mut i = 0
              while i < nargs {
                thread.stack[dst + 1 + i] = thread.stack[func_slot + 1 + i]
                i = i + 1
              }
              let ret_slot = fr.ret_slot
              let want = fr.nres_wanted
              let tailcalls = fr.tailcalls + 1
              close_frame(st, thread, ci, @core.VNil, "close")
              thread.frames.truncate(ci)
              push_frame(st, thread, dst, nargs, ret_slot, want, func_slot, 0)
              ci = thread.frames.length() - 1
              thread.frames[ci].tailcalls = tailcalls
              fr = thread.frames[ci]
              pc = fr.pc
              base = fr.base
              if (thread.hook_mask & @core.HOOK_CALL) != 0 &&
                !thread.hook_running {
                fr.pc = pc
                hook_call_event(st, thread, nargs, true)
                fr = thread.frames[ci]
                pc = fr.pc
                base = fr.base
              }
            }
          }
          @core.OP_RETURN => {
            let n = if inst.b == 0 {
              fr.top - (base + inst.a)
            } else {
              inst.b - 1
            }
            fr.pc = pc
            // The frame's to-be-closed variables go before its return event,
            // so a handler that turns the hook on is still followed by the
            // event for this very return: the reference closes first and only
            // then reaches `luaD_poscall`, which is what reports it.
            close_frame(st, thread, ci, @core.VNil, "close")
            if (thread.hook_mask & @core.HOOK_RETURN) != 0 &&
              !thread.hook_running {
              hook_return_event(st, thread, inst.a + 1, n)
            }
            // The results stay where the frame left them; they are copied into
            // the caller's registers by `complete_frame`.
            match
              complete_frame(
                st,
                thread,
                ci,
                floor,
                OnStack(base + inst.a, n),
                true,
              ) {
              Some(results) => return @core.RFinished(results)
              None => ()
            }
            ci = thread.frames.length() - 1
            if ci < floor {
              return @core.RFinished([])
            }
            fr = thread.frames[ci]
            pc = fr.pc
            base = fr.base
          }
          @core.OP_FORPREP => {
            let step = thread.stack[base + inst.a + 2]
            if is_zero_step(step) {
              @core.vm_error(st, "'for' step is zero")
            }
            let run = prepare_for(st, thread, base + inst.a)
            if !run {
              // The loop cannot run: land past its test, as the reference's
              // FORPREP does.  Otherwise the body comes first, and FORLOOP
              // decides whether there is another round.
              pc = pc + inst.c + 1
            }
          }
          @core.OP_FORLOOP => {
            let a = base + inst.a
            let step = thread.stack[a + 2]
            let cont = match step {
              // An integer loop runs off its counter, which `prepare_for` put
              // where the limit was; the index is simply advanced by the step,
              // and the last such advance is never performed.
              @core.VInt(s) => {
                let count = match thread.stack[a + 1] {
                  @core.VInt(c) => c
                  _ => 0L
                }
                if count.reinterpret_as_uint64() == 0UL {
                  false
                } else {
                  let idx = match thread.stack[a] {
                    @core.VInt(v) => v
                    _ => for_error(st, "initial value", thread.stack[a])
                  }
                  // The addition is done in unsigned arithmetic, which wraps,
                  // so that a step of the smallest integer behaves as the
                  // reference's two's complement one does.
                  let u = idx.reinterpret_as_uint64()
                  let u = u + s.reinterpret_as_uint64()
                  let idx = u.reinterpret_as_int64()
                  thread.stack[a] = @core.VInt(idx)
                  thread.stack[a + 1] = @core.VInt(
                    (count.reinterpret_as_uint64() - 1UL).reinterpret_as_int64(),
                  )
                  thread.stack[a + 3] = @core.VInt(idx)
                  true
                }
              }
              @core.VNum(s) => {
                let limit_n = match @core.value_to_double(thread.stack[a + 1]) {
                  @core.ConvNum(l) => l
                  _ => for_error(st, "limit", thread.stack[a + 1])
                }
                let idx = match @core.value_to_double(thread.stack[a]) {
                  @core.ConvNum(v) => v
                  _ => for_error(st, "initial value", thread.stack[a])
                }
                let next = idx + s
                if s > 0.0 {
                  if next <= limit_n {
                    thread.stack[a] = @core.VNum(next)
                    thread.stack[a + 3] = @core.VNum(next)
                    true
                  } else {
                    false
                  }
                } else if limit_n <= next {
                  thread.stack[a] = @core.VNum(next)
                  thread.stack[a + 3] = @core.VNum(next)
                  true
                } else {
                  false
                }
              }
              _ => for_error(st, "step", step)
            }
            if cont {
              pc = pc + inst.c
            }
          }
          @core.OP_TFORCALL => {
            let a = base + inst.a
            let f = thread.stack[a]
            let s = thread.stack[a + 1]
            let ctl = thread.stack[a + 2]
            let want = inst.b
            // `L->top.p = ra + 4 + 3`: the iterator call's frame is placed past
            // the loop's own registers, and that is the live limit while it
            // runs.
            fr.top = a + 7
            // The iterator call is a frame, not a host call, so that a
            // `coroutine.yield` inside it suspends the loop itself.
            fr.pc = pc
            // Just past this frame's register window: stable across iterations
            // (so the loop reuses it) and never overlapping a live register,
            // unlike the running top, which multret calls move around.
            let slot = base + proto.maxstack
            thread.ensure_stack(slot + 3)
            thread.stack[slot] = f
            thread.stack[slot + 1] = s
            thread.stack[slot + 2] = ctl
            push_frame(st, thread, slot, 2, a + 4, want, @core.src_iterator, 0)
            let nf = thread.frames.length() - 1
            thread.frames[nf].call_line = @core.line_at(proto, pc - 1)
            if (thread.hook_mask & @core.HOOK_CALL) != 0 && !thread.hook_running {
              hook_call_event(st, thread, 2, false)
              fr = thread.frames[ci]
            }
            ci = thread.frames.length() - 1
            if ci < floor {
              return @core.RFinished([])
            }
            fr = thread.frames[ci]
            pc = fr.pc
            base = fr.base
          }
          @core.OP_TFORLOOP => {
            let a = base + inst.a
            let v = thread.stack[a + 4]
            if !v.is_nil() {
              thread.stack[a + 2] = v
              pc = pc + inst.c
            }
          }
          @core.OP_SETLIST => {
            let a = base + inst.a
            let tbl = match thread.stack[a] {
              @core.VTable(t) => t
              _ => @core.vm_error(st, "table expected")
            }
            // `c` is the number of array items already stored by previous
            // batches; this batch appends its `n` values after them.  With a
            // fixed count the reference raises the live limit to the whole
            // register window, since every one of them is an operand.
            let n = if inst.b == 0 { fr.top - (a + 1) } else { inst.b }
            if inst.b != 0 {
              fr.top = base + proto.maxstack
            }
            let start = inst.c
            let before = @core.table_bytes(tbl)
            let mut i = 1
            while i <= n {
              tbl.set_int((start + i).to_int64(), thread.stack[a + i])
              i = i + 1
            }
            charge_growth(st, tbl, before)
          }
          @core.OP_CLOSURE => {
            // `L->top.p = ra + 1` before the closure is allocated, so that a
            // collection it triggers sees the registers below it.
            fr.top = base + inst.a + 1
            st.memory_units = st.memory_units + 40
            let sub = proto.protos[inst.b]
            let upvals : Array[@core.LUpval] = []
            let mut i = 0
            while i < sub.upvals.length() {
              let d = sub.upvals[i]
              let pseudo = proto.code[pc]
              pc = pc + 1
              if d.in_stack {
                upvals.push(find_upvalue(thread, base + pseudo.b))
              } else {
                upvals.push(cl.upvals[pseudo.b])
              }
              i = i + 1
            }
            thread.stack[base + inst.a] = @core.VFunc({
              proto: sub,
              upvals,
              id: @core.next_object_id(),
              mark_epoch: 0,
            })
          }
          @core.OP_VARARG => {
            let va = fr.varargs
            let a = base + inst.a
            if inst.b == 0 {
              let n = va.length()
              thread.ensure_stack(a + n + 1)
              let mut i = 0
              while i < n {
                thread.stack[a + i] = va[i]
                i = i + 1
              }
              fr.top = a + n
            } else {
              let n = inst.b - 1
              let mut i = 0
              while i < n {
                thread.stack[a + i] = if i < va.length() {
                  va[i]
                } else {
                  @core.VNil
                }
                i = i + 1
              }
            }
          }
          @core.OP_CLOSE =>
            close_to_level(st, thread, fr, base + inst.a, "close")
          @core.OP_TBC => {
            let reg = base + inst.a
            let v = thread.stack[reg]
            if !v.is_nil() &&
              !(match v {
                @core.VBool(b) => !b
                _ => false
              }) {
              let h = metafield(st, v, "__close")
              // Only a *missing* handler is refused here, which is
              // `checkclosemth`; one that is there but cannot be called is
              // reported when it is called.
              if h.is_nil() {
                // The reference reports the declaration site, naming the local
                // the way `luaF_getlocalname` does.
                let name = match @core.local_name(proto, inst.a, pc - 1) {
                  Some(n) => n
                  None => "?"
                }
                @core.vm_error(
                  st,
                  "variable '" + name + "' got a non-closable value",
                )
              }
              fr.push_tbc(reg)
            }
          }
          _ => @core.vm_error(st, "invalid opcode " + inst.op.to_string())
        }
      }
    }
  } nobreak {
    @core.RFinished([])
  }
}

///|----------------------------------------------------------------
/// Instruction helpers

///|----------------------------------------------------------------

///|
pub fn[T] for_error(
  st : @core.LuaState,
  what : String,
  v : @core.Value,
) -> T raise @core.LuaRaised {
  let name = @core.type_error_name(st, v)
  let message = "bad 'for' " + what + " (number expected, got " + name + ")"
  @core.vm_error(st, message)
}
