# The workloads' pure-Python benchmark: integer and float loops, calls,
# dicts, strings, and sorting, with a deterministic digest of the results.
import hashlib


def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)


def nbody(steps):
    # Two bodies, a simple Euler step: float arithmetic in the loop.
    x = [0.0, 1.0]
    v = [0.0, 0.5]
    m = [1.0, 0.001]
    dt = 0.001
    for _ in range(steps):
        dx = x[1] - x[0]
        r3 = abs(dx) ** 3 + 1e-9
        f = m[0] * m[1] / r3 * dx
        v[0] += f / m[0] * dt
        v[1] -= f / m[1] * dt
        x[0] += v[0] * dt
        x[1] += v[1] * dt
    return x[0] + x[1]


def words(n):
    d = {}
    for i in range(n):
        w = "w%d" % (i * 7919 % 1000)
        d[w] = d.get(w, 0) + i
    return sorted(d.items(), key=lambda kv: (-kv[1], kv[0]))[:5]


def sieve(n):
    s = bytearray([1]) * (n + 1)
    s[0] = s[1] = 0
    for i in range(2, int(n ** 0.5) + 1):
        if s[i]:
            s[i * i :: i] = bytearray(len(s[i * i :: i]))
    return sum(s)


out = [fib(25), "%.9f" % nbody(200000), words(200000), sieve(2000000)]
lst = [(i * 2654435761) % 1000003 for i in range(300000)]
lst.sort()
out.append(lst[1000])
out.append(" ".join(sorted("the quick brown fox jumps over the lazy dog".split())))
for o in out:
    print(o)
print(hashlib.sha256(repr(out).encode()).hexdigest())
