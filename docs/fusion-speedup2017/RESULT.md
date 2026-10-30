# 融合引擎线速化 + 打包流水化结果

日期：2026-10-30（Asia/Shanghai）。执行者：ZCode（2026-10-30 会话）。**四路 Gate/Up+SiLU/乘法融合实验的吞吐优化（build tag `quad-2017-v5`）已完成仿真、Vivado 2017.4 时序验收与板端测试。** 同协议短序列生成速率从 v4 融合版的 0.667 token/s 提高到 **0.747 token/s（+11.9%）**，相对 CPU 为 **+37.5%**。553 次调用同输入 CPU 参考数值检查全部通过且与 v4 逐位同源；CPU/PL 生成文本一致性仍失败（本方案不改变数值契约，属已知未解决问题），模型质量等价未验证。交付基线（四实例 B-Lite）未动。

## 瓶颈定位（本轮验证）

对 v4 融合版实测统计拆解（`GATEUP-STATS`，553 次调用）：

- 后端合计 14285ms（25.8ms/调用）= DMA 窗口 6149ms + CPU 侧 8136ms。
- 引擎侧：`gateup_axis` 每子块 15 拍（WLOAD 3 + XREAD 1 + 每组 3 拍 ×4），其中 `q58_dot32` 的单缓冲乘积级使流每 2 拍才收 1 拍；理论线速摄取约 4 拍/子块。
- CPU 侧：每调用从缓存向 TX 缓冲 memcpy 约 6.5MB 并做 cache flush，且"全部打包→统一启动 DMA"完全串行。

## 方案与实现

1. **引擎线速化**（`compat/gateup2017/rtl/gateup_axis.sv` 全量重写，替代 `prepare.py` 的字符串派生；`q58_dot32.sv` 握手改造）：
   - dot32 允许"消费与重填同沿发生"，流每拍收 1 拍；结果未消费时才反压。
   - 权重乒乓缓冲：流可领先计算两个子块；稳态 Q5 每子块 4 拍（Q8 为 5 拍）。
   - 激活读管线领先发射指针一拍；**单 BRAM 读口**（fire/prime 两个互斥源复用同一地址，否则 1024×64 激活存储被降级为 LUTRAM，LUT 多耗约 17k——首版构建实测过该问题）。
   - **至多一个在途 dot 结果**（`res_pending`）：属性（dw/dx/first/last）在第 4 拍锁存、scaler 消费时清除，杜绝 v4 型串行化被破坏后的属性错配；非行尾时消费与下一块首拍同拍，无代价。
   - **权重字预算**（rows×blocks×相位×每块字数）在 FLOW 中耗尽即关断接收，防止下一包 header 被当权重字吃掉（包边界保护，v4 靠状态机天然获得）。
   - 算术契约不变：整数点积、FP16 尺度、112 位块序累加、末端单次 FP32 RNE。
2. **runtime 打包流水化**（`compat/gateup2017/board/gateup_runtime.c`）：S2MM 全部先挂接收，随后按 lane"打包→flush→启动 MM2S"流水执行，lane N 的 memcpy 与 lane N-1 的 DMA 传输重叠；激活有限性检查前置到派发循环之前。`dma_ms` 统计口径相应变化（窗口从首个 kick 起算，含被重叠的打包时间）。

## 验收

### 仿真（本轮验证，Vivado 2017.4 XSim）

- `FP-MUL-PASS 1600`、`SILU-MUL-PASS 1870`、`GATEUP-AXIS-PASS rows=68 max_abs=2.38419e-06 relative_L2=4.24126e-08`——与 v4 记录值完全一致（`GATEUP-VERIFIED`）。
- **新旧引擎位级对拍**：同一向量集（`vectors.py` 固定种子，含 K32/64/896/8192、零输入、随机停顿、输出反压）下，v4 引擎与新引擎 68 行输出值与 TLAST **逐位一致**（`build/gateup2017/bitexact/{old,new}/*.txt`，驱动含随机反压）。

### 硬件（本轮验证）

| 项 | v5 实测 |
| --- | --- |
| 64 项网表检查 / 33 项 HWH 检查 | 通过 |
| 时钟 | 83.333MHz（12ns 约束不变），板端读回 83.333332MHz |
| WNS / WHS | **+0.420ns / +0.048ns** |
| LUT / FF | 25742（48.39%）/ 17622（16.56%） |
| DSP / BRAM | 24 / 84（60.00%）——BRAM 与 v4 持平 |
| DRC | 无 Error/Critical Warning |
| bit SHA256 | `91bbc86575cc0e631bd11f91d4f93df22fdd175bbd5259e537663913c1671cf0` |
| HWH SHA256 | `a1d030108eee1121a484bb3102509022488a5cc0e24201b007fcd025b132f4a9` |

资源余量：LUT 48%、BRAM 60%、DSP 11%——在 v4 基础上仅增加约 2.2k LUT 流水/缓冲逻辑。

### 板端（本轮实测，2026-10-30）

- 新程序 `bin/llama-cli-gateup` SHA256 `574fb6ee30fe481ea72a78658caf089b00510ad374358533309d22cedc20a916`（板端 GCC 11.2 原生编译，源码编译后已恢复）。原 B-Lite 程序保持 `98dc5451…` 不变。
- CPU 诊断基线（新二进制、纯 CPU）与 `/home/xilinx/ax7020-validation2017/logs/model-cpu.stdout` 固定参考**逐字节一致**。
- 553 次融合调用（552 decode + 1 prefill 末层单列）`BLITE_GATEUP_VERIFY=1` 同输入 CPU 参考检查全部通过；**最差 relative L2 = 9.79996804e-07，与 v4 完全相同**（数值逐位同源的板上旁证）。
- 重复性：CPU 两次 logits 逐位一致；融合两次自由文本逐字节一致。
- 同 prompt/模型/参数（ctx256/b64/ub64/t2、temp0/seed1234、no-warmup，24 token/23 decode）：

| 路径 | decode 时间 | tps |
| --- | ---: | ---: |
| CPU（新二进制） | 42331.32 ms | 0.5433 |
| CPU 复测 | 42521.83 ms | 0.5409 |
| **融合 v5** | **30797.75 ms** | **0.7468** |
| 融合 v5 复测 | 31026.16 ms | 0.7413 |

- 相对 CPU **+37.5%**（复测口径 +37.1%）；相对 v4 融合版（34465.72/34491.57ms）**+11.9%**。
- `GATEUP-STATS`（fused 首轮）：calls=553、MACs=4820107264、backend_ms=11108.701（v4：14285，−22%）、dma_ms=9040.603（口径含重叠打包）、pack_ms=1725.596（缓存未命中，即 24 层首次打包）、cache=149.625MiB。
- 文本一致性：**失败（GATEUP-TEXT-PARITY-FAIL）**——v5 引擎与 v4 数值逐位一致，该限制原样保留；速度提升不得表述为保持生成质量的加速。

## 限制与未验证项

- 文本等价与模型质量未解决（与 `docs/logits-diagnosis2017/RESULT.md`、`docs/gateup2017/RESULT.md` 的结论一致）；未评估困惑度/任务质量。
- 剩余瓶颈已转移：backend 20.1ms/调用中 CPU 侧打包+flush 约占 14ms（6.5MB/调用 memcpy，流水化后受 4 lane 串行下限约束）。后续候选：NEON 打包、减小 flush 范围/合并传输、引擎进一步加宽（16 元素/拍需 scaler 管线化）。
- 板端时钟仍为镜像旧日期；本轮报告日期以客户端 Asia/Shanghai 为准。未修改 SD 启动配置、系统库、持久网络（板端 169.254.32.1/16 为本次会话临时辅助地址，重启即失效；另有既有 eth0:1 192.168.2.99/24 非本轮所加）。

## 证据与产物

- 主机：`build/gateup2017/quad-2017-v5/`（bit/HWH/HDF/时序/资源/审计），`build/gateup2017/bitexact/`（对拍），`build/gateup2017/logs-v5.tar.gz` 与本目录（板端日志）。`build/gateup2017/rtl-v4ref/` 保存 v4 引擎基准。
- 板端：`/home/xilinx/ax7020-gateup2017`（v5 overlay 已加载，logs-v4/overlay-v4 归档保留，原始 v4 证据未覆盖）。
- 复现入口：`compat/gateup2017/README.md`（构建 tag `quad-2017-v5`）；手动 `cd /home/xilinx/ax7020-gateup2017 && bash run.sh`（先核对加载匹配产物）。
- 本轮过程性脚本（串口探测、mref 探针、dump TB）在 `build/gateup2017/`，未纳入交付面。
