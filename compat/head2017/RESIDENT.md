# AX7020 Resident 1.202

This deployment uses the timing-accepted combined overlay (`37cf59e6…`). The runtime packs and synchronizes each complete Gate/Up layer once in an XRT BO. Each forward step sends four short prefix DMAs followed by direct reads from the layer BO at the four row offsets. As on Head, input TLAST can terminate a prefix transfer while the hardware retains the logical request until output TLAST. Slow-path weight staging remains independently selectable for controlled comparisons.

The test_gateup tool passed 8 real cases and 100 zero repeats with resident dispatch. In that matrix test the summed DMA time was 449.258 ms for 108 calls (4.16 ms/call) with the same worst relative L2, 2.97e-7. The added runtime required no RTL/clock changes.

## Board results

With 384 MiB CMA, 24 Gate/Up BOs occupy 149.625 MiB and all 22 Head tiles fit. Combined decode made 553 direct resident Gate/Up calls (zero fallback) and 24 full-vocabulary PL Head calls (zero CPU rows). Relative to the existing Gate/Up-enabled control on the same 24-token history, all 24 candidates matched and the maximum logits difference was 3.81e-6. Free generation text matched across all tested settings.

| Mode | 23-step decode after prompt (token/s) |
| --- | ---: |
| Prior 128 MiB staged Gate/Up + hybrid Head (two runs, pooled) | 0.860 |
| 384 MiB, staged Gate/Up + full PL Head | 0.917 |
| 384 MiB, resident Gate/Up + full PL Head, `--poll 0` | 1.153 / 1.219 (pooled 1.185) |
| 384 MiB, resident Gate/Up + full PL Head, `--poll 50` | **1.195 / 1.210 (pooled 1.202)** |

The selected mode is 31.1% faster than staged Gate/Up on the same memory profile and 39.9% faster than the earlier hybrid deployment. The decode measurement includes first-use Gate/Up preparation on the first decode step. It does not include prompt eval or loading. The cold diagnostic run took 5.95 s of Gate/Up preload and was deliberately excluded from throughput.

After rebooting with the persisted configuration, a separate 19-step fixed-history measurement excluding the first four decode steps gave **1.380 tok/s** (724.5 ms/token), with a matching greedy output on every step. The operator profiler, which synchronizes each node and is slower than the normal graph, found roughly 231 ms/token in Attention projections and 230 ms/token in Down (97 ms Q4_K and 133 ms Q6_K). The profiler reported 854 ms/token in total. See `build/head2017/fast/profile.log` for the full accounting.


## Reproduction and rollback

1. Reuse the accepted combined build in [DECODE.md](DECODE.md). Upload `build_resident.py` and `resident_gateup.inc` to a separate board directory and run `python3 build_resident.py`. It compiles one runtime object and relinks a copy of the accepted application without changing either prior binary.
2. Validate one boot with `boot_cma_once.py` (serial and SSH required) and check `CmaTotal: 393216 kB`. `restore_serial_ipv4.py` restores the temporary Ethernet alias if lost during reboot. Both use local environment credentials.
3. Run `sudo bash test_resident_board.sh VALIDATED_DECODE_LOG_DIR` in the board directory. The script validates resident and full-Head call counts, compares raw logits to the prior forced history and measures the polling candidates. Board evidence is `~/ax7020-resident2017/resident-logs.m63PqF/`. The [benchmark record](BOARD-RESULT.md) captures the verification and throughput.
4. `install_resident_boot.sh` persists the tested argument through an added `/boot/uEnv.txt`, with the original `/boot/boot.scr` unchanged. After reboot, `boot_cma_once.py --verify-installed` can check that Linux reserved the intended size. The board was verified to import the added file and reserve 384 MiB. To roll back, rename only the added `/boot/uEnv.txt` to `/boot/uEnv.resident.disabled` and reboot. Original v5 and combined hybrid programs remain available.
5. Start with `cd ~/ax7020-resident2017 && bash run_resident.sh`. This release uses the 7168-row partition and defaults to `--poll 50`.
