# fmt12（Q4_K）调试记录（2026-10-30/31，WIP）

状态：**fmt12 数值路径未通过仿真，运行时未接入（安全）**。Q5/Q8 主路径回归全绿（GATEUP-AXIS-PASS rows=68 与 v5 一致）。本文记录已确认的修复与待查线索，供下一会话续作。

## 已确认并修复

1. **scale 切片偏移**：get_sm6 的输入应为 `feed_w[127:32]`（12 字节 scales 区），最初误用 `[127:16]`（混入 dmin）→ 已修。
2. **fp16_of_6b 指数位宽**：`4'd15+{1'b0,e}` 是 4 位加法，n≥2 时指数场溢出为 0 → 改 `5'd15+{2'd0,e}` 已修。
3. **fp16_of_6b 尾数 concat 截断**（已定位、**待重写验证**）：`{1'b0, expo, (n<<(10-{1'b0,e}))}` 中移位结果按 n 的 6 位自定宽截断，非 2 的幂的 n（如 3）尾数被清零 → fp16 值错。正确写法：先赋给 10 位 reg（`mant = n << (10-{1'b0,e});`，赋值上下文按 LHS 位宽计算）再拼。
4. **打包/解包不一致**（向量侧）：get_sm6 的高 2 位来自 `(sc[j+4]>>4)&3`（位 [5:4]），最初生成器误用 `sc[j+4]&3`（位 [1:0]）→ 已修（roundtrip 2000×16 全对）。

## 已知值测试（build/gateup2017/simdbg12/）

输入：x=1、q=1、d=dmin=1.0、sc=2、m∈{0,3}，K=256、rows=1×2。期望 512 与 −256。
实测：case A=0.015625（=512×2^-15，**系统性 2^-15 偏差**）、case B=0。

## 待查线索（下一会话从这里开始）

- case A 的 2^-15 偏差：shift=ew+ex−2 链路或 to_fp32 的指数在 fmt12 数值域的行为；建议 dump `scaler.accumulator`、`shift`、`highest` 全程（tb_dbg12c 骨架已建好，注意 hierarchical 引用在该版 TB 中未输出，需检查作用域）。
- case B 恒为 0：sx/term2 链路（dot32 的 s_acc、scaler 的 integer_sx/coefficient2/shift2/negate2）。
- 工程教训：改 compat/rtl 后必须先 `python compat/gateup2017/prepare.py` 再做 build/rtl 的直接仿真，否则测的是陈旧副本（本次浪费一轮）；本仓库 shell 的 heredoc 会预展开转义/破坏引号，一律用 Write 工具落补丁脚本。

## 恢复步骤

1. 修 fp16_of_6b（见上）并解决 2^-15/case B 两个数值问题。
2. vectors.py 恢复 3 个 fmt12 配置（注释保留在文件中）。
3. verify.ps1 全绿 → runtime/callback 接入（设计已定：`ggml_map_custom3_shape(ctx,cur,down,cur,down_compute,1,nullptr,896,1)`，条件 `down->type==Q4_K && ne==[4864,896]`；runtime 加 `gateup_matvec`，缓存 12 层 ×2.45MB ≤ 192MB 余量内）。
4. 走构建→时序→板测链；Q6_K（format 14）与 Attention/LM Head 阶段见 docs/pl-roadmap-20261030/PLAN.md。
