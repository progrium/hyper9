# Python threads, which need clone with CLONE_VM and futexes.
# expect: 8 4950
python3 - <<'END'
import threading
out = []
lock = threading.Lock()
def work(i):
    with lock:
        out.append(sum(range(100)) if i == 0 else 0)
ts = [threading.Thread(target=work, args=(i,)) for i in range(8)]
for t in ts: t.start()
for t in ts: t.join()
print(len(out), sum(out))
END
