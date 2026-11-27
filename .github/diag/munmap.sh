#!/bin/bash
# Temporary diagnosis (not for merge): runs the [linux-threads] munmap case
# in 3 parallel loops per arch, as the shards load a runner, and samples
# the stacks of any run that's still going after 20 s.
cd "$(dirname "$0")/../.."
end=$(( $(date +%s) + ${DIAG_SECS:-900} ))
hangs=0
loop() {
  local a=$1 k=$2 i=0
  while [ "$(date +%s)" -lt "$end" ] && [ ! -f /tmp/diag-stop ]; do
    i=$((i+1))
    zig-out/bin/h9 --engine hcpu --arch $a --dir .local/linux/alpine-$a:#L --cwd zig-out/fixtures/linux/$a /mnt/term/cwd/threads munmap > /tmp/out-$a-$k.txt 2>&1 &
    local pid=$! t=0
    while kill -0 $pid 2>/dev/null && [ $t -lt 200 ]; do sleep 0.1; t=$((t+1)); done
    if kill -0 $pid 2>/dev/null; then
      echo "=== HUNG $a loop $k run $i pid $pid"
      sample $pid 3 -mayDie -file /tmp/sample-$a-$k-$i.txt >/dev/null 2>&1
      cat /tmp/sample-$a-$k-$i.txt
      sleep 5
      echo "=== second sample, 5 s later"
      sample $pid 2 -mayDie -file /tmp/sample2-$a-$k-$i.txt >/dev/null 2>&1
      cat /tmp/sample2-$a-$k-$i.txt
      kill -9 $pid
      touch /tmp/diag-hung
      [ "$(ls /tmp/sample-* | wc -l)" -ge 2 ] && touch /tmp/diag-stop
    else
      wait $pid; rc=$?
      [ $rc -ne 0 ] && { echo "=== FAIL $a loop $k run $i rc=$rc"; cat /tmp/out-$a-$k.txt; }
      echo "$a $k $i $t" >> /tmp/diag-times.txt
    fi
  done
}
for k in 1 2 3; do loop arm64 $k & done
for k in 1 2; do loop amd64 $k & done
wait
echo "runs: $(wc -l < /tmp/diag-times.txt)"
awk '{print $4}' /tmp/diag-times.txt | sort -n | awk '{a[NR]=$1} END {print "deciseconds p50", a[int(NR/2)], "p99", a[int(NR*0.99)], "max", a[NR]}'
[ -f /tmp/diag-hung ] && exit 1
exit 0
