# tar with gzip and xz, both ways.
# expect: n
# expect: dea9193b768319cbb4ff1a137ac03113  -
cd /tmp && seq 1 100000 >n
tar czf n.tgz n && tar tzf n.tgz
xz -k n && xz -dc n.xz | md5sum
