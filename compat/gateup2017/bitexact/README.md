# Bit-exact comparison against the derived (v4) engine

`tb_dump.sv` replays `build/gateup2017/sim/axis-input.hex` through one engine
and dumps every output beat (value + TLAST) to a compile-time `-dDUMP_FILE=`
file. Compile it once against the derived engine (set `GATEUP_AXIS_SOURCE`
fallback by temporarily moving `compat/gateup2017/rtl/gateup_axis.sv` aside,
or use a preserved copy such as `build/gateup2017/rtl-v4ref/`) and once
against the line-rate engine, then diff the two dumps. The driver applies
randomized output backpressure and source pauses, so handshake timing
differences cannot hide; a clean diff proves the arithmetic contract is
bit-identical. Reference result: 68 rows identical (2026-10-30).
