# Busybox's text tools in a pipeline: find, sed, awk, sort, and a
# heredoc into md5sum.
# expect: 3
# expect: 15
# expect: 0bee89b07a248e27c83fc3d5951213c1  -
mkdir -p /tmp/t/a/b && touch /tmp/t/a/x /tmp/t/a/b/y /tmp/t/z
find /tmp/t -type f | wc -l
seq 1 5 | awk '{s += $1} END {print s}'
md5sum <<END
abc
END
