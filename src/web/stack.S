# The C and Zig shadow stack pointer, which each coroutine has its own
# value of (src/web/coro.c). There's no builtin to read or set a wasm
# global from C. design/browser-host.md.

	.globaltype __stack_pointer, i32

	.globl h9_get_sp
	.type h9_get_sp,@function
h9_get_sp:
	.functype h9_get_sp () -> (i32)
	global.get __stack_pointer
	end_function

	.globl h9_set_sp
	.type h9_set_sp,@function
h9_set_sp:
	.functype h9_set_sp (i32) -> ()
	local.get 0
	global.set __stack_pointer
	end_function
