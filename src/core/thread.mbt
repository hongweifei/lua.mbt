// Coroutines: frames, stacks and run status.

///|
pub const THREAD_OK : Int = 0

///|
/// Not started yet (created by `coroutine.create`).
pub const THREAD_SUSPENDED : Int = 1

///|
/// Currently executing.
pub const THREAD_RUNNING : Int = 2

///|
/// Resumed another coroutine and waiting for it.
pub const THREAD_NORMAL : Int = 3

///|
/// Finished normally or with an error.
pub const THREAD_DEAD : Int = 4

///|
/// A call frame.  All of the mutable state of a running function lives here, so
/// that a coroutine can be suspended and resumed simply by stopping and
/// restarting the interpreter loop.
pub(all) struct Frame {
  mut pc : Int
  func_slot : Int
  base : Int
  ret_slot : Int
  nres_wanted : Int
  mut top : Int
  closure : LClosure?
  builtin : LBuiltin?
  varargs : Array[Value]
  /// The protections this frame carries, innermost first.  A call such as
  /// `xpcall(pcall, f, g)` nests two of them on the frame of `g`.
  mut prots : Array[Cont]
  mut tbc : Array[Int]
  mut tailcalls : Int
  mut call_line : Int
  patched_builtin : Int
  /// True for the frame running a debug hook function, so that `debug.getinfo`
  /// reports `namewhat == "hook"` for it.
  mut hook_frame : Bool
  /// Whether per-instruction debug hooks run for this frame (true when the
  /// hook mask had line or count events when the frame was pushed).
  mut trap : Bool
  /// The metamethod name when the frame was entered through a metamethod
  /// call (empty otherwise), used by `debug.getinfo` namewhat.
  mut mm_name : String
  /// The transfer information a call or return hook recorded for this frame,
  /// which `debug.getinfo` field 'r' reports.  It belongs to the frame, as the
  /// reference's `ci->u2.transferinfo` does: a hook asking about a level other
  /// than the one it fired on has to see that level's own values, and the
  /// reference leaves them in place until the frame is popped.
  mut ftransfer : Int
  mut ntransfer : Int
  /// True for the frame a protected call itself stands for.  Such a frame runs
  /// no host function: the protected function is its child, and the child's
  /// values are already where the caller of `pcall` asked for them, so all that
  /// is left when the child is finished is to drop this level.
  protect_frame : Bool
  /// The message handler this frame's protection displaced, put back when the
  /// protection is dropped, so the enclosing `xpcall` is reached again.
  mut saved_errfunc : Value
  /// The instruction whose metamethod call a yield interrupted, or -1.  On
  /// resume this frame finishes that instruction instead of running it again:
  /// the call's result is already in the stack, so the instruction only has to
  /// take it.  This is the reference's `luaV_finishOp`.
  mut pending_finish : Int
  /// Where that result was left, as a stack slot.
  mut pending_slot : Int
  /// For a suspended concatenation: how many operands the fold had left, which
  /// is what tells the resume where in the operand range it stopped.
  mut pending_top : Int
  /// The frames a failed protected call still has to close, innermost last, on
  /// the marker of that call.  It shrinks as their variables are closed, so it
  /// is also the progress: a `__close` that yields leaves the rest here for the
  /// pass that reaches the marker again.
  mut pending_closes : Array[Frame]?
  /// The error the closing carries from one handler to the next.
  mut pending_err : Value
  /// The frame allowance to put back once those closes are done, since the
  /// closing may be suspended in the middle of it.
  mut pending_room : Int
  /// For a builtin whose call was suspended in the Lua it called back into:
  /// where the results of that call stand, and how many.  A resume finishes
  /// this frame with them instead of running the builtin again, which is what
  /// `pairs` needs -- it has nothing left to do but return them.
  mut pending_result : (Int, Int)?
}

///|
/// The continuation a frame performs when the call it represents finishes.
/// This is what makes `pcall` resumable: instead of a native function waiting on
/// the MoonBit stack, the protection is recorded on the frame and applied when
/// the call returns -- normally or with an error.
pub(all) enum Cont {
  ContPCall
  ContXPCall(Value)
}

///|
pub fn Frame::is_lua(self : Frame) -> Bool {
  match self.closure {
    Some(_) => true
    None => false
  }
}

///|
/// A coroutine.
pub(all) struct LThread {
  stack : Array[Value]
  frames : Array[Frame]
  mut open_upvals : Array[LUpval]
  meta : LTable?
  mut status : Int
  mut ny : Int
  /// Nested protected calls, which the reference counts as C levels: a chain of
  /// `pcall` calls stops with "C stack overflow" long before the Lua stack does.
  mut ccalls : Int
  mut func : Value
  mut started : Bool
  mut dead_error : Value
  /// The values a `resume` passed in, waiting for the `coroutine.yield` frame
  /// that suspended the thread to be finished with them.  Nothing is pending
  /// while the thread runs.
  mut resume_vals : Array[Value]?
  /// Debug hook state, as manipulated by `debug.sethook`.
  mut hook_fn : Value
  mut hook_mask : Int
  mut hook_count : Int
  mut hook_base_count : Int
  /// True while the hook function itself is running, so that it does not
  /// trigger itself again.
  mut hook_running : Bool
  /// The pc of the last executed instruction (of the last active proto),
  /// used by the line hook to detect loops and new lines.
  mut hook_old_pc : Int
  /// The metamethod name of a call that is being dispatched through
  /// `call_metamethod`, consumed by the next pushed frame.
  mut mm_pending : String
  /// The message handler of the innermost active `xpcall`, or nil.  The
  /// reference keeps this on the state rather than in the frame it protects,
  /// because the handler has to run where the error is *raised*, before any
  /// frame leaves the chain; a protected call without a handler clears it for
  /// as long as it lasts.
  mut errfunc : Value
  /// True while the message handler itself runs, so an error it raises is not
  /// handed to it again at that point: the retries are counted by
  /// `message_handler_result` instead of by the C stack.
  mut in_errfunc : Bool
  /// Set where an error is *created*, and taken by the first recovery that
  /// sees it.  Only a created error reaches the message handler: an error that
  /// is put back in flight while the stack unwinds (by a `__close` chain, or
  /// by a protected call reporting to its caller) has already been reported,
  /// and the reference reports each error exactly once, from `luaG_errormsg`.
  mut fresh_error : Bool
  id : Int
  /// The collection cycle that last reached this thread (see `LTable`).
  mut mark_epoch : Int
}

///|
/// Debug hook event masks, matching the reference implementation.
pub const HOOK_CALL : Int = 1

///|
pub const HOOK_RETURN : Int = 2

///|
pub const HOOK_LINE : Int = 4

///|
pub const HOOK_COUNT : Int = 8

///|
/// Upper bound for the count-hook period (2^24 - 1).
pub const HOOK_COUNT_MAX : Int = 16777215

///|
/// Why the interpreter loop stopped.
pub(all) enum RunStatus {
  /// The frame at the bottom of this run returned these values.
  RFinished(Array[Value])
  /// The running coroutine yielded.
  RYield(Array[Value])
}

///|
/// Maximum number of Lua frames on one thread.  The interpreter loop is
/// iterative, so this is only bounded by memory.
pub const MAX_LUA_FRAMES : Int = 200000

///|
/// Maximum nesting of calls that re-enter the interpreter from the host.  Each
/// of those consumes host stack, so the limit is much lower.  This is the
/// reference's own shape (`LUAI_MAXCCALLS`, which it also counts in levels);
/// what actually stops the recursion is `MIN_HOST_STACK` below, since what one
/// level costs is a property of the generated code rather than of the language.
pub const MAX_NATIVE_DEPTH : Int = 190

///|
/// How much host stack has to remain below a call that re-enters the
/// interpreter, in bytes.  The check that uses it is in `call_value`, and it is
/// what keeps a program that recurses through host callbacks (`string.gsub`
/// with a replacement function, a `__index` that calls back) from running the
/// real stack out: the reference's fixed count of C levels assumes a level
/// costs a few hundred bytes, which is true of C code and not of the code this
/// backend produces.  The margin is what the unwinding of that recursion needs
/// -- the message handler, the tracebacks and the `__close` runs all happen
/// while the deep frames are still standing.
pub const MIN_HOST_STACK : Int = 256 * 1024

///|
/// `LUAI_MAXCCALLS` in the reference implementation.
pub const MAX_CCALLS : Int = 200

///|
/// How deep past the limit a call may get while an overflow is still being
/// handled, before the reference gives up on error handling altogether.
pub const CCALLS_LIMIT_LATE : Int = MAX_CCALLS / 10 * 11
