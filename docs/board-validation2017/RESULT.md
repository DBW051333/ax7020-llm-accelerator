# 2017.4 产物板端测试结果

日期：2026-10-28（Asia/Shanghai）。**加载和 DMA 通过；模型逐层数值验证通过，但 CPU/PL 生成文本一致性未通过。不能宣称整模型输出等价复现成功。**

## 实测范围

| 检查 | 结果 |
| --- | --- |
| 新 bit/HWH 通过 PYNQ 加载 | 通过，FCLK0=83.333332MHz |
| 1MiB/32MiB 连续缓冲区分配与释放 | 通过 |
| 单路原始小向量 | 通过 |
| 四路原始向量，100轮 | 通过 |
| 1/2/4路，各12配置×100轮 | 全部 bit-exact 通过；另有每配置6轮零/正常交替检查 |
| 四路512×8192，1000轮 | bit-exact通过，DMA 3.4617GMAC/s，含同步校验3.2183GMAC/s |
| 当前模型真实矩阵896×4864，5组激活 | 正常缩放模式通过，最差 relative L2=1.86795252e-7 |
| 4-token推理逐层验证 | 36次PL调用通过 |
| 完整24-token推理逐层验证 | 276次PL调用通过 relative L2≤1e-4 |
| CPU重复输出 | 两次逐字节相同 |
| PL重复输出 | 性能运行与开启验证的完整运行逐字节相同 |
| CPU/PL文本一致性 | **失败，第70字节首次不同；比较脚本退出码1** |
| 模型测试后的四路DMA复查 | 通过 |

逐层日志只打印前12次检查，其最大 relative L2 为7.16360853e-7；全部调用都会执行阈值判断，超限将终止运行。不能将已打印最大值当作全部276次调用的精确最大值。

## 同设置计时

同一原生二进制、同一GGUF，双线程，ctx256/batch64/ubatch64，seed1234、贪心，关闭warmup。prompt为 `Write a short story about a robot.`，8个输入token，请求生成24token，对应23次decode eval。性能运行关闭数值复算与剖析。

| 模式 | decode耗时 | token/s |
| --- | ---: | ---: |
| CPU | 43641.81ms | 0.527018 |
| PL+CPU回退 | 41286.41ms | 0.557084 |
| CPU复测 | 42269.07ms | 0.544133 |

PL性能运行实际完成276次调用、12个权重缓存项，DMA累计346.142ms，后端1024.354ms，缓存28.29MiB。上述速率只记录本轮计时；由于输出不同，不作为保持生成结果等价的加速验收。

## 输出差异

CPU两次输出相同：

```text
 The robot is named "Bee" and is programmed to be a helpful assistant for humans. The story should include a
```

PL两次输出相同：

```text
 The robot is named "Bee" and is programmed to be a helpful assistant. The story should include a detailed description
```

输出差异可重复，尚未定位本轮根因。下一步应固定CPU token序列，比较逐层量化激活/输出与首个不同logits，区分局部数值误差传播及量化边界敏感性等候选原因。本轮没有通过换prompt、放宽阈值或静默CPU复算来掩盖差异。

## 版本与证据

- bit SHA256：`f5c5e2faf46ce512b58a879106f178df8afa9ac5b96853b6ee73a6a117a5310a`，由本机Vivado2017.4从RTL重建。
- 模型：本地 `qwen2.5-0.5b-instruct-q4_k_m.gguf`，397808160 bytes，SHA256 `23c36f3a641c0062f5f60b1b98c652233a40adcc2c9f6c24df87d2e2b996248c`。290张量，与历史交付模型不同。
- llama.cpp基准：`dafae66cc242eb766797194d3c85c5e502625623`，应用原交付集成补丁；板端GCC/G++11.2原生构建，未替换系统库。
- 原生程序SHA256：`98dc545163e6fc8de326ca3dfc8127344287274dc61157857b1945f1cd56d91c`。
- 当前模型提取的 `blk.3.ffn_down.weight` SHA256：`0718fdbc9c243476a7432476891aa6a06e16484a5c41031caafb3c2b5e4c1c5f`。

本目录保存原始数值、计时与生成文本证据；机器可读结果为 `board-result.json`。完整日志、原生程序备份和部署包在主机 `build/board-validation2017/`；板端部署保留在 `/home/xilinx/ax7020-validation2017`。使用方式见 `compat/vivado2017/BOARD_TEST.md`。

测试进程已退出，锁和进程缓冲区已释放，overlay保留为本次版本。板卡系统时间仍为镜像旧日期，报告使用客户端日期；未修改持久网络、SD启动配置或系统运行库。
