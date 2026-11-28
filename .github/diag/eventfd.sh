#!/bin/bash
# Temporary diagnosis (not for merge): runs the [linux-net] eventfd_waker
# case in parallel loops, amd64 and arm64 guests on hcpu, with munmap loops
# beside them for load, and samples h9's stacks when a run stalls.
cd "$(dirname "$0")/../.."
end=$(( $(date +%s) + ${DIAG_SECS:-1200} ))
mkdir -p /tmp/d
loop() {
  local a=$1 k=$2 i=0
  while [ "$(date +%s)" -lt "$end" ] && [ ! -f /tmp/d/stop ]; do
    i=$((i+1))
    zig-out/bin/h9 --engine hcpu --arch $a --dir .local/linux/alpine-$a:#L --cwd zig-out/fixtures/linux/$a /mnt/term/cwd/net eventfd_waker > /tmp/d/out-$a-$k.txt 2>&1 &
    local pid=$! t=0 sampled=0
    while kill -0 $pid 2>/dev/null && [ $t -lt 600 ]; do
      sleep 0.1; t=$((t+1))
      if [ $t -eq 8 ] && [ "$(ls /tmp/d/sample-* 2>/dev/null | wc -l)" -lt 6 ] && kill -0 $pid 2>/dev/null; then
        sample $pid 1 -mayDie -file /tmp/d/sample-$a-$k-$i.txt >/dev/null 2>&1; sampled=1
      fi
    done
    kill -9 $pid 2>/dev/null
    wait $pid; rc=$?
    grep -q '^DIAG lost=0' /tmp/d/out-$a-$k.txt || rc=99
    echo "$a $k $i $t $(grep '^DIAG lost' /tmp/d/out-$a-$k.txt)" >> /tmp/d/times.txt
    if [ $rc -ne 0 ] || grep -q 'DIAG slow' /tmp/d/out-$a-$k.txt; then
      echo "=== $a loop $k run $i rc=$rc t=${t}ds"; cat /tmp/d/out-$a-$k.txt
      if [ $sampled = 1 ]; then echo "--- sample"; cat /tmp/d/sample-$a-$k-$i.txt; fi
    fi
    [ $sampled = 1 ] && [ $rc -eq 0 ] && ! grep -q 'DIAG slow' /tmp/d/out-$a-$k.txt && rm -f /tmp/d/sample-$a-$k-$i.txt
  done
}
load() {
  local a=$1
  while [ "$(date +%s)" -lt "$end" ] && [ ! -f /tmp/d/stop ]; do
    timeout 60 zig-out/bin/h9 --engine hcpu --arch $a --dir .local/linux/alpine-$a:#L --cwd zig-out/fixtures/linux/$a /mnt/term/cwd/threads munmap >/dev/null 2>&1
  done
}
for k in 1 2 3; do loop amd64 $k & done
for k in 1 2; do loop arm64 $k & done
[ "${DIAG_LOAD:-1}" = 1 ] && { load amd64 & load arm64 & }
wait
echo "runs: $(wc -l < /tmp/d/times.txt)"
for a in amd64 arm64; do
  echo "$a: runs $(grep -c "^$a " /tmp/d/times.txt), failed $(grep "^$a " /tmp/d/times.txt | grep -vc 'lost=0')"
  grep "^$a " /tmp/d/times.txt | awk '{print $4}' | sort -n | awk '{x[NR]=$1} END {print "  deciseconds p50", x[int(NR/2)], "p99", x[int(NR*0.99)], "max", x[NR]}'
done
grep -v 'lost=0' /tmp/d/times.txt | head -40
exit 0
