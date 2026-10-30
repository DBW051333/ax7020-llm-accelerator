# Vivado 2017.4 四实例重建验收

日期：2026-10-28（Asia/Shanghai）。执行工具：本机 Vivado 2017.4，器件 `xc7z020clg400-2`。结果：**从交付 RTL 到四实例 bitstream、HWH 和 HDF 重建通过**。

## 范围与版本

- 原交付包 SHA256：`d67be205a0dad19ad6e7154ec4f2d9cc1e88784214b11d64ec8b326c516e9efc`。
- 原始源码恢复至 `accel/` 并保持只读；兼容变更由 `compat/vivado2017/prepare_rtl.py` 和 `build_quad.tcl` 生成，未使用交付 bitstream 或 DCP 替代本轮综合。
- 四个计算实例、四个 DMA、四个 HP，流宽 64 位；控制地址仍为 `0x40400000` 至 `0x40430000`，间隔 64KiB。
- `rtl-manifest.json` 保存原 RTL 与实际构建 RTL 的 SHA256；`verification.json` 保存本轮测试输入和日志的哈希。

## 本轮结果

| 验收项 | 实测结果 |
| --- | --- |
| 数学归一化参考 | 1333 向量通过，覆盖零、符号、边界、每个最高位位置及随机值 |
| 原核心 TB | `TB-PASS: 8 rows, 0 errors` |
| 原 AXIS TB | `AXIS-TB-PASS` |
| 真实输入头后暂停 | `REAL-STALL-PASS`，绝对误差 2.59913e-7 |
| 生成网表检查 | 64 项通过 |
| HWH 软件接口检查 | 33 项通过 |
| 综合、布局、布线、bitstream | 全部完成 |
| FCLK 时钟约束 | 12ns，约 83.333MHz |
| 最终 setup / hold slack | +0.374ns / +0.009ns |
| 最终时序结论 | All user specified timing constraints are met |
| 无时钟寄存器 / 未约束最大延迟引脚 | 0 / 0 |
| LUT / FF | 40749（76.60%）/ 24878（23.38%） |
| DSP / BRAM | 160（72.73%）/ 30（21.43%） |
| DRC | 无 Error/Critical Warning；Warning/Advisory 保留，无 waiver |
| HDF 内容一致性 | 内含 bit/HWH 与独立导出逐字节相同，并包含 PS7 初始化文件 |

原始 RTL 在此版本的核心仿真曾 8 行失败；归一化最高位检测的工具兼容改写解决该问题。DMA 接口连线和导出方式也按 2017.4 调整。未改变原 TB 数值容差；详见兼容目录 README。

## 操作入口

在仓库根目录 PowerShell 中执行：

```powershell
.\compat\vivado2017\rebuild.ps1
```

Vivado GUI 打开：`build/vivado2017/quad-2017/project/blite_quad_2017.xpr`。

产物：`build/vivado2017/quad-2017/blite_quad_2017.bit` 及同名 `.hwh/.hdf/.hwdef`。bit 大小 4045678 bytes；SHA256：

```text
f5c5e2faf46ce512b58a879106f178df8afa9ac5b96853b6ee73a6a117a5310a
```

完整日志：`build/vivado2017/implementation.log` 和 `quad-2017/project/blite_quad_2017.runs/`。验收后的文件哈希与状态见同目录 `rebuild-result.json`。

本硬件重建阶段未重新编程板卡。随后已执行加载、DMA和模型测试，结果是硬件与局部数值检查通过、模型文本一致性未通过，详见[板端测试报告](../board-validation2017/RESULT.md)。不能把硬件重建通过扩展为整模型输出等价通过。
