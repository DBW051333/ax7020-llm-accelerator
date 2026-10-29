# 2017.4 产物加载、DMA 与模型测试

本机 RTL 重建入口见 README；这里描述独立的板端验证。用户已授权本轮加载和测试。当前部署目录为 `/home/xilinx/ax7020-validation2017`；不覆盖系统运行库、原模型或其他项目。

本轮已执行完成。加载、DMA、真实矩阵和逐层数值验证通过，CPU/PL生成文本一致性失败；完整24-token逐层检查也通过，但PL文本稳定地与CPU不同。失败日志已保留，比较脚本仍按原条件返回非零；详见 `docs/board-validation2017/RESULT.md`。不要将下面的复现步骤理解为全部验收已通过。

## 部署来源

在主机执行 `python tools/prepare_validation_bundle.py`，会校验下载的固定 llama.cpp 基准包、应用原集成补丁并生成 `build/board-validation2017/` 下的两个部署包和 manifest。上游 revision 为 `dafae66cc242eb766797194d3c85c5e502625623`；压缩包 SHA256 已固定，不使用浮动最新版。

SSH/SFTP 工具 `tools/boardctl.py` 从进程环境读取 `AX7020_PASSWORD`、`AX7020_SSH_FINGERPRINT`，主机地址由 `--host` 指定。不要把凭据写入仓库。首次主机指纹应由串口等可信渠道核对，不能自动接受未知身份。

部署到独立目录后，以普通用户解包（或显式设置该目录所有者），使用 `tar -xmzf` 避免镜像旧系统时间造成未来文件时间和 make 时钟偏差。模型独立传输，加载前核对 SHA256。

## 加载与分配

在板端通过 SSH 执行：

```bash
cd /home/xilinx
sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 \
  ax7020-validation2017/load_overlay.py \
  ax7020-validation2017/overlay/blite_quad_2017.bit
```

同名 `.hwh` 必须与 bit 放在一起。脚本先验证已验收 bit 的 SHA256、解析四路控制地址，再通过 PYNQ 下载，使用设备树中的 33.333333MHz PS 参考时钟修正 FCLK 换算。`--inspect-only` 只解析元数据。本流程不使用 raw JTAG，也不将 HDF 改后缀当 XSA。

默认 `/usr/bin/python3` 的依赖不完整，应使用上述 PYNQ 虚拟环境。当前实现需要先下载 overlay 注册 PS DDR 内存，才能通过 `pynq.allocate` 分配；未加载时的 “Overlay is not downloaded” 不等于 CMA 已耗尽。

本轮已验证 1MiB/32MiB 分配与释放。`CmaFree` 较低仍可能通过内存迁移满足分配，应以实际分配结果判断；不要直接全局 reset/free 其他进程的缓冲区。

## DMA 校验

先运行小向量，再逐步扩大。所有驱动在访问硬件期间使用 `/tmp/blite-perf.lock`；加载前仍需核查其他非合作进程与实际设备占用。

```bash
cd /home/xilinx/ax7020-validation2017
sudo env XILINX_XRT=/usr timeout 30 ./bin/perf_parallel \
  --dir vectors --data orig --lanes 1 --nrows 8 --nsb 4 --rounds 1 --warmup 0
sudo env XILINX_XRT=/usr timeout 30 ./bin/perf_parallel \
  --dir vectors --data perf --lanes 4 --sweep --rounds 100
sudo env XILINX_XRT=/usr timeout 30 ./bin/perf_parallel \
  --dir vectors --data perf --lanes 4 --repeat 16 --rounds 1000
```

本轮额外完成 1/2/4 路各 12 配置 ×100 轮；每个配置先交替输入 6 轮零/正常激活以排除旧结果。四路 512×8192、1000 轮 bit-exact 通过，DMA 窗口 3.4617 GMAC/s，含同步与校验 3.2183 GMAC/s。这是合成矩阵性能，不是模型生成速度。该测量时没有并行运行模型编译。

真实权重测试使用当前本地 GGUF 的 `blk.3.ffn_down.weight`，而不是历史模型 fixture。原 `test_real_matvec.c` 的 896×4864、5 组激活全部通过，启用正常运行时缩放时最差 relative L2 为 1.86795252e-7。关闭缩放仅作为诊断，其较大误差不算正常推理路径的通过条件。

## 原生构建与模型对照

```bash
cd /home/xilinx/ax7020-validation2017
bash build_board.sh
sudo env XILINX_XRT=/usr bash test_model.sh
```

本轮 `test_model.sh` 在文本比较处按设计返回1。保留原失败日志后，补充完整长度的逐层验证：

```bash
sudo env XILINX_XRT=/usr bash -c 'set -o pipefail; bash verify_model24.sh 2>&1 | tee logs/verify24-console.log'
```

这一步会验证24-token运行中的每次卸载，并检查开启数值复算时的PL文本是否与原PL文本相同；不把它当作CPU文本一致性通过。运行结果汇总器会分别报告局部数值检查和生成文本检查。

`build_board.sh` 使用板端 GCC/G++11.2、CMake3.22，以 Cortex-A9/NEON-VFPv3 参数构建，关闭 OpenMP 与 llamafile。CPU/PL 使用同一个本机原生二进制和系统 glibc，无需替换板端库或使用历史交叉工具链的私有 loader。源码 tar 包不含 Git 数据库，CMake 的 build-info 提示不影响编译；版本依据是 manifest 中的固定 revision 和补丁/源码哈希。

`test_model.sh` 依次执行：

1. 模型 SHA256 校验。
2. `BLITE_VERIFY=1` 的 4-token 验证，对每次 Q4_K 卸载使用同输入的 ggml CPU 点积检查 relative L2≤1e-4；失败立即停止，不静默回退。
3. 关闭数值复算/剖析，以相同程序、模型、prompt、seed、双线程、ctx256/batch64/ubatch64、贪心采样，串行运行 CPU、PL、CPU 复测，各请求 24 token。
4. 要求 PL 运行的实际硬件调用计数大于 0，并对完整生成 stdout 做字节比较。计时以 decode eval 记录为准，单独保留 prompt eval 和初始化日志。

当前模型有 290 个张量，和历史交付模型不同。旧 loader 的 Qwen2 路径支持缺失独立 output.weight 时复用 token embedding，但仍须以本轮实际加载/运行结果为准。不能直接沿用历史的 token/s 或输出文本。

日志位于板端 `logs/`；取回到主机 `build/board-validation2017/` 后，运行 `python compat/vivado2017/collect_board_results.py` 汇总。模型阶段是否完成及实测结果，以 `docs/PROJECT_CONTEXT.md` 最新交接和本轮结果文件为准；DMA 通过不能替代模型通过。
