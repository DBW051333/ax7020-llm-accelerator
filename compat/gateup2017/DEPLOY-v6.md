# v6（Down 入 PL）板端部署步骤（连接恢复后执行）

前置：串口 COM13 恢复（USB 重新插入）或 SSH 可达；板端无加速器进程、锁空闲。
凭据走环境变量：`export AX7020_PASSWORD=... AX7020_SSH_FINGERPRINT=...`
（指纹可经串口 `cat /etc/ssh/ssh_host_ed25519_key.pub` 本地计算核对，boardctl.py 强制匹配。）

```bash
# 1) 串口恢复辅助地址（若 SSH 不通；板端 eth0 加 169.254.32.1/16）
powershell -ExecutionPolicy Bypass -File build/gateup2017/serial_addr.ps1

# 2) 上传产物（bit/HWH/accepted.json 已在 overlay/ 时跳过）
MSYS2_ARG_CONV_EXCL="*" python tools/boardctl.py --host 169.254.32.1 put build/gateup2017/software.tar.gz /home/xilinx/ax7020-gateup2017/software-v6.tar.gz
for f in gateup_quad_2017.bit gateup_quad_2017.hwh accepted.json; do
  MSYS2_ARG_CONV_EXCL="*" python tools/boardctl.py --host 169.254.32.1 put build/gateup2017/quad-2017-v6/$f /home/xilinx/ax7020-gateup2017/overlay/$f
done

# 3) 归档 v5 日志、解包、编译（约 20 分钟）
python tools/boardctl.py --host 169.254.32.1 run --command "cd /home/xilinx/ax7020-gateup2017 && rm -rf logs-v5 && mv logs logs-v5 && mkdir logs && tar -xmzf software-v6.tar.gz && bash build_board.sh" --timeout 2400 --log build/gateup2017/board-build-v6.log

# 4) 加载 v6 overlay（sudo，锁由脚本持有）
python tools/boardctl.py --host 169.254.32.1 run --sudo --command "cd /home/xilinx/ax7020-gateup2017 && env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 load_overlay.py" --timeout 120

# 5) 新二进制 CPU 诊断基线（与固定参考逐字节比对）
python tools/boardctl.py --host 169.254.32.1 run --command "cd /home/xilinx/ax7020-gateup2017 && env XILINX_XRT=/usr BLITE_ENABLE=0 BLITE_Q58=0 BLITE_GATEUP=0 BLITE_DIAG_PREFIX=\"\$PWD/logs/cpu\" timeout 300 bin/llama-cli-gateup -m models/qwen2.5-0.5b-instruct-q4_k_m.gguf -c 256 -b 64 -ub 64 -t 2 -p 'Write a short story about a robot.' --temp 0 -s 1234 --no-warmup --no-display-prompt -n 24 >logs/cpu.stdout 2>logs/cpu.stderr; cmp logs/cpu.stdout /home/xilinx/ax7020-validation2017/logs/model-cpu.stdout && echo CPU-MATCHES-PINNED-REFERENCE; awk '{print \$2}' logs/cpu.tokens >logs/cpu-force.tokens" --timeout 360

# 6) 五模式测试组（829 次调用预期：553 融合 + 276 Down；276 条 DOWN-VERIFY）
python tools/boardctl.py --host 169.254.32.1 run --sudo --command "cd /home/xilinx/ax7020-gateup2017 && env XILINX_XRT=/usr bash test_model.sh" --timeout 2700 --log build/gateup2017/board-test-model-v6.log

# 7) 收证据
python tools/boardctl.py --host 169.254.32.1 run --command "cd /home/xilinx/ax7020-gateup2017 && cp overlay/loaded.json logs-v6-loaded.json; sha256sum bin/llama-cli-gateup overlay/gateup_quad_2017.bit; tar -czf /tmp/logs-v6.tar.gz logs logs-v6-loaded.json" --timeout 60
MSYS2_ARG_CONV_EXCL="*" python tools/boardctl.py --host 169.254.32.1 get /tmp/logs-v6.tar.gz build/gateup2017/logs-v6.tar.gz
mkdir -p docs/fusion-speedup2017 && tar -xzf build/gateup2017/logs-v6.tar.gz -C docs/fusion-speedup2017/ --transform 's/^logs\//' 2>/dev/null || true
```

判读：`GATEUP-NUMERIC-AND-REPEAT-PASS`（553 融合 + 276 Down 校验、重复逐字节一致）+
`GATEUP-TEXT-PARITY-FAIL`（预期内，既有未解决问题）。decode 时间与 tps 从各模式
`eval time` 行提取；对比 v5（fused 30797.75ms/0.7468 tps、CPU 42331.32ms/0.5433）。
