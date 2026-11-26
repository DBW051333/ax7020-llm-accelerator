# AX7020 共享项目上下文

最后维护：2026-10-31（Asia/Shanghai）。初次建立基于提交 `cb76351` 的交付快照。

2026-10-31：用户更换同型号板卡后，现已换回原 SD 卡；串口确认 Linux 与 SSH 正常，恢复临时辅助地址后 SSH 登录实测成功。下述已加载 overlay 及性能结论属于此前板测，不能据此推定本次开机的 FPGA 状态。

当前工作区更新：源码已通过 `tools/restore_source.py` 的等价校验恢复到 `R/accel`（Git 忽略的只读快照），2017.4 适配入口为 `compat/vivado2017/rebuild.ps1`。下文“未解包”等表述是初始化时的历史状态；以最新交接和任务表为准。

当前板卡实际加载Gate/Up+SiLU/乘法融合实验overlay，原四实例B-Lite产物和程序保留为交付基线。融合版完成2017.4重建和上板，WNS+0.442ns/WHS+0.042ns；模型553次局部检查通过，生成速率0.6668/0.6673 token/s，对比CPU0.5437、原Q4版0.5468。CPU/PL文本仍不同，模型质量等价尚未验证。新入口 `compat/gateup2017/README.md`，证据 `docs/gateup2017/RESULT.md`。当前板端程序/overlay协议须配套使用。

原Q4基线板测结论：2017.4产物加载、DMA、真实矩阵及完整24-token逐层数值检查通过，但本地模型CPU/PL文本一致性未通过。详见文末板端验证及 `docs/board-validation2017/RESULT.md`；不能宣称整模型输出等价复现。

2026-10-29 固定token诊断：相同CPU前缀下，第17个生成token由CPU的 ` for` 翻转为PL的 `.`，候选分差从+0.067505变为−0.023226。首Q4矩阵的896行硬件输出与独立RTL算术重放逐位一致；逐层显式替换为同输入CPU参考后，24步全部logits恢复与CPU逐位一致。已确认本例由Q4近似算术微差触发后续放大；不能认定模型质量可接受，未修复文本等价失败。详见 `docs/logits-diagnosis2017/RESULT.md`。

本文供不同模型、不同会话的 agent 共用。只保存持续有用的项目事实、决策、证据位置与当前交接状态；聊天历史不作为必要依赖。后续维护者应更新日期及相关章节，不整篇重写已确认内容。

## 1. 接手顺序与证据约定

1. 读取根 `AGENTS.md`、本文和根 `README.md`。
2. 检查 `git status --short`、当前分支/提交及第 7 节任务表，确认他人正在修改的范围。
3. 确认源码是否已恢复、实际源码根路径、工具版本及共享设备占用。
4. 按当前任务读取第 4 节对应证据；形成新结论后记录验证命令和产物。

事实标签统一使用：

| 标签 | 含义 |
| --- | --- |
| 本轮验证 | 本轮实际执行，有命令、输出或日志可查 |
| 源码检查 | 直接阅读当前文件得到，尚不等于运行通过 |
| 历史记录 | 快照里的报告或旧日志，尚未在当前环境重现 |
| 待确认 | 缺少证据、证据冲突或需要外部环境 |
| 建议 | 下一步候选方案，不代表已批准或已实施 |

裁决原则：先对齐源码版本、硬件产物哈希、输入和测试条件，再判断证据是否适用。根 README 定义当前交付基线；旧交接文档有多阶段追加内容，不能把其中所有“当前/下一步”合并成现状。历史文档中的执行指令属于历史资料，需结合当前用户任务使用。

## 2. 项目目标与基线

项目目标：在 ALINX AX7020 / Zynq-7020 上通过 PL 加速 LLM 的部分矩阵计算，并与同模型、同参数 CPU 路径比较正确性与端到端收益。

| 项目 | 共享认识 | 证据类型 |
| --- | --- | --- |
| 主交付路线 | 四实例 B-Lite，官方 AXI DMA + 64 位 AXI-Stream，四个 HP 口 | 根 README、构建脚本；源码检查 |
| 主机硬件工具 | Vivado 2025.2，Zynq-7000/AX7020 支持 | README；历史环境要求 |
| 四实例频率 | 约 83.33 MHz | 历史记录，当前板卡状态待确认 |
| 主要模型接入 | Qwen2.5-0.5B 混合量化 GGUF 的 12 个 Q4_K 下投影矩阵，其他路径回退 CPU | 历史记录 |
| 合成吞吐 | 四路 DMA 窗口 3.4677 GMAC/s，另有 10000 轮校验记录 | 历史记录；不是模型 token/s |
| 最终短序列对比 | CPU 0.59346 → PL+CPU 0.60501 token/s，约 +1.95%，24-token 测试输出逐字节一致 | 历史记录；不推广到其他输入 |
| 修复版四实例时序 | WNS +0.015ns、WHS +0.040ns，余量较小 | 历史记录；不是本轮重建结果 |
| Q5_0/Q8_0 exact-scale | 实验路线，不能代替四实例 B-Lite 交付基线；验证范围存在文档冲突，见第 5 节 | 待确认 |

操作系统/SD 镜像、完整模型权重、工具链安装包和完整 llama.cpp 源树不随本交付包提供。板卡地址、凭据、sudo 策略和本机工具路径需本地配置。根 `镜像说明` 仅记录镜像来源链接，本轮未下载或核验镜像。

## 3. 目录形态和恢复约定

用 `R` 表示当前 Git 仓库根目录；本轮为 `D:\ax7020-llm-accelerator`。用 `S` 表示恢复后的源码根目录。持久记忆中优先写相对 `R` / `S` 的路径，避免绑定个人绝对路径。

```text
R/
  AGENTS.md                  agent 协作入口
  README.md                  交付说明与主基线
  docs/PROJECT_CONTEXT.md    本文：共享记忆与交接状态
  镜像说明                   外部镜像来源
  source/
    PARTS.sha256             各分卷校验清单
    SHA256SUMS               合并压缩包校验清单
    ax7020-source.tar.xz.part-000 ... part-012
```

本轮验证：13 个分卷及内存合并后的 SHA256 全部通过，压缩包有 512 个成员（含目录），未解包到工作区。合并包 SHA256：

```text
d67be205a0dad19ad6e7154ec4f2d9cc1e88784214b11d64ec8b326c516e9efc
```

README 的恢复命令适用于 Bash/WSL/Linux，在 `R` 执行：

```bash
sha256sum -c source/PARTS.sha256
cat source/ax7020-source.tar.xz.part-* > ax7020-source.tar.xz
sha256sum -c source/SHA256SUMS
tar -xJf ax7020-source.tar.xz
```

压缩包自带顶层目录 `ax7020-llm-accelerator/`，因此上述命令默认得到 `S = R/ax7020-llm-accelerator`。不要把它误认为已合并到 `R`；解包前检查目标是否已有其他 agent 的工作。PowerShell 不要直接照抄 Bash 的二进制拼接命令。

源码恢复策略需按实施任务确定：可在独立工作目录恢复，或单独变更将源码纳入正常 Git 跟踪。当前尚未选择或执行源码迁移；不要把分卷和已修改源码同时视为同一事实源。修改恢复后的源码时，交接必须说明实际路径、Git 跟踪状态和补丁/提交位置；不能仅依赖未提交的本地解包目录。

2026-10-28 重建任务已选择 `S = R/accel`，恢复 342 个文件，共 21313300 bytes；`docs/source-snapshot-manifest.json` 保存恢复文件的 SHA256。原快照保持只读；受 Git 跟踪的兼容层生成独立 RTL，构建目录单独忽略。新机器可通过 `tools/restore_source.py` 重建，无需提交重复二进制快照。

## 4. 源码与证据地图

以下路径均相对 `S`，当前需在压缩包内读取或恢复后访问。

| 路径 | 用途 |
| --- | --- |
| `移交文档.md` | 历史阶段汇总；顶部更新更正了正文多处旧结论 |
| `交接指南.md`、`接手AI执行指南.md` | 早期协议、排障与验证经验；执行前核对当前实现 |
| `rtl/fpu32.v`、`blite_core.v`、`blite_axis_top.v` | 主线算术与流式顶层（后三个文件均在 rtl 下） |
| `rtl/bd_dma_quad.tcl` | 四实例构建入口，在 `S/rtl` 运行 |
| `rtl/blite_sys_quad.xsa`、`artifacts/blite_quad_wrapper.bit` | 交付主基线硬件产物 |
| `rtl/blite_sys_quad.pre-xd-fix.xsa` | 修复前留档，不能和修复版混淆 |
| `rtl/tb_core.v`、`rtl/tb_axis.v`、`verify/real-stall/` | 核心、协议和头后暂停竞态验证 |
| `board/perf_parallel.c`、`board/load_parallel.py` | 多路板测、overlay 加载与时钟处理 |
| `board/blite_runtime.c`、`board/blite_runtime.h` | Q4_K 四路 runtime、组包和缓存 |
| `board/benchmark_blite.sh`、`board/run_llama_blite.sh` | CPU/PL 串行比较与私有运行库启动 |
| `integration/build_blite.sh`、`llama.cpp-integration.patch` | 软件集成构建与上游补丁 |
| `LLAMA_CPP_BASE_REVISION.txt` | llama.cpp 补丁基准：`dafae66cc242eb766797194d3c85c5e502625623` |
| `docs/真实模型接入.md`、`docs/model-integration-20261025/` | 真实矩阵、竞态修复、逐层校验与端到端结果 |
| `docs/资源并行提速.md`、`docs/resource-speedup-20261025/` | 单/双/四路合成吞吐、测试条件和日志 |
| `experimental/q58*/`、`integration/build_q58*` | Q58 计算、缩放、协议、runtime 与构建实验 |
| `docs/pl-expansion-20261025/` | Q58 的状态、清单、参考结果及审查裁决 |
| `tools/inspect_gguf.py`、`tools/q58_reference.py` | GGUF 检查与 Q58 参考工具 |

原文中的 `/home/ding/DIC`、`<repo-root>/accel`、`tools/llama.cpp` 等是原开发工作区路径，不能直接套用本仓库布局。已检查 `integration/build_blite.sh`：它通过脚本向上两层查找工作区，依赖同级 `tools/` 和 `accel/board`，并不适配直接解包后的目录。软件复建前需要恢复相应工作区布局或有针对性地适配脚本，不能宣称开箱即用。

## 5. 已知冲突与容易误用的信息

- **Q58 验证状态冲突**：根 README 称完整 overlay 实现与新板行为尚未建立；`experimental/q58_exact/CONTRACT.md` 声称通过综合、布线时序和板上矩阵测试，并明确不保证整模型文本一致。`docs/pl-expansion-20261025/review-triage.md` 也记录量化边界导致文本差异。当前只确认这些声明存在，没有复核对应完整证据链；继续按实验路线处理，后续核对源码、manifest、产物和板测记录再裁决。
- **“零 Q4_K 张量”已被后续记录纠正**：历史记录为 12 个 Q4_K 的 `ffn_down.weight`，K=4864、N=896、NSB=19。不能仅由 `Q4_K_M` 文件名推导全部张量格式。
- **时序对应不同产物**：较早四实例 +0.187/+0.009ns 与修复后 +0.015/+0.040ns 不能混写为同一构建结果。
- **旧待办可能已完成**：双路 C 驱动、四实例吞吐和 Q4_K 真实模型接入已有后续历史记录；不应根据旧正文直接重新立项。
- **频率显示可能冲突**：后续资源文档记录设备树基准频率和寄存器换算修正；旧 debugfs/PYNQ 显示不能单独证明实际 FCLK。
- **仿真、板测、模型一致性分别验收**：数学参考误差小不代表与 ARM NEON 浮点累加逐位一致；短序列文本相同也不代表全部模型行为相同。

## 6. 实施与验证约定

主硬件入口（在配置好 Vivado 的环境中）：

```bash
cd "$S/rtl"
vivado -mode batch -source bd_dma_quad.tcl
```

`$S` 需由执行者设置为实际源码目录。脚本会创建/更新构建目录，运行前先核查占用。仿真使用 Vivado 2025.2 的 `xvlog/xelab/xsim`，按测试选择源文件、向量和工作目录；主线历史标记包括 `TB-PASS`、`AXIS-TB-PASS`、`REAL-STALL-PASS`。PASS 必须同时绑定进程退出码、输入和源码版本，不能只搜索旧日志字符串。

- 硬件变更：先取得相关仿真结果，再检查构建警告、接口位宽/连接及 setup/hold 收敛，最后按任务范围做匹配产物的板测。
- 板测：按历史已验证的 PYNQ/XSA 完整加载路径初始化 PS/FCLK；不要直接用 raw JTAG 编程 PL。保存旧 overlay 及其哈希，命令设置超时。
- DMA：先挂接收再发输入，每轮清旧 IOC，检查双通道完成、错误、接收长度和缓存同步。只复位 DMA 不保证自研流式 FSM 已复位，半包失败后按完整恢复路径处理。
- 性能：固定模型哈希、程序版本、线程、prompt、采样及上下文参数；区分初始化、prefill、decode、DMA 窗口和校验时间。比较性能时关闭额外数值复算/剖析，并保留硬件调用与 CPU 回退证据。
- 缓存：权重缓存期间源权重须保持有效且不变；Q58 的释放/替换策略以对应 runtime 的清理契约为准。
- 不恢复已废弃的 `blite_rdma/blite_wdma/blite_top` 自研 AXI master 路线，除非当前任务明确要求重新评估且有新证据。

## 7. 多 Agent 任务与共享资源

任务 ID、负责人可使用 agent 名或会话标识。开始写文件前登记修改范围；同时编辑本文时也需协调，优先追加自己的交接段落并检查最新 diff。登记后重新读取任务表以发现冲突；表格本身不提供原子锁。

| 任务 ID | 负责人 | 状态 | 修改范围 | 独占资源/实际锁 | 最近更新 | 下一步/交接 |
| --- | --- | --- | --- | --- | --- | --- |
| resident-1202-release | Codex | 已完成 | compat/head2017/、README.md、共享交接 | 无设备占用 | 2026-11-20 | 1.202 tok/s 原分块常驻版，`codex/axi-resident-1202` |
| context-init | 本轮 Codex | 已完成 | R/AGENTS.md、R/docs/PROJECT_CONTEXT.md、R/README.md | 无 | 2026-10-28 | 已建立共享入口；实现任务待用户指定 |
| readiness-audit | 本轮 Codex | 已完成 | R/docs/PROJECT_CONTEXT.md；只读检查 D:/shuji | 无 | 2026-10-28 | 见第 9 节；板端系统状态仍待用户确认 |
| board-discovery | 本轮 Codex | 已完成 | 串口只读系统/网络查询；R/docs/PROJECT_CONTEXT.md | COM13 已关闭释放 | 2026-10-28 | 已确认 PYNQ 启动；电脑有线网卡与板卡不在同一 IPv4 子网 |
| ssh-connect | 本轮 Codex | 已完成 | 板端 eth0 临时辅助地址；R/docs/PROJECT_CONTEXT.md | 串口和 SSH 均已关闭释放 | 2026-10-28 | 密码认证及只读 SSH 命令成功；重启后需重建临时网络连接 |
| board-readiness | 本轮 Codex | 已完成 | SSH 只读环境核查；R/docs/PROJECT_CONTEXT.md | SSH 会话已关闭 | 2026-10-28 | PYNQ 虚拟环境与 XRT 库存在；项目部署、CMA 占用及功能验收未完成 |
| vivado2017-rebuild | 本轮 Codex | 已完成 | tools/、compat/vivado2017/、docs/；恢复只读 accel/ | Vivado 构建已结束，目录可复用 | 2026-10-28 | RTL→bit/HWH/HDF 验收通过，WNS+0.374ns/WHS+0.009ns；本产物尚未上板 |
| board-validation2017 | 本轮 Codex | 已完成 | tools/、compat/vivado2017/、docs/；板端独立测试目录 | 进程已结束、锁已释放；新 overlay 保留 | 2026-10-28 | 测试完成；模型文本一致性失败，原因待定位，不能标记整项目验收通过 |
| logits-diagnosis2017 | 本轮 Codex | 已完成 | compat/vivado2017/diagnostics/、docs/；板端独立诊断程序与日志 | 进程结束、锁已查释放；原体验程序未变 | 2026-10-29 | 已定位近似算术触发放大及首次候选翻转；具体层间量化边界和质量可接受性仍未验证 |
| gateup-fusion2017 | 本轮 Codex | 已完成 | compat/gateup2017/、docs/、README.md；独立构建与板端部署目录 | 构建/测试进程结束，锁已查释放；板端保留融合overlay | 2026-10-29 | 融合硬件、局部数值和性能测试完成；约0.667tps，相对CPU+22.7%/原Q4+22.0%；文本一致性失败，质量等价未验证 |
| replacement-ssh | 本轮 Codex | 已完成 | 原SD卡串口查询及eth0临时辅助地址；docs/PROJECT_CONTEXT.md | COM11和SSH均已关闭释放；未加载overlay | 2026-10-31 | 主机指纹核对及密码登录通过；辅助地址重启失效 |
| fusion-speedup2017 | ZCode(2026-10-30会话) | 已完成 | compat/gateup2017/（RTL 线速重写+dot32 握手+runtime 流水化+prepare.py）、build/gateup2017/（tag quad-2017-v5）、docs/；不动 accel/ | 构建/测试进程结束，锁已查释放；板端 v5 overlay 已加载，v4 归档于 logs-v4/overlay-v4 | 2026-10-30 | 0.747tps（较CPU+37.5%/较v4融合+11.9%）；553次数值检查全过且最差relative L2与v4相同（逐位同源）；文本一致性仍失败；详见 docs/fusion-speedup2017/RESULT.md |
| pl-roadmap2017 | ZCode(2026-10-30会话) | 已完成 | docs/pl-roadmap-20261030/PLAN.md、docs/PROJECT_CONTEXT.md；纯分析未改代码/硬件 | 无独占资源 | 2026-10-30 | PL 资源扩展路线（Down/Attention/LMHead 入 PL + DSP 化 MAC）与带宽上限推算（约5.0tps@实测带宽）；全部估算需独立立项验证 |
| full-source-20261030 | ZCode(2026-10-30/31会话) | 阶段1挂起（板回滚v5） | 分支 dev/ligan-full-source；compat/gateup2017/（fmt12 引擎收敛+runtime matvec+callback Down 派发+test_model.sh 829 预期）、build/gateup2017/quad-2017-v6/ | 硬件已验收未上板；板端连接中断（COM13 消失、169.254.32.1 半丢包无 SSH）待用户恢复 | 2026-10-31 | 阶段1：fmt12 引擎+runtime/callback 完成并上板联调——发现并修复 4 类问题（matvec 包头 0x1558|12<<8=0x17 非法格式→BAD 态；回调 rows 取 dst->ne[1]=1；Q4_K vec_dot 需 Q8_K 校验改 to_float 参考；**激活块 Q8_0 scale 缺失（498x 偏差根因，dump 重算 77.35 vs 板上 7.69 证实）→ dx3 三因子 scaler 已实现**，Q5 回归绿）；遗留 (12,4,512) row0 2^63 饱和一个数值问题（DEBUG-NOTES-fmt12.md #5）；v6 bit 不含 dx3，收敛后需 v7 重建；板端连接已恢复（169.254.32.99，重启后 eth0 持久双地址） |

状态使用：进行中 / 等待外部条件 / 待交接 / 已完成 / 已取消。时间不足以证明资源已释放；记录过期时先核查实际进程并协调，不能直接夺取。软件进程互斥锁不能自动覆盖另一个驱动、远程主机或人工操作。

共享资源记录模板：

```text
资源：板卡标识 / overlay / 串口 / Vivado 绝对工作目录
持有者与任务 ID：
开始时间与预计结束时间（含时区）：
当前进程/PID、主机及实际锁路径（如有）：
加载产物及 SHA256：
允许他人执行的操作：
释放时间与恢复后的状态：
```

不同任务优先使用独立构建目录和日志目录。修改相同源码文件、协议或软硬件接口时明确一个集成负责人，先统一接口再合并；不要同时改协议、算术、驱动和模型接入后仅凭最终结果定位问题。

## 8. 每轮交接模板与维护规则

稳定事实保留在第 2～6 节；活动状态放第 7 节；每轮交接在本节追加简短条目。结论被替代时标记更正并链接新证据，保留关键决策原因。详细日志放独立文件，本文只索引；已完成的长篇过程移至后续建立的归档目录，避免记忆无限增长。

```text
日期/时区、agent、任务 ID：
目标与实际完成范围：
分支/提交、工作区、未提交文件及补丁位置：
修改文件与原因：
已确认事实（附事实标签）：
验证命令、退出码、日志/产物路径及必要哈希：
未验证项、失败现象或证据冲突：
决策与理由（仅记录影响后续工作的部分）：
共享资源是否释放、设备当前状态：
下一步可直接执行的动作及前置条件：
```

### 2026-10-28：共享记忆初始化

- 本轮验证：Git 初始工作区干净；全部分卷及合并包哈希通过；读取压缩包目录、主要交接与专题文档、相关构建脚本。
- 产出：根 agent 入口、本文及 README 导航。新增文档使用 UTF-8，目录地图来自实际包内容。
- 待确认：未解包、未运行 Vivado/RTL 仿真、未构建软件、未连接或操作板卡；设备当前状态未知。历史性能与 PASS 均未在本轮复现。
- 建议：实施任务开始时先决定源码恢复位置和版本管理方式，再补齐环境与 Q58 证据链；本轮不将建议标记为已开始的实现任务。

## 9. 本机复现条件核查（2026-10-28）

本节是当前机器的环境记录，不代表所有协作者的环境。此次仅做文件和系统枚举，未打开串口、连接板卡、加载 overlay 或安装软件。

| 条件 | 本轮验证结果 | 影响 |
| --- | --- | --- |
| 板卡资料 | `D:/shuji` 有 AX7020 用户手册 V2.2、原理图 V2.0、基础教程及 `analysis/` 文本提取件 | 资料中的 XC7Z020-2CLG400I、1GB/32bit DDR3 与目标一致；实物版本仍需核对 |
| 本机 Vivado | 找到 `D:/Xilinx/Vivado/2017.4/bin/vivado.bat`，旧实验日志同为 2017.4；本次检查的常用安装位置未发现 2025.2 | 主线指定的 2025.2 构建环境尚未就绪；不能假定 2017.4 可直接重建 |
| Linux 主机环境 | `wsl --list --quiet` 返回未安装 WSL；未检查其他远程 Linux/虚拟机可用性 | 交付软件构建脚本不能直接在当前 PowerShell 环境运行 |
| 串口 | 系统枚举到 COM13，Silicon Labs CP210x USB to UART Bridge | 只能证明串口设备存在，不能证明板卡已启动 Linux |
| 板端系统与网络 | 用户确认板卡已连接、插有系统镜像的 SD 卡且已接网口；未配置当前进程的 BOARD_IP，启动/SSH/PYNQ/XRT/CMA 状态尚未实测 | 物理条件由用户确认；需确认系统实际启动及软件运行环境 |
| SD 启动文件 | 在 D:/shuji 文件清单中未找到 `.img`、`.img.xz`、`BOOT.BIN`、`image.ub` 或 `.xsa` | 该目录本身尚不能提供已确认的板端运行系统；其他位置/已写入 SD 卡状态未核查 |
| PC 推理 | `D:/shuji/final_lab` 有 Windows llama.cpp 程序与历史 PC 推理日志 | PC 推理记录不能代替 ARM 板端基线 |
| llama.cpp | 本地源码 HEAD 为 `620d2225cc436ab0b001e3200e590e3b286ef9ab`；本地对象库查不到交付补丁基准 `dafae66...` | 必须获取匹配基准或验证移植；不能直接假设现有源码能应用补丁 |

### 本地模型核查

直接运行交付包中的只读 GGUF 检查器（未落盘源码），确认：

- 文件：`D:/shuji/final_lab/model/qwen2.5-0.5b-instruct-q4_k_m.gguf`。
- 大小：397808160 bytes；SHA256：`23c36f3a641c0062f5f60b1b98c652233a40adcc2c9f6c24df87d2e2b996248c`。
- GGUF v3，共 290 个张量，类型计数 `{0:121, 6:132, 8:13, 12:12, 14:12}`。
- 12 个 Q4_K 均为 `[4864,896]` 的下投影矩阵，层号为 3、4、6、7、9、10、12、13、15、16、18、19。
- 与历史交付模型的 291 张量及层分布不同，因此不能按同一模型快照处理。它具备主线支持的格式与形状，实际旧版 loader 兼容性、硬件派发、数值及生成表现仍需验证；不能直接复用历史性能或黄金输出。

### 复现判断与建议顺序

已有板卡资料、可用候选模型和交付硬件产物，具备开始分阶段复现的基础；当前未满足已确认的完整复现条件。

1. 确认实物板卡、SD 卡系统、串口启动日志和 SSH，核查 PYNQ/XRT、DMA 分配与权限。
2. 可优先尝试现成四实例 XSA 的板端复现：先小向量和重复事务校验，再测合成吞吐。此路线无需先在本机重新生成 bitstream，但仍需匹配的软件运行环境和驱动。
3. 获取匹配 llama.cpp 基准及 ARM 工具链，适配工作区路径，重建板端 CPU/PL 程序；先验证当前模型可加载，再按同文件同参数对照。
4. 若要求从 RTL 重建，另准备 Vivado 2025.2，完成仿真、实现时序与板测。现阶段不把 Q58 整模型复现列为已具备条件。

### 板卡发现更新（2026-10-28，本轮实测）

- 通过 COM13、115200 baud 串口发送回车后收到已登录的 shell 提示符；只执行 hostname、uname、os-release 和 ip 查询。
- 主机名 `pynq`，系统 PynqLinux 3.0（Ubuntu 22.04），内核 `5.15.19-xilinx-v2022.1`，架构 `armv7l`。
- 板端 eth0 为 UP/LOWER_UP，已有静态 IPv4 地址；电脑 Realtek 有线链路 Up、100Mbps，但只有 169.254/16 自动地址，与板端不在同一子网。具体设备地址保留在当前会话，不作为跨环境项目常量。
- 已找到并确认运行中的 Linux 板卡；尚未验证 SSH、PYNQ Python API、XRT 或 DMA 功能。未改网络配置、未重启、未加载 overlay；串口已关闭释放。

### SSH 连接更新（2026-10-28，本轮实测）

- 用户确认使用默认登录密码；凭据不写入文件。
- Windows 为有线网卡添加静态地址返回“拒绝访问”，未生效。随后通过串口和 sudo 在板端 eth0 添加与电脑 APIPA 网段相通的临时辅助地址，保留原静态地址；未修改持久网络配置。具体连接地址在本轮会话中，重启后临时地址消失。
- 经串口取得板端 ED25519 公钥指纹，再与 SSH 握手公钥核对一致，密码认证成功。SSH 执行 hostname、whoami、uname、ip 及 Python 模块存在性查询，退出码 0。
- 确认以 xilinx 用户登录 pynq，Python3 能发现 pynq 模块；仅模块存在性检查，尚未验证 PYNQ API、XRT 或 DMA。未加载 overlay。
- 串口及测试 SSH 会话已关闭释放，板端临时辅助地址保留供用户 MobaXterm 连接。

### 板端复现条件更新（2026-10-28，本轮实测）

- 内存总量约 1.0 GiB，available 约 868 MiB；根分区剩余约 21 GiB；swap 511 MiB。CMA 总量 131072 kB，空闲 9644 kB，实际占用来源尚未确认，不能假设大 DMA 缓冲可分配。
- 默认 `/usr/bin/python3` 为 3.10.4，直接在 home 导入本地 pynq 时缺 pydantic；使用 `/usr/local/share/pynq-venv/bin/python3` 可正常导入 pydantic 和 PYNQ 3.0.1，模块为 `/home/xilinx/pynq/__init__.py`，Overlay/allocate API 存在。应使用该虚拟环境或等价依赖配置，不把默认 Python 的失败误判为 PYNQ 未安装。
- 找到 `/usr/lib/libxrt_core.so`（2.13.0）和 coreutil 库，以及 `/dev/fpga0`、`/dev/xlnk`、DRM 设备。仅确认文件存在，尚未调用 XRT 分配、DMA 或加载硬件。
- 板端有 GCC/G++ 11.2.0、CMake 3.22.1、git、timeout，可评估板上本地编译方案；是否能构建匹配版本尚未验证。
- 在 `/home/xilinx` 最大深度 3 的检索中，未找到项目 XSA、GGUF、llama-cli、perf_parallel 或 load_parallel.py；其他位置未全面搜索。项目部署尚未完成。
- 本轮未重启、停止现有进程、释放 CMA、加载 overlay 或运行推理。结论：运行环境具备继续复现的主要基础，但尚不能宣称完整复现；先查 CMA 占用与资源使用，再部署并完成小向量、重复 DMA、合成吞吐、同模型 CPU/PL 验收。

### Vivado 2017.4 从 RTL 重建（2026-10-28，硬件重建已完成）

- 用户明确指定使用本地 Vivado 2017，从 RTL 重建。实际版本为 2017.4，工具路径 `D:/Xilinx/Vivado/2017.4/bin`。本轮仅操作本机构建，未重新编程板卡。
- 已校验/恢复原快照；入口、适配原因和复现命令见 `compat/vivado2017/README.md`。本机确认所需 PS7 5.5、DMA 7.1、互连 2.1、reset 5.0、constant 1.1 均在 IP 目录中。
- 原始核心 TB 在 2017.4 实测 8 行全部失败；诊断发现 int56_to_fp32 的最高位检测索引错误保持 0。兼容层将两处整数归一化循环改写为等价优先级扫描，不修改快照、不改变数值容差。
- 兼容 RTL 在 2017.4 XSim 实测四组通过：1333 组独立数学参考、核心 8 行、AXIS 原测试、真实输入头后暂停。证据位于 `build/vivado2017/sim/`，`verification.json` 绑定 RTL/输入/测试和日志哈希。
- 原逐引脚 DMA 连线在旧工具中触发只读位宽参数与 post_propagate 错误；改用接口连线并适配 stream gate 后，四实例 BD 已通过验证、生成 HWH 和工程。`audit_netlist.py` 的 64 项检查确认四路 64-bit 数据/握手/TLAST、TKEEP=0xff、HP 请求 ID 补零和共用时钟。
- 当前工程：`build/vivado2017/quad-2017/project/blite_quad_2017.xpr`。综合/布局/布线/bitstream/导出全部成功，最终 WNS +0.374ns、WHS +0.009ns，12ns 时钟约束不变；时序报告中无无时钟寄存器或未约束最大延迟引脚。
- 最终资源 LUT 40749/53200（76.60%）、寄存器 24878/106400（23.38%）、DSP 160/220（72.73%）、BRAM 30/140（21.43%）。DRC 保留 Warning/Advisory，无 Error/Critical Warning；未放宽约束或豁免规则。
- 导出 `blite_quad_2017.bit/.hwh/.hwdef/.hdf`，HDF 内 bit/HWH 与独立导出逐字节相同，含 ps7_init。bit SHA256：`f5c5e2faf46ce512b58a879106f178df8afa9ac5b96853b6ee73a6a117a5310a`。
- `docs/vivado2017-rebuild/RESULT.md` 和同目录验收数据保存本轮证据摘要；完整构建日志和产物在被忽略的 `build/vivado2017/`。脚本、说明与证据文件已落盘，尚未创建 Git 提交。
- 本次完成范围为四实例 B-Lite 的 RTL→硬件产物。未加载新产物、未板测、未验证整模型；后续须适配 2017.4 的 bit/HWH/HDF 加载及 PS 初始化，不能直接沿用只接受 XSA 的历史加载脚本。

### 2017.4 产物上板验证（2026-10-28，测试已完成，有未通过项）

- 用户已明确授权加载、DMA 校验和模型测试。板端独立目录 `/home/xilinx/ax7020-validation2017`；项目脚本使用 `/tmp/blite-perf.lock` 协调硬件访问。核查无已有加速器进程；Python redirect_server 为系统服务，不是占用 FPGA 的 notebook 内核。
- `load_overlay.py` 先核对已验收 bit SHA256，再用 bit/HWH 路径解析、验证四路地址并通过 PYNQ 下载。已成功加载，实际 FCLK0=83.333332MHz。加载前 PYNQ 记录的 bitfile 为 None；没有覆盖现有可识别的项目 overlay。
- 必须设置 `XILINX_XRT=/usr`。首次分配在加载前失败（No Devices/Overlay is not downloaded）；加载后 1MiB 和 32MiB 分配/释放均成功。CmaFree 低值不等价于分配失败，本轮未清空其他进程、修改 CMA 预留或重启。
- 单路原始 8×1024 小向量通过；四路原始向量 100 轮通过；1/2/4 路各 12 配置 ×100 轮 bit-exact 全通过，每配置另有 6 轮零/正常激活交替校验。四路 512×8192 连续 1000 轮通过，DMA 窗口 3.4617GMAC/s，含同步校验 3.2183GMAC/s。该性能运行时模型编译尚未启动。
- 从当前模型提取 `blk.3.ffn_down.weight`，2451456 bytes，SHA256 `0718fdbc9c243476a7432476891aa6a06e16484a5c41031caafb3c2b5e4c1c5f`。板上运行原 `test_real_matvec.c`，896×4864、5 组激活通过，启用运行时缩放的最差 relative_L2=1.86795252e-7；缩放关闭的诊断值不作为推理正确性结果。
- 当前模型已传至板端。已取得上游固定 revision `dafae66...`，下载包 SHA256 `933eccfb927b5e921ca23f18b2454583a6c6dcc89917fc07c0bb8f3dcffdb912`，应用原集成补丁，板端 GCC/G++11.2 原生构建成功。使用系统 glibc，不替换系统运行库。二进制 SHA256 `98dc545163e6fc8de326ca3dfc8127344287274dc61157857b1945f1cd56d91c`，主机已备份到 `build/board-validation2017/bin/`。
- 板卡时钟仍为镜像的旧日期；本轮报告日期以客户端 Asia/Shanghai 为准。部署解包采用 `tar -m` 避免未来文件时间影响编译，未更改板卡系统时间。
- 4-token 数值验证：36 次硬件调用通过；完整 24-token 验证：276 次硬件调用通过既定 relative_L2≤1e-4 检查。打印的前 12 层最大 relative_L2 为 7.16360853e-7，该数不能当作全部 276 次调用的已测最大值。
- 同二进制/同模型/同参数，8 prompt token、请求生成24 token、23次decode eval：CPU 43641.81ms（0.527018token/s），PL 41286.41ms（0.557084token/s），CPU复测42269.07ms（0.544133token/s）。性能运行关闭额外验证和剖析；PL性能运行276次调用、12个缓存项、28.29MiB缓存。
- **文本一致性失败**：CPU两次 stdout 字节相同；PL性能运行与开启验证的24-token运行 stdout 也字节相同；CPU/PL从第70字节分歧。CPU文本为“helpful assistant for humans...”，PL为“helpful assistant. The story...”。比较脚本按设计 exit 1，没有放宽条件或改为CPU复算后冒充PL通过。
- 结论：硬件与DMA链路及局部数值契约通过，当前模型的生成轨迹等价未通过。计时只作记录，不宣称等价质量下加速。微小数值差异/量化边界敏感性可作为后续候选解释，尚未定位本轮首个差异的根因。
- 后续若继续：固定CPU token序列（teacher forcing），逐层比较量化激活/输出及首个不同logits，定位第一个分歧；不得通过换prompt、放宽容差、静默CPU回退或覆盖失败日志改写验收结果。
- 最后四路小向量复查通过。测试/编译进程均结束，硬件锁和进程缓冲区释放，overlay 保留为本次重建版本；未修改SD启动配置/系统运行库/持久网络配置。完整日志在 `build/board-validation2017/`，便于版本管理的证据与摘要在 `docs/board-validation2017/`，原始快照保持不变。

### 固定 token / logits 定位（2026-10-29，本轮实测）

- 用户授权固定相同token序列比较首次logits分歧。新增 `compat/vivado2017/diagnostics/` 生成、运行和分析工具；证据报告为 `docs/logits-diagnosis2017/RESULT.md`。沿用当前未提交工作区，没有创建提交；不改只读 `accel/`。
- 板端开始前核查无推理/编译占用；保留原体验二进制和旧失败日志。独立诊断程序记录采样前原始logits、实际采样与强制token、Q4输入和同输入参考。四组串行运行均exit0：CPU、固定CPU历史的PL、同历史且显式替换Q4输出为CPU参考的因果实验、CPU复测。CPU文本匹配旧基线，CPU两次全部logits逐位一致。
- 24步151936维logits：首次数值分歧是step2，首次采样分歧是step16（第17个生成token），CPU选369 ` for`，PL选13 `.`。CPU/PL这两个候选的分差分别+0.06750488、−0.02322578；该步最大绝对误差0.51696229，relative L2=0.02727780。
- 首个Q4调用 `blk.3.ffn_down.weight` 的F32/Q8输入完全相同，输出relative L2=4.68791326e-7。整数位操作重放当前截断浮点/Q18/整数累加/末端转换和缩放，896行与实际硬件逐位一致。全部276次Q4调用相对各自CPU参考最差relative L2=1.75728438e-6，但完整网络误差明显放大。
- 因果实验仍实际调用硬件276次，但随后明确替换Q4输出，结果24步所有logits与CPU逐位一致。该实验只证明差异来源，不能标为PL等价、质量或性能通过。已捕获Q4层中，decode step2的blk.13首次出现543个不同Q8整数编码；更早的具体层间量化边界尚未逐算子定位。
- 独立诊断二进制SHA256 `0bb8856cd740e2aadb4d43e32be1ba8740a96aa4a074d4a10d666ce76da65d71`，原体验程序SHA256仍为 `98dc545163e6fc8de326ca3dfc8127344287274dc61157857b1945f1cd56d91c`。板端两处临时插桩源码已恢复并cmp核对；现有 `llama-build` 含诊断对象，下一次正式产出应从恢复源码重新构建。
- 全部进程结束，硬件锁可获取，overlay保留。没有改硬件、持久配置、板卡时钟或系统库。主机保留原始诊断归档和二进制于 `build/logits-diagnosis2017/`；摘要、哈希和小日志保存在docs目录。
- 下一步按目标选择：严格文本等价需研究更接近CPU的算术并验证；允许近似则先定义并评估困惑度/任务质量和重复退化。若继续定位放大边界，可捕获decode step2中blk.12→blk.13间所有量化输入与编码，不能宣称已有完整模型质量结论。

### Gate/Up + SiLU/乘法融合（2026-10-29，本轮实测完成）

- 用户授权加速Gate/Up、尽可能融合SiLU与逐元素乘法并上板验证。新增独立实验目录 `compat/gateup2017/`、`build/gateup2017/` 和板端 `/home/xilinx/ax7020-gateup2017`；原四实例Q4交付基线、原程序和旧失败证据保留。分支仍为 `dev/ligan`，HEAD `cb76351`，没有创建提交。
- 新四路实验核复用Q58整数点积和FP16精确尺度累加，增加Q30 sigmoid查表/插值和F32 RNE乘法。每路共用BRAM激活，逐行完成Gate、Up和SiLU×Up；四路分输出行。CPU负责输入Q8_0量化和其余计算，包括Down。原 `accel/` 快照342文件再次校验未改变。
- 仿真通过1600组有限F32乘法逐位比较、1870组SiLU×Up和68行流式结果，含K896/K8192、随机输入停顿、输出反压、零/新鲜度。v1–v3长组合路径未通过时序，未上板；改为多级归一化、对齐/舍入、ROM插值流水后，`quad-2017-v4` 最终WNS+0.442ns/WHS+0.042ns，12ns约束不变。LUT23539、FF18282、DSP24、BRAM84；无DRC Error/Critical Warning，64项网表和33项HWH检查通过，HDF载荷一致。
- 接入固定上游 `dafae66...`：增加有明确三输入依赖的F32自定义图节点，仅选当前Qwen单列、无偏置/缩放/LoRA、K896/rows4864的Q5_0 Gate/Up。运行失败立即停止，不静默CPU回退。多列和其他形状保持原CPU路径。编译时核对并备份六处上游文件，结束后恢复；原构建树对象和CMake缓存仍为实验状态，下一次正式构建须从恢复源码重新生成。
- 新bit SHA256 `d343cbb735b465eaa0503404adb3e8dafcdd8973b0c502f8e0019bdaa8c013a3`；新程序 `3029e019d190d0cf9319f7681a72e095b53140fbdd08ceccfdb80ecd867cbc07`。原B-Lite程序仍为 `98dc545163e6fc8de326ca3dfc8127344287274dc61157857b1945f1cd56d91c`。模型仍为既有相同SHA256，未覆盖权重。
- 板端PYNQ成功加载，FCLK83.333332MHz；真实第0层Gate/Up矩阵8组输入最差relative L2=2.96912207e-7，另100次零输入复查通过。完整24-token固定CPU前缀的553次融合调用全部满足同输入CPU参考relative L2≤1e-4，实测最差9.79996804e-7；只比较，不替换硬件输出。553含552次decode和prefill末层压缩到单列的1次调用。
- 无诊断性能：同prompt/模型、ctx256/b64/ub64/t2、temp0/seed1234，24token/23decode；CPU42304.32ms=0.5436797tps，原Q4版42065.02ms=0.5467726，融合34491.57ms=0.6668296、复测34465.72ms=0.6673297。首轮速率较CPU+22.65%、较Q4+21.96%。关闭数值复算、剖析和logits文件写入，无并行编译。权重包缓存149.625MiB在普通DDR；四路共用8MiB TX和48KiB RX，不是权重驻留PL。
- **文本一致性仍失败，质量等价未评估**：CPU重复完整logits逐位一致，融合重复自由文本一致；固定CPU历史第2个预测就从CPU的 ` robot` 翻为PL的 ` story`，该步logits最大绝对差0.5098753，24步最大0.7499304。局部数值通过不是整模型等价通过；速度与该限制必须一起报告。
- 证据及源码/部署哈希见 `docs/gateup2017/RESULT.md`、同目录JSON、RPT和小日志；原始logits、归档、可执行程序及工程在 `build/gateup2017/`。新旧程序均已主机备份。所有构建/测试进程结束、锁可获取；板卡保留融合overlay。未改SD启动配置、网络、系统库或板卡时间。手动入口 `cd /home/xilinx/ax7020-gateup2017 && bash run.sh` 会核对/加载匹配产物再启动聊天；旧Q4命令需先恢复原overlay。
- 下一步可按需要研究模型质量/数值边界、减少权重搬运及统一混合格式runtime。未自动扩大到LM Head、Q6_K、完整Attention或宣称原Q58实验全栈验收。
### 融合引擎线速化 + 打包流水化（2026-10-30，本轮实测完成）

- 用户授权自行探索加速并充分利用 PL 资源；每方案实现后以方案命名分支提交远程。任务 `fusion-speedup2017`，分支 `scheme/fusion-throughput`（自本轮基线提交 `0c4254f` 分出；基线提交把此前 Codex 各轮未提交的共享工作区首次入库并推送 origin/dev/ligan）。
- 瓶颈证据（v4 实测拆解）：后端 25.8ms/调用 = DMA 窗口 11.1（引擎每子块 15 拍，dot32 单缓冲致流 2 拍收 1 拍）+ CPU 侧 14.7（每调用 6.5MB memcpy+flush 且与 DMA 串行）。
- 方案：gateup_axis 全量重写（乒乓权重缓冲、dot32 线速握手、激活读管线、至多一个在途结果、权重字预算防包边界吞 header）；runtime 按 lane 流水打包/flush/启动。数值契约不变，与 v4 逐位一致（XSim 对拍 68 行含随机反压逐位相同；板上最差 relative L2 9.79996804e-07 与 v4 相同）。
- 排障记录：XSim 首版三个时序问题（xvalid 未置位、包边界吞 header、预算漏乘 blocks）由逐拍调试 TB 定位修复；首次构建 LUT 暴涨 17k 根因是 x_memory 双读口降级 LUTRAM，改单读口恢复 BRAM；Vivado 从 Git Bash 启动会被沙箱与 TMP=/tmp 环境破坏 IP Tcl 解释器，须以净化 TEMP 的 PowerShell 非沙箱运行；Git Bash 会把 MSYS 路径转换进 SFTP 远端参数（MSYS2_ARG_CONV_EXCL 禁用），并会把 heredoc 中的转义序列提前展开（字节级构造规避）。
- 板端：新程序 574fb6ee30fe481ea72a78658caf089b00510ad374358533309d22cedc20a916，bit 91bbc86575cc0e631bd11f91d4f93df22fdd175bbd5259e537663913c1671cf0（WNS+0.420/WHS+0.048，LUT 48.39%/BRAM 60.00%）。CPU 基线（新二进制）与固定参考逐字节一致；553 次强制验证全过；fused 30797.75ms=0.7468tps、复测 0.7413；CPU 0.5433/复测 0.5409。较 CPU +37.5%、较 v4 融合 +11.9%。
- 限制：文本一致性失败原样保留（引擎与 v4 数值逐位同源，属既有未解决问题），质量等价未验证；剩余瓶颈为 CPU 侧打包/flush（约 14ms/调用）。板端 169.254.32.1/16 为本轮临时辅助地址（重启失效），eth0:1 192.168.2.99/24 为既有配置非本轮所加；串口/SSH 用毕释放，锁可获取，无遗留进程。
- 证据：docs/fusion-speedup2017/（板端五模式日志、verify 明细、loaded.json）；build/gateup2017/{quad-2017-v5,bitexact,rtl-v4ref}。原始 v4 板端证据未覆盖（logs-v4/overlay-v4 归档）。

### PL 资源扩展路线与带宽上限分析（2026-10-30，分析完成）

- 任务 pl-roadmap2017（ZCode 同会话，fusion-speedup2017 之后）：将三轮探索固化为 docs/pl-roadmap-20261030/PLAN.md——资源账本（v5 实测：LUT 48%/DSP 10.9%/BRAM 60%）、DSP48E1 能力映射（2 MAC/片/拍位精确打包、层内串行分时复用）、算子迁移排序（Down≈341ms → Attention≈259ms → LMHead≈444ms，后两者为估算）、最大部署资源预算（LUT 66%/DSP 33%/BRAM 69%）与 tps 阶梯（0.747→约0.9→约1.0→2.5~4.0→5.0 带宽上限，端口理论 6.7）。
- 全部"估算"项未实现、未验证；任何落地须独立走仿真→时序→板测。文本一致性失败仍为既有未解决问题。交互式流程图为本轮会话可视化产物，不在仓库内。
- 本文件在 dev/ligan 上曾短暂包含未解决的合并冲突标记（提交 65d7e99），本提交以 scheme/fusion-throughput 的版本为基底重建修正。

### full-source 迁移任务启动（2026-10-31，WIP）

- 用户指令：按迁移排序（Down→Attention→LMHead）开发并推送到 dev/ligan/full_source。**git 限制**：dev/ligan 已存在导致子路径分支名不可用，实际分支为 `dev/ligan-full-source`（已推送，基点=dev/ligan 515ce2c 合并 scheme/fusion-throughput 220a6fe）。
- 模型张量实测（gguf-py）：Attention Q/K/O 全 24 层 Q5_0；V 混合 12 层 Q5_0 + 12 层 Q8_0（引擎 format 8 可覆盖，Q/K/V/O 均带 F32 bias 需 CPU 侧补加）；token_embd=Q8_0 [151936,896] 证实 LM Head 假设。
- 阶段1（Down 入 PL）设计定稿并部分实现：Q4_K 作为 format 12 接入统一引擎——dot32 增加 Σx 输出、双项 scaler（term=(d·sc)·Snq−(dmin·m)·Sx，Q5 路径 dx2=0 语义逐位不变、68 行回归通过）、乒乓缓冲扩至 18 字/超块、按格式预算。已修三处 bug（scale 切片偏移、fp16_of_6b 指数位宽、向量打包高位来源），**遗留两处数值问题（case A 2^-15 系统偏差、case B term2 恒零）**，fmt12 配置暂从验收向量摘除保持 GATEUP-VERIFIED 绿灯；运行时/回调未接入（不会派发错误数据到硬件）。
- 续作入口：compat/gateup2017/DEBUG-NOTES-fmt12.md（含 fp16_of_6b concat 截断 bug 的修复写法、恢复步骤、运行时接入设计）。

### full-source 阶段1（Down 入 PL）开发完成、等待板测（2026-10-31）

- 分支 dev/ligan-full-source（提交至 "runtime gateup_matvec + Down 派发接入 + v6 硬件验收"）。
- **fmt12（Q4_K）引擎调试收敛**：四类 bug 修复——fp16_of_6b 重写（12 位 concat 整体错位+尾数自定宽截断）、get_sm6 的 jj 3 位加法回绕、dot32 的 sx 用组合 x_sum（消费拍已换块，改 x_sum_r 寄存）、integer_sx 零扩展（13 位片段赋 21 位 signed 寄存器需 $signed() 重解释）。**GATEUP-VERIFIED 76 行**（含 (12,2,256)/(12,4,512)/(12,2,4864) 三个随机配置；Q5/Q8 主路径 max_abs 与 v5 一致）。调试方法：逐拍 dot32 内部跟踪 + 逐块 scaler 输入与 Python 从包重算期望值对照（dot 384/384 一致后锁定 sx 与符号扩展）。教训：Verilog concat/移位自定宽与 part-select 无符号是本次全部四类 bug 的共同根源。
- runtime/callback：gateup_matvec（fmt12 单矩阵派发，缓存按格式标签区分，12 层 Q4_K 缓存 29.4MB，总 179MB<192MB）；gateup_down_compute（Q8_0 量化+派发+verify 下 Q4_K vec_dot 参考）；图分支对 Q4_K [4864,896] 的 Down 包装为 custom3_shape [896,1]（Q6_K 层保持 CPU）；test_model.sh 预期 553→829 次调用（+276 Down）、DOWN-VERIFY 276。
- 硬件 quad-2017-v6 已验收：WNS+0.114/WHS+0.054 @83.33MHz、LUT 78.36%（fmt12 增 ~16k：18 字乒乓×2+双项 scaler+解码组合逻辑）、BRAM 84 不变；bit d2b4a33fb7677c9b5e1c304107d79500fb60ae7d182bb9fd68aacf57d76d16bb、HWH 28133688a9542acdfb5407c592eaf03967d842e05551e479077f74473730dd66；64 项网表+33 项 HWH 检查过、DRC 无 Error/Critical。
- **板端部署挂起**：COM13 串口消失（USB 枚举丢失）、169.254.32.1 ping 半丢包且 TCP/22 无法建立（跨会话板卡/线缆状态变化）；全部产物与逐步命令见 compat/gateup2017/DEPLOY-v6.md，连接恢复后可一次执行。未验证项：板端 829 调用、DOWN-VERIFY、tps 对比（预期：Down 派发节省约 250~340ms/步，tps 0.75→0.85~0.9，估算）。



### full-source 阶段1 板端联调（2026-10-31，进行中）

- 板端连接恢复：板卡重启后 eth0 持久双地址 192.168.2.99/24 + 169.254.32.99/16（SD 镜像网络配置含 APIPA），SSH 169.254.32.99 指纹校验通过；COM13 重枚举为 COM11 但控制台无输出（未再依赖）。开机 13 分钟、锁空闲、PYNQ/XRT 正常。
- 部署联调四轮，逐层修复：matvec 包头格式字节错误（引擎 BAD 态，DMA 状态转储定位）；回调 rows=dst->ne[1]=1 静默拒绝；校验参考 Q4_K vec_dot 配 Q8_0 错误配对（改 to_float×原始 F32 输入）；**激活 scale 缺失（498× 偏差）→ dx3 三因子 scaler**。
- 关键教训：bundle.py 不运行 prepare_software.py（修复三轮未上板）；碎片化字符串补丁不可靠（scaler 文件曾成嵌合体，整文件重写解决）；引擎 BAD 态后必须整片重载（融合调用也会随后卡死）。
- 当前：fmt12 单超块行 (12,2,256) 板级路径就绪；(12,4,512) row0 有 2^63 累加饱和待查；fmt12 配置摘离验收向量（Q5/Q8 回归绿）；v7 bit 待 dx3 收敛后构建。

### 板端回滚 v5、恢复可用（2026-10-31，本轮实测）

- 用户决策回滚到 v5 可用状态。方法：git 220a6fe 的 v5 软件侧源码（runtime/callback/prepare_software/test_model）临时恢复 → prepare_software+bundle → 上板重编译 → **二进制哈希精确还原 574fb6ee**（源码级可复现构建验证）→ 重载 v5 overlay（bit 91bbc865）→ 五模式测试组 **GATEUP-NUMERIC-AND-REPEAT-PASS**。
- 板端当前状态：**v5 融合配置可用**——fused 30760.72ms=0.7474 tps、复测 30914.35ms=0.7434；CPU 0.5410/0.5411；GATEUP-STATS calls=553 ✓；TEXT-PARITY-FAIL 为既有已知限制。手动入口 `cd /home/xilinx/ax7020-gateup2017 && bash run.sh`。证据 docs/fusion-speedup2017/v5-rollback/。
- full_source 分支的 dx3 WIP 完整保留（compat 已 git checkout 还原到 fe188ab 状态，工作区干净）；回滚所用临时覆盖未提交。恢复推进时的入口：DEBUG-NOTES-fmt12.md（(12,4,512) 2^63 饱和待查）→ dx3 收敛 → v7 构建 → 部署。

### 2026-10-31 原 SD 卡 SSH 恢复（本轮验证）

- 用户确认换回原 SD 卡。COM11/115200 收到 xilinx@pynq shell；电脑物理网口 Up/100Mbps，板端 eth0 carrier=1。板卡原静态 IPv4 与电脑 APIPA 地址不在同一子网；此前临时辅助地址已消失。
- 板端 ssh 服务 active，IPv4/IPv6 的 TCP 22 均监听；经串口核对 ED25519 指纹与原 SD 卡历史身份一致。
- 经串口 sudo 在 eth0 恢复与电脑同网段的临时辅助 IPv4，保留原静态地址。通过指纹校验后 SSH 密码认证成功，hostname/whoami/uptime/ip/ssh 查询 exit 0。具体连接地址留在当前会话，不作为项目常量。
- 未修改持久网络配置，未重启、加载 overlay 或运行模型；串口和 SSH 会话均已关闭。本次仅恢复连通性；临时地址在重启后消失，持久方案可将电脑有线网口配置为板卡原静态地址的同子网地址。

### 2026-10-31 模型换型与不量化可行性分析（ZCode 只读分析会话；重追加）

- **协作警示**：本会话曾于 2026-10-31 在任务表与第 8 节追加 `qwen15b-feasibility` 条目，随后被另一并行会话用其缓存版本整体覆盖丢失（该内容未进过任何提交）。写本文前请重新读取最新文件，避免再发生 lost-update。
- 背景：用户问（a）0.5B 换 1.5B 是否可行、能否达 5 tps；（b）0.5B 完全不量化 DDR3 够不够。本轮纯文档分析，无板端/构建操作；结论依据 `accel/docs/更大模型评估.md`（2026-10-25 板端实测：可用 872~873MB、SD 顺序读 11.4MB/s、compute buffer 公式、783MB 极限预算）与 `docs/pl-roadmap-20261030/PLAN.md` §6（0.5B 全卸载带宽上限 ≈5.0 tps = 1.96GB/s ÷ 392MB/token）。
- 结论 a〔历史记录+推算〕：**1.5B 换型不可行**。内存墙：Q4_K_M 940.4/1065.6MB、Q3_K_M 786.0/881.6MB 均超 783MB 极限预算；IQ3_XS/Q2_K 能进内存但两代引擎（Q4_K/Q5_0+Q8_0）不支持该格式、CPU IQ kernel 无 NEON（推断 0.1~0.2 tok/s）。带宽墙：1.5B decode 每 token 实读 ≈787MB〔推算〕，5 tps 需 3.9GB/s > 实测聚合 1.96GB/s（亦近 DDR3-1066 32-bit 理论峰 4.26 的 92%），单流无权重重用；全模型完美流式上限仅 ~2.5~3.4 tok/s 且前提（进内存）不成立。融合 runtime 若接 1.5B，gate/up 打包缓存约 0.55GiB〔推算：0.5B 实测 149.625MiB × 3.86〕更装不下。5 tps 是 0.5B 全卸载口径的带宽上限，与 1.5B 不兼容。
- 结论 b〔源码检查+推算〕：**0.5B 不量化（F16）不够**。已核实当前部署文件 embed/lm_head 共享单张量（`token_embd.weight` Q8_0 144.7MB，无独立 output.weight），参数 0.494B → F16 文件 ≈988MB，超 783MB 极限预算 ~26%，且已超空载可用 872MB（未含任何运行缓冲）；F32 ≈1.98GB 更不可能。装不下即触发 SD 11.4MB/s 抖页（每 token 至少 +18s）。两代 PL 引擎均无 F16 权重路径；CPU F16 decode 推断 ~0.2 tok/s。能落地的精度上限：全 Q8_0 ≈527MB / 全 Q6_K ≈405MB（ctx128/b64 可装，推断 CPU ~0.4 tok/s）；F16 需换 1.5~2GB RAM 平台。
- 未验证项：以上未在板卡复测；内存/带宽数字为 2026-10-25 历史实测。


### AX7020 Resident 1.202 发布交接

- 本分支收录 7168 行分块、384 MiB CMA 和 `--poll 50` 的常驻版。板测依据与复现入口在 `compat/head2017/BOARD-RESULT.md` 和 `RESIDENT.md`。
- 推理和硬件产物按文档构建，原始权重、日志和本机文件未入库。数值结论限同前缀对照与该测试提示词。

### 2026-11-26 双时钟 Resident 实现与板测

- 实验分支 `codex/axi-dual-clock` 从 Resident 1.202 的发布分支建立。四路 HP/DMA 接 FCLK0，各 lane 的收发经独立时钟 FIFO 进入 FCLK1。增加整数归约和 FP16 缩放流水。代码、重建与板测复现见 `compat/head2017/dual_clock/`。
- 本轮 XSim 检查 4102 个输入 beat、38 行混合协议、TLAST 与反压，缩放另用 512 行、2281 块的整数参考对拍。125/200 MHz 的新版计算域 WNS -4.661 ns，142.857 和 111.111 MHz 也未收敛。125/100 MHz 用原布线重新约束并配套低频 HWH 后通过 WNS +0.256 ns、WHS +0.025 ns。
- 板上 125/100 MHz 读回通过，8 个真实 Gate/Up 加 100 次零输入和 3 个 Head 用例通过。固定前缀的 24 步全词表 logits 位级一致，同轮两对短提示合并解码 1.144→1.179 tok/s，Head 1.837→2.067 GB/s。125/83.33 MHz 也通过同样功能测试。原 Resident overlay 已恢复，DMA 锁可获取。
- 实测记录见分支 `compat/head2017/dual_clock/RESULT.md`。本地独立工作树的 `build/dual-board/` 和 `build/head2017/dual-clock-*/` 保留详细日志。200 MHz 的优化仍受包头乘法、Head 选数至 DSP、SiLU 乘法器舍入限制，多列与长提示性能待验。

### 2026-11-26 单会话解码的 Cortex-A9 NEON 优化

- 独立分支 `codex/single-chat-neon`，实现 ARMv7 Q4_K/Q6_K/Q5_0 点积并保留原浮点累加顺序；使用板端既有工具链重新链接，现有 GGUF、RTL 和原 Resident 二进制不变。真实形状合成矩阵的结果逐位一致，三格式分别节省约 14%、15% 和 28% 的计算时间。
- 同板同条件 ABBA，各侧合计 46 个解码步。原 overlay、上下文 256 为 1.158→1.263 tok/s（+9.1%）；双时钟 125/100 MHz、上下文 1024 为 1.169→1.296 tok/s（+10.8%，每 token 少 83.3 ms）。两组都对拍固定前缀 24 步、全 151936 logits 逐位一致。通过的运行全部 Gate/Up 常驻、Head 全 PL。初次原 overlay 1024 有 5 层回退，作为未通过的尝试保留，不计入 A/B。
- 新独立入口 `~/ax7020-a9-decode/run_a9.sh` 默认 1024 和双时钟；已验证启动链路，随后恢复原 overlay。详细结果与复现见 `compat/head2017/a9_decode/README.md`，本机证据为该工作树的 `build/dual-board/a9-*`。本轮没有变更硬件实现或原启动入口，分支留在本地。
