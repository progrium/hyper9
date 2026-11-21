# The sqlite3 shell, with a file database in /tmp.
# expect: 4950
sqlite3 /tmp/db 'create table t(x)'
seq 0 99 | sed 's/.*/insert into t values (&);/' | sqlite3 /tmp/db
sqlite3 /tmp/db 'select sum(x) from t'
