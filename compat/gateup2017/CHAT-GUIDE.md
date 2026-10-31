# MobaXterm 手动聊天测试指南（v5 融合配置）

板端当前状态：v5 融合 overlay（bit 91bbc865…）+ 配套程序（574fb6ee…），五模式验证通过，
decode 约 0.747 token/s。以下命令均在 MobaXterm 的 SSH 会话里执行。

## 1. 连接板卡

MobaXterm → Session → SSH：

| 项 | 值 |
| --- | --- |
| Remote host | 169.254.32.99 |
| Port | 22 |
| Username | xilinx |
| Password | xilinx |

若连不上：先在本机 `ping 169.254.32.99`；板卡重启后该地址由镜像自动配置，一般不变。

## 2. 一键启动聊天

```bash
cd /home/xilinx/ax7020-gateup2017
bash run.sh
```

- 会提示输入 sudo 密码（xilinx）——脚本先校验并加载匹配的 overlay（幂等，重复跑安全），
  然后自动进入交互聊天。
- 出现 `> ` 提示符即可输入。

## 3. 聊天操作

- 在 `> ` 后输入内容，回车生成。中文英文均可。
- **打断当前生成**：按一次 `Ctrl+C`（生成停止，回到 `> `）。
- **退出聊天**：`Ctrl+D`（或直接关闭 MobaXterm 标签——进程随会话结束，硬件锁自动释放）。
- 退出时 stderr 会打印一行 `GATEUP-STATS …`（调用数/DMA/后端耗时汇总），可作为运行凭证。

## 4. 速度与行为预期（不要误判为卡死）

| 现象 | 数值/原因 |
| --- | --- |
| 首条回复特别慢 | 模型加载 + 24 层权重包首次准备（约 1.3s/层，仅首轮）+ prompt 逐 token 评估 |
| 每个输出 token 约 1.3~1.4 秒 | 0.747 token/s 是本配置的实测速度；一条 64 token 回复约 85 秒 |
| 每条回复最多 64 token | run.sh 固定 `-n 64`（可用 `bash run.sh -n 128` 这类附加参数覆盖） |
| 同样输入每次输出一致 | 固定 temp 0（贪心）+ seed 1234 |
| 文本与纯 CPU 版不完全相同 | **既有已知限制**：PL 近似算术所致，质量等价未验证；不代表坏了 |

## 5. 故障排查

| 报错/现象 | 处理 |
| --- | --- |
| `GATEUP hardware busy` | 别的进程占用加速器：`ps aux | grep llama` 查看；确认无进程后重跑 |
| `GATEUP DMA timeout / hardware failure` | 重新 `bash run.sh`（脚本会整片重载 overlay 自愈）；仍失败则重启板卡 |
| `receive length mismatch` | 同上，先重载 overlay |
| SSH 突然连不上 | 板卡可能重启过，地址一般不变；用串口（COM11，115200）看启动日志 |
| 聊天回复明显语无伦次 | 确认 overlay 是当前配套版本（`cat overlay/accepted.json` 的 bit 哈希应为 91bbc865…开头）；新旧协议不能混用 |

## 6. 可选：纯 CPU 对照

```bash
cd /home/xilinx/ax7020-gateup2017
env XILINX_XRT=/usr BLITE_GATEUP=0 BLITE_ENABLE=0 BLITE_Q58=0 \
 bin/llama-cli-gateup -m models/qwen2.5-0.5b-instruct-q4_k_m.gguf -cnv -if -c 512 -b 64 -ub 64 -t 2 --temp 0 -s 1234 -n 64
```

速度约 0.54 token/s。同一输入下 PL 融合版与 CPU 版的生成文本可能不同（上述已知限制）。

## 7. 测完检查清单

- 进程已退出（`ps aux | grep llama` 无残留）；
- `ls /tmp/blite-perf.lock` 存在没关系（flock 随进程释放）；
- 若要跑正式测试/构建，先确认锁未被持有（`fuser /tmp/blite-perf.lock`）。
