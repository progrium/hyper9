# Python's C modules: json, sqlite3, hashlib, zlib, and re.
# expect: ok
python3 - <<'END'
import hashlib, json, re, sqlite3, zlib
db = sqlite3.connect(":memory:")
db.execute("create table t(x)")
db.executemany("insert into t values (?)", [(i,) for i in range(10)])
assert db.execute("select sum(x) from t").fetchone()[0] == 45
assert json.loads(json.dumps({"a": [1, 2]})) == {"a": [1, 2]}
assert hashlib.sha256(b"abc").hexdigest().startswith("ba7816bf")
assert zlib.decompress(zlib.compress(b"x" * 1000)) == b"x" * 1000
assert re.sub(r"(\d+)", r"<\1>", "a1b22") == "a<1>b<22>"
print("ok")
END
