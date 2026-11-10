// Recursive Fibonacci: calls, returns, and the stack.
typedef unsigned int u32;

static u32 fib(u32 n) {
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

u32 compute(void) {
    volatile u32 n = 30;
    return fib(n);
}
