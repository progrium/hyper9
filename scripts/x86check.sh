#!/bin/sh
# Checks h86's interpreter (T0) against the host CPU: random integer
# instructions run on the real CPU in 32-bit mode (tools/x86check/oracle.c)
# and on T0, which must agree on registers, defined flags, memory, and
# exceptions. Needs x86-64 Linux with 32-bit support.
#
# x87 and SSE cases start from random x87 stacks, control words, XMM
# registers, and MXCSRs, and compare the whole FXSAVE image.
#
#   scripts/x86check.sh [cases [seed [int|x87|sse]]]
set -eu
n=${1:-100000}
seed=${2:-1}
mode=${3:-int}
out=.zig-cache/x86check
mkdir -p "$out"
zig cc -target x86-linux-musl -O2 -fno-pie -no-pie tools/x86check/oracle.c -o "$out/oracle"
zig build-exe -lc --dep vcpu -Mroot=tools/x86check/x86check.zig -Mvcpu=src/vcpu.zig -femit-bin="$out/x86check"
"$out/x86check" gen "$n" "$seed" "$out/cases.bin" "$mode"
"$out/oracle" < "$out/cases.bin" > "$out/answers.bin"
"$out/x86check" cmp "$out/cases.bin" "$out/answers.bin"
