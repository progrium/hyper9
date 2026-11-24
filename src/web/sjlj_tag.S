// The tag wasm exception handling throws for longjmp (-wasm-enable-sjlj).
// LLVM 22 (Zig 0.17) no longer defines it in the object that uses it and
// leaves it to the runtime, which wasi-libc's setjmp runtime (rt.c, which
// addKern builds) doesn't do in the version Zig ships, so it's here.
.globl __c_longjmp
.tagtype __c_longjmp i32
__c_longjmp:
