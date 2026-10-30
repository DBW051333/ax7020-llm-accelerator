# Vivado 2017.4 四实例 RTL 重建

本目录将交付的四实例 B-Lite 主线适配到 Vivado **2017.4**。原交付快照保持不变，适配版产物与原 Vivado 2025.2 产物分开管理。其他 2017.x 小版本尚未验证。

2026-10-28 已完成本机从 RTL 到 bitstream/HWH/HDF 的重建：最终 WNS **+0.374ns**、WHS **+0.009ns**，全部用户时序约束满足。随后加载、DMA和逐层数值检查已通过，但当前模型的 CPU/PL 生成文本一致性失败。分别见[硬件重建报告](../../docs/vivado2017-rebuild/RESULT.md)与[板端测试报告](../../docs/board-validation2017/RESULT.md)。

## 入口

在仓库根目录的 PowerShell 中执行（Python 3.9+）：

```powershell
.\compat\vivado2017\rebuild.ps1
```

默认工具路径为 `D:\Xilinx\Vivado\2017.4\bin`，可通过 `-VivadoBin` 指定。需要安装 Zynq-7000 器件支持和可用许可证。`-Stage bd` 只创建 Block Design，`-Stage impl` 继续已有工程，默认 `all` 完成整个流程；已有工程时默认继续实现。不要在相同目录同时运行多个构建。

流程依次：校验/恢复原快照 → 生成兼容 RTL → XSim 校验 → 创建四实例工程 → 综合/布局/布线/bitstream → setup/hold 检查 → 导出。失败会停止，不自动删除失败工程或放宽时钟约束。已完成项目再次实现时，如 Vivado 要求 reset run，应先检查需要重跑的原因并保留已有结果。

## 路径与源码管理

- `source/`：原分卷快照，保持不变。
- `tools/restore_source.py`：校验每个分卷及合并包后恢复到 `accel/`。已存在但内容不同的文件会拒绝覆盖。
- `accel/`：原源码的只读工作副本，由 Git 忽略。恢复后不在这里修改；变更写在本兼容层。
- `build/vivado2017/rtl/`：生成的兼容 RTL，附原文件/生成文件 SHA256 manifest。
- `build/vivado2017/sim/`：四组仿真、向量和日志；`verification.json` 绑定通过结果与实际输入文件哈希。
- `build/vivado2017/quad-2017/project/blite_quad_2017.xpr`：可在 Vivado GUI 打开的完整工程。
- `build/vivado2017/quad-2017/`：验收后导出的 `.bit`、`.hwh`、`.hwdef`、`.hdf` 以及资源/时序报告。

`accel/` 和 `build/` 都能重新生成，不将它们作为共享记忆或修改的唯一存储位置。重建依赖 root 下原 `source/` 分卷及本目录脚本。

## 实际兼容修改

1. **整数归一化优先级循环**：2017.4 XSim 对原 descending + mutable found 写法的测试中，`int56_to_fp32` 的 msb 错误保持为 0，核心 8 行全部数值失败。兼容层改成升序扫描、最后匹配获最高优先级，found 单独由 `|av` 得到。数学映射不变，未放宽误差阈值。修改同时覆盖 `int_to_fp32` 和 `int56_to_fp32`；原快照不改动。
2. **DMA Stream 参数传播**：2017.4 的 `c_s_axis_s2mm_tdata_width` 是只读传播参数，原逐引脚连线会触发 DMA post_propagate 错误。改为连接完整 AXIS 接口，让工具传播 64 位宽；S2MM TKEEP 仍显式接 8'hFF。
3. **连接检查**：保留 64 位宽、valid/ready/last、TKEEP 检查；2017.4 对接口连接使用 interface-net 路径核对对应 DMA 和计算实例，而非要求每个接口引脚单独具有 scalar net。
4. **PS 外部接口**：显式导出 DDR 和 FIXED_IO。
5. **硬件交付格式**：2017.4 提供 `write_hwdef` / `write_sysdef`，没有 `write_hw_platform`。导出同名 bit/HWH 供后续 PYNQ 适配验证，并保留 HDF；不把 HDF 改后缀冒充 XSA。

四实例数、DMA 地址 `0x40400000/0x40410000/0x40420000/0x40430000`、83.333 MHz 请求值、四 HP 拓扑及算术格式保持原设计。2017.4 的布局布线结果必须独立验收，不能沿用旧日志或旧 bitstream 的时序/板测结论。

## 仿真验收

单独运行：

```powershell
python tools/restore_source.py
.\compat\vivado2017\verify.ps1
```

已在本机 Vivado 2017.4 实测通过：

| 测试 | 标记 | 覆盖 |
| --- | --- | --- |
| 归一化数学参考 | `NORMALIZATION-PASS 1333 vectors` | 正负号、零、每个最高位位置、邻近值、56/24 位边界、随机值与全部 6 位无符号输入 |
| 核心 | `TB-PASS: 8 rows, 0 errors` | 原合成向量和原容差 |
| AXI-Stream | `AXIS-TB-PASS` | 原协议 TB 的断流、结果数值和末拍 |
| 真实权重头后暂停 | `REAL-STALL-PASS` | 真实输入及定向 16 拍暂停，误差约 2.59913e-7 |

原核心存在 acc_row 64 位连至 56 位转换器的端口截断告警，属于交付设计原行为；本次未扩展数值范围或改变该接口。旧 TB 的 PASS 不是完整协议覆盖证明。硬件板测和端到端模型验证仍需独立完成。

## IP 生成警告的核查

- TKEEP 接常量产生 `BD 41-1306`：有意覆盖该接口成员；生成网表须确认四个 DMA 的 TKEEP 分别接 8'hFF。
- PS HP ID 位宽 6 与单路实际 ID 位宽 1 产生 `BD 41-235`：须核对生成网表的 AWID/ARID 高位显式补零及返回 ID 低位连接，不笼统忽略宽度告警。
- 构建中其他错误、CRITICAL WARNING、未约束路径及失败时序需逐项审查；不得用旧日志声明通过。
- 本轮 DRC 无 Error/Critical Warning；仍保留 DSP 流水建议、供应商 FIFO 的 WRITE_FIRST 建议及未使用内部标志网告警。`Memdata 28-167` 限制 updatemem 修改厂商 FIFO 存储，本项目不使用该功能。本轮未降低规则严重度或添加 waiver。

## 导出说明依据

2017.4 的硬件导出命令见 [AMD UG835 v2017.4](https://docs.amd.com/api/khub/documents/5z3ulJJUfMdxsAsX2FN0sQ/content)，并已通过本机 Tcl 命令枚举确认。

当前重建进度及最终验收结果记录在根 `docs/PROJECT_CONTEXT.md`。本流程不自动连接或重新编程板卡。
