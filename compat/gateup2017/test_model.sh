#!/bin/bash
set -euo pipefail
cd /home/xilinx/ax7020-gateup2017
export XILINX_XRT=/usr BLITE_ENABLE=0 BLITE_Q58=0 BLITE_PROFILE=0
common=(-m models/qwen2.5-0.5b-instruct-q4_k_m.gguf -c 256 -b 64 -ub 64 -t 2
        -p 'Write a short story about a robot.' --temp 0 -s 1234 --no-warmup --no-display-prompt -n 24)
for mode in forced-verify fused fused-repeat cpu-repeat cpu-perf; do
 test ! -e "logs/$mode.stdout"
 enabled=1;verify=0;extra=()
 if [ "$mode" = cpu-repeat ] || [ "$mode" = cpu-perf ];then enabled=0;fi
 if [ "$mode" = forced-verify ] || [ "$mode" = cpu-repeat ];then
  extra+=(BLITE_DIAG_PREFIX="$PWD/logs/$mode")
 fi
 if [ "$mode" = forced-verify ];then
  verify=1;extra+=(BLITE_DIAG_FORCE="$PWD/logs/cpu-force.tokens")
 fi
 env BLITE_GATEUP="$enabled" BLITE_GATEUP_VERIFY="$verify" \
  "${extra[@]}" timeout 360 bin/llama-cli-gateup "${common[@]}" \
  >"logs/$mode.stdout" 2>"logs/$mode.stderr"
 grep 'GATEUP-STATS\|eval time' "logs/$mode.stderr"
 # 23 decode steps *24 layers, plus the final prefill layer compacted to one column.
 if [ "$enabled" = 1 ];then grep -Eq 'GATEUP-STATS calls=553 ' "logs/$mode.stderr";fi
 echo "GATEUP-MODE-DONE $mode"
done
test "$(grep -c GATEUP-VERIFY logs/forced-verify.stderr)" -eq 553
cmp logs/cpu.logits logs/cpu-repeat.logits
cmp logs/cpu.stdout logs/cpu-perf.stdout
cmp logs/fused.stdout logs/fused-repeat.stdout
echo GATEUP-NUMERIC-AND-REPEAT-PASS
if cmp -s logs/cpu.stdout logs/fused.stdout;then echo GATEUP-TEXT-PARITY-PASS
else echo GATEUP-TEXT-PARITY-FAIL;fi
# Text parity is reported separately; never label this as full model acceptance.
