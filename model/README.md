# Fixed-Point FlashAttention 参考模型

这个工程用于建模和验证一个 FlashAttention-style 硬件加速器的
fixed-point datapath。它不是 RTL，也不是简单的 FP32 attention demo。
工程目标是提供一个结构清晰、可配置、可测试、可用于后续 RTL 对齐的
Python 参考模型。

## 工程结构

```text
flash_attn_fixed_model/
|-- README.md
|-- pyproject.toml
|-- experiment_config.json
|-- run_experiment.py
|-- flash_attn_fixed/
|   |-- __init__.py
|   |-- experiment_config.py
|   |-- fixed_format.py
|   |-- fixed_ops.py
|   |-- golden_attention.py
|   |-- exp_pwl.py
|   |-- hardware_config.py
|   |-- hardware_attention.py
|   |-- debug_dump.py
|   |-- stats.py
|   `-- data_gen.py
`-- tests/
    |-- test_fixed_format.py
    |-- test_exp_pwl.py
    |-- test_golden_attention.py
    |-- test_experiment_config.py
    `-- test_hardware_attention.py
```

## 两类模型

`golden_attention_fp32` 是公式级 FP32 golden model。它会把 raw Q/K/V 按
fixed-point 格式反量化为 float，然后直接计算：

```text
O = softmax(QK^T / sqrt(d) + mask) V
```

golden model 可以显式保存完整 score/probability matrix，用作数学参考。

`fixed_point_flash_attention` 是 hardware-like fixed-point model。它使用
block-wise / tiled FlashAttention 流程、整数 fixed-point 运算、PWL exp、
causal mask，以及 online softmax 状态 `old_m / old_l / old_o`。这个模型不
调用 FP32 softmax，也不会显式保存完整 attention matrix。

需要这两类模型的原因是：FP32 golden model 定义数学目标，fixed-point model
定义硬件 datapath 行为。二者的误差就是当前定点格式、PWL exp 和量化策略带来的
整体误差。

## 默认配置文件

工程默认由 [experiment_config.json](experiment_config.json) 驱动。通常只需要改
这个 JSON 文件，不需要改 Python 代码。

默认 baseline 配置为：

```json
{
  "len_seq": 256,
  "head_dim": 64,
  "Br": 16,
  "Bc": 16,
  "causal": true
}
```

debug log 默认打开：

```json
"debug": {
  "model_debug_print": false,
  "dump_debug": true,
  "debug_dir": "debug_logs/run_001",
  "dump_hex": true
}
```

默认不在命令行打印 summary：

```json
"report": {
  "print_summary": false
}
```

如果想在命令行看到格式、memory 和误差信息，把 `print_summary` 改成 `true`。

## Q/K/V/O 默认格式

默认 Q/K/V/O 都是 signed Q8.8：

```text
total_bits = 16
frac_bits  = 8
raw range  = [-32768, 32767]
real range = [-128.0, 127.99609375]
```

所有 fixed-point 格式都在 `experiment_config.json` 的 `hardware.formats`
中配置。

## 默认 Datapath 格式

| variable | default format |
| --- | --- |
| Q/K/V/O | signed Q8.8 |
| Q*K product | signed Q16.16 |
| S | signed Q22.16 |
| S_scaled, local_m, new_m, N | signed Q22.16 |
| log2e | signed Q2.16 |
| b, P, exp output | UQ1.23 |
| local_l | UQ5.23 |
| old_l, new_l | UQ9.23 |
| local_o | signed Q12.23 |
| old_o, new_o | signed Q16.23 |

## Config 中每个格式字段的含义

这些字段都在 `experiment_config.json` 的 `hardware.formats` 中配置。每个字段
都会被 fixed-point hardware-like model、debug dump 和误差统计直接使用。

### q_fmt

`q_fmt` 是输入 Q 矩阵的格式。

默认：

```text
signed Q8.8
total_bits = 16
frac_bits  = 8
```

用途：

- 随机生成 Q 时，float Q 会按 `q_fmt` 量化成 raw int。
- FP32 golden model 会按 `q_fmt` 把 Q raw int 反量化为 float。
- hardware-like model 中 QK dot-product 直接使用 Q raw int。
- debug log 中 `input_q_raw.csv` 的 hex 宽度来自 `q_fmt.total_bits`。

### k_fmt

`k_fmt` 是输入 K 矩阵的格式。

默认：

```text
signed Q8.8
total_bits = 16
frac_bits  = 8
```

用途：

- 随机生成 K 时，float K 会按 `k_fmt` 量化成 raw int。
- FP32 golden model 会按 `k_fmt` 把 K raw int 反量化为 float。
- hardware-like model 中 QK dot-product 直接使用 K raw int。
- debug log 中 `input_k_raw.csv` 的 hex 宽度来自 `k_fmt.total_bits`。

### v_fmt

`v_fmt` 是输入 V 矩阵的格式。

默认：

```text
signed Q8.8
total_bits = 16
frac_bits  = 8
```

用途：

- 随机生成 V 时，float V 会按 `v_fmt` 量化成 raw int。
- FP32 golden model 会按 `v_fmt` 把 V raw int 反量化为 float。
- hardware-like model 中 `local_o = P * V` 直接使用 V raw int。
- `P * V` 后需要右移 `v_fmt.frac_bits` 位，使结果从 Q9.31 对齐到 Q*.23。
- debug log 中 `input_v_raw.csv` 的 hex 宽度来自 `v_fmt.total_bits`。

### out_fmt

`out_fmt` 是最终输出 O 的格式。

默认：

```text
signed Q8.8
total_bits = 16
frac_bits  = 8
```

用途：

- 最终 `O = old_o / old_l` 后量化到 `out_fmt`。
- 归一化时分子会左移 `out_fmt.frac_bits` 位。
- 误差统计时，fixed-point 输出会按 `out_fmt` 反量化为 float。
- debug log 中 `output_o_raw.csv` 和 `q_block_output_raw.csv` 的 hex 宽度来自
  `out_fmt.total_bits`。

### prod_qk_fmt

`prod_qk_fmt` 表示单个 `Q * K` 乘积的理论格式。

默认：

```text
signed Q16.16
total_bits = 32
frac_bits  = 16
```

用途：

- Q8.8 与 K8.8 相乘后，小数位相加得到 16 个 frac bits。
- 当前代码直接用 Python int 计算乘积，不单独把每个乘积 saturate 到
  `prod_qk_fmt`。
- 这个字段用于清晰描述 datapath 中单项乘法的格式，也方便后续 RTL 拆 pipeline
  时对齐单个 multiplier 输出。

### s_fmt

`s_fmt` 是 `S = QK^T` 累加完成后的格式。

默认：

```text
signed Q22.16
total_bits = 38
frac_bits  = 16
```

用途：

- `head_dim` 个 QK 乘积累加后得到 `S_raw`。
- 累加完成后会 saturate 到 `s_fmt`。
- debug log 中 `S.csv` 的 hex 宽度来自 `s_fmt.total_bits`。

### score_fmt

`score_fmt` 是 softmax score 相关变量的格式。

默认：

```text
signed Q22.16
total_bits = 38
frac_bits  = 16
```

用途：

- `S_scaled = S / sqrt(d)` saturate 到 `score_fmt`。
- `N = S_scaled - new_m` saturate 到 `score_fmt`。
- `exp_pwl_fixed` 的输入 `x_int` 按 `score_fmt` 解释。
- `exp_clamp_min_real` 会按 `score_fmt.frac_bits` 量化成 clamp 阈值。
- debug log 中 `S_scaled.csv` 和 `N.csv` 的 hex 宽度来自 `score_fmt.total_bits`。

### m_fmt

`m_fmt` 是 online softmax 中 max 状态的格式。

默认：

```text
signed Q22.16
total_bits = 38
frac_bits  = 16
```

用途：

- `local_m`、`old_m`、`new_m` 都使用这个格式。
- 当前默认下 `m_fmt` 和 `score_fmt` 相同，因为 max 直接来自 score。
- debug log 中 `local_m.csv`、`old_m_before.csv`、`new_m.csv` 的 hex 宽度来自
  `m_fmt.total_bits`。

### log2e_fmt

`log2e_fmt` 是 PWL exp 内部常数 `log2(e)` 的格式。

默认：

```text
signed Q2.16
total_bits = 18
frac_bits  = 16
raw value  = 94548
```

用途：

- `exp(x) = 2^(x * log2(e))` 中的 `log2(e)` 使用 `log2e_fmt`。
- `z_mul = x * log2e` 后，右移 `log2e_fmt.frac_bits` 位。
- 注意：`log2e` 不使用 Q22.16，而是独立使用 signed Q2.16。

### exp_fmt

`exp_fmt` 是 PWL exp 输出、`P` 和 `b` 的格式。

默认：

```text
UQ1.23
total_bits = 24
frac_bits  = 23
```

用途：

- `b = exp(old_m - new_m)` 输出为 `exp_fmt`。
- `P = exp(N)` 输出为 `exp_fmt`。
- `local_l = rowsum(P)` 以 `exp_fmt` 的 frac bits 为基础累加。
- `old_l * b` 和 `old_o * b` 后会右移 `exp_fmt.frac_bits` 位。
- debug log 中 `b.csv`、`P.csv` 的 hex 宽度来自 `exp_fmt.total_bits`。

### locall_fmt

`locall_fmt` 是当前 K/V tile 内 `local_l = rowsum(P)` 的格式。

默认：

```text
UQ5.23
total_bits = 28
frac_bits  = 23
```

用途：

- `P` 是 UQ1.23，默认 `Bc=16`，一行最多累加 16 个 P。
- 因此默认使用 UQ5.23 表示当前 tile 的 denominator 局部和。
- debug log 中 `local_l.csv` 的 hex 宽度来自 `locall_fmt.total_bits`。

### l_fmt

`l_fmt` 是 online softmax 全局 denominator 状态的格式。

默认：

```text
UQ9.23
total_bits = 32
frac_bits  = 23
```

用途：

- `old_l` 和 `new_l` 使用 `l_fmt`。
- `new_l = old_l * b + local_l` 最终 saturate 到 `l_fmt`。
- 默认 `LEN=256`，完整 denominator 最大量级接近 256，因此使用 UQ9.23。
- debug log 中 `old_l_before.csv`、`new_l.csv` 的 hex 宽度来自
  `l_fmt.total_bits`。

### localo_fmt

`localo_fmt` 是当前 K/V tile 内 `local_o = P * V` 局部累加的格式。

默认：

```text
signed Q12.23
total_bits = 35
frac_bits  = 23
```

用途：

- `P: UQ1.23` 与 `V: signed Q8.8` 相乘后得到 Q9.31。
- 右移 `v_fmt.frac_bits` 位后对齐到 23 个 frac bits。
- 当前 tile 内累加 Bc 个 `P * V` 结果后 saturate 到 `localo_fmt`。
- debug log 中 `local_o.csv` 的 hex 宽度来自 `localo_fmt.total_bits`。

### oacc_fmt

`oacc_fmt` 是 online softmax 全局 numerator 状态的格式。

默认：

```text
signed Q16.23
total_bits = 39
frac_bits  = 23
```

用途：

- `old_o` 和 `new_o` 使用 `oacc_fmt`。
- `new_o = old_o * b + local_o` 最终 saturate 到 `oacc_fmt`。
- 最终归一化 `O = old_o / old_l` 的分子来自 `oacc_fmt`。
- debug log 中 `old_o_before.csv`、`new_o.csv` 的 hex 宽度来自
  `oacc_fmt.total_bits`。

| step | operation                      | default output format |
| ---- | ------------------------------ | --------------------- |
| 1    | S = Q * K^T                    | signed Q22.16         |
| 2    | S_scaled = S / sqrt(d) = S / 8 | signed Q22.16         |
| 3    | local_m = rowmax(S_scaled)     | signed Q22.16         |
| 4    | new_m = max(local_m, old_m)    | signed Q22.16         |
| 5    | b = exp(old_m - new_m)         | UQ1.23                |
| 6    | N = S_scaled - new_m           | signed Q22.16         |
| 7    | P = exp(N)                     | UQ1.23                |
| 8    | local_l = rowsum(P)            | UQ5.23                |
| 9    | new_l = old_l * b + local_l    | UQ9.23                |
| 10   | local_o = P * V                | signed Q12.23         |
| 11   | new_o = old_o * b + local_o    | signed Q16.23         |
| 12   | O = old_o / old_l              | signed Q8.8           |

## 具体量化说明

本工程中，FP32 golden model 只在输入处把 raw Q/K/V 反量化为 float，后续都按
数学公式计算，不模拟硬件量化。

fixed-point hardware-like model 则严格使用 raw integer 表示中间变量。每一次
乘法后的 frac bits 对齐、右移 rounding、目标格式 saturation，都是显式执行的。

### 1. 输入 Q/K/V 量化

随机数据生成时，先生成 float，再量化为 raw integer：

```text
raw = round(real_value * 2^frac_bits)
raw = saturate(raw, target_format)
```

默认：

```text
Q/K/V real -> signed Q8.8 raw int
frac_bits = 8
scale = 256
```

例如：

```text
1.25 -> round(1.25 * 256) = 320
-0.5 -> round(-0.5 * 256) = -128
```

### 2. QK 乘法量化

每一项乘法：

```text
q_raw: signed Q8.8
k_raw: signed Q8.8
q_raw * k_raw: signed Q16.16
```

因为两个输入各有 8 个小数位，所以乘积有 16 个小数位。

代码中不会把每一项乘积先转成 float，而是直接使用 Python int：

```text
prod_qk_raw = q_raw * k_raw
```

### 3. S = rowsum(QK) 累加量化

对 head_dim 个乘积做整数累加：

```text
S_raw = sum(q_raw[t] * k_raw[t])
```

默认 `head_dim=64`，累加结果仍然保留 16 个小数位：

```text
S_raw: signed Q22.16
```

累加完成后会 saturate 到 `s_fmt`：

```text
S_raw = sat(S_raw, signed Q22.16)
```

### 4. S_scaled = S / sqrt(d) 量化

baseline 中：

```text
d = 64
sqrt(d) = 8
```

所以缩放通过右移 3 位实现：

```text
S_scaled = round_shift_right_signed(S_raw, 3)
S_scaled = sat(S_scaled, signed Q22.16)
```

注意：这里不是直接截断，而是 signed symmetric rounding。输出仍然是
signed Q22.16，只是数值被除以 8。

### 5. rowmax / local_m / new_m 量化

`local_m` 是当前 tile 中 valid score 的最大值：

```text
local_m = max(valid S_scaled)
```

它不需要重新缩放，因为输入 `S_scaled` 已经是 signed Q22.16：

```text
local_m: signed Q22.16
new_m:   signed Q22.16
old_m:   signed Q22.16
```

causal mask 中 invalid 的位置不会参与 `rowmax`。

### 6. b = exp(old_m - new_m) 量化

先做差：

```text
a = old_m - new_m
a: signed Q22.16
```

理论上 `a <= 0`。随后输入 PWL exp：

```text
b = exp_pwl_fixed(a)
b: UQ1.23
```

`b` 表示旧 softmax 状态在新最大值下的缩放因子。

### 7. N = S_scaled - new_m 量化

对每个 valid score：

```text
N = S_scaled - new_m
N = sat(N, signed Q22.16)
```

理论上 `N <= 0`。invalid mask 位置不进入 exp，debug log 中默认把对应 `N`
写成 0，避免 RTL 对齐时误解。

### 8. P = exp(N) 量化

`N` 输入 PWL exp：

```text
N: signed Q22.16
P: UQ1.23
```

输出 `P` 是 fixed-point probability numerator，不是最终归一化概率。invalid
位置强制：

```text
P = 0
```

### 9. log2(e) 常数量化

PWL exp 内部使用：

```text
exp(x) = 2^(x * log2(e))
```

默认：

```text
log2(e) real = 1.4426950408889634
log2e raw    = 94548
format       = signed Q2.16
```

注意：`log2e` 不使用 Q22.16，而是独立使用 `log2e_fmt`，默认 signed Q2.16。

### 10. z = x * log2(e) 量化

PWL exp 中：

```text
x:     signed Q22.16
log2e: signed Q2.16
z_mul = x * log2e
```

乘积格式等效为：

```text
Q22.16 * Q2.16 -> Q24.32
```

然后右移 16 位回到 16 个小数位：

```text
z_pre = round_shift_right_signed(z_mul, 16)
z_int = sat(z_pre, signed Q22.16)
```

### 11. 2^(-f) PWL 系数量化

`2^(-f)` 使用 8 段 uniform PWL：

```text
intercept[k]: UQ1.23
slope[k]:     signed Q1.23
delta:        UQ0.16
```

乘法：

```text
slope * delta -> signed Q1.39
```

右移 16 位后变成 signed Q1.23：

```text
prod_q23 = round_shift_right_signed(slope * delta, 16)
two_minus_f = intercept[k] + prod_q23
two_minus_f = clamp(two_minus_f, 0, 1.0)
```

最后通过右移 `I` 位实现 `2^(-I)`：

```text
exp(x) = two_minus_f >> I
output: UQ1.23
```

### 12. local_l = rowsum(P) 量化

`P` 的格式是 UQ1.23，累加 Bc 个元素：

```text
local_l = sum(P)
local_l: UQ5.23
```

默认 `Bc=16`，最大行和接近 16，因此默认使用 UQ5.23。累加后 saturate 到
`locall_fmt`。

### 13. new_l = old_l * b + local_l 量化

旧 denominator 缩放：

```text
old_l: UQ9.23
b:     UQ1.23
old_l * b -> UQ10.46
```

右移 23 位回到 23 个小数位：

```text
oldl_scaled = round_shift_right_unsigned(old_l * b, 23)
oldl_scaled: UQ9.23
```

然后加上当前 tile 的 `local_l`：

```text
new_l = oldl_scaled + local_l
new_l = sat(new_l, UQ9.23)
```

如果当前 row 是第一次出现 valid tile，则直接：

```text
new_l = zero_extend(local_l)
```

### 14. local_o = P * V 量化

每个 value 乘法：

```text
P: UQ1.23
V: signed Q8.8
P * V -> signed Q9.31
```

为了和 `local_o` 的 23 个小数位对齐，需要右移 8 位：

```text
prod_pv_q23 = round_shift_right_signed(P * V, 8)
```

然后对当前 K/V tile 内的 Bc 个元素累加：

```text
local_o = sum(prod_pv_q23)
local_o = sat(local_o, signed Q12.23)
```

### 15. new_o = old_o * b + local_o 量化

旧 numerator 缩放：

```text
old_o: signed Q16.23
b:     UQ1.23
old_o * b -> signed Q17.46
```

右移 23 位回到 23 个小数位：

```text
oldO_scaled = round_shift_right_signed(old_o * b, 23)
oldO_scaled: signed Q16.23
```

然后加上当前 tile 的 `local_o`：

```text
new_o = oldO_scaled + local_o
new_o = sat(new_o, signed Q16.23)
```

如果当前 row 是第一次出现 valid tile，则直接：

```text
new_o = sign_extend(local_o)
```

### 16. 最终 O = old_o / old_l 量化

所有 K/V block 完成后：

```text
old_o: signed Q16.23
old_l: UQ9.23
```

二者小数位都是 23，相除时小数位抵消。最终输出需要 signed Q8.8，所以分子先左移
8 位：

```text
abs_num = abs(old_o) << 8
q_abs = round(abs_num / old_l)
q = +/- q_abs
O = sat(q, signed Q8.8)
```

如果 `old_l == 0`，输出 0。

### 17. 输出反量化

误差统计和 debug float 输出中，会把 raw Q8.8 反量化为 float：

```text
real_value = raw / 2^frac_bits
```

默认输出：

```text
O_float = O_raw / 256
```

### 18. Debug hex 量化显示

当 `debug.dump_hex = true` 时，CSV 中会额外输出 `hex` 列。hex 不是重新量化，
而是把 raw integer 按变量自己的 `total_bits` 显示成补码：

```text
Q22.16  -> 38-bit two's complement hex
UQ1.23  -> 24-bit unsigned hex
Q16.23  -> 39-bit two's complement hex
```

这用于 RTL 波形或仿真 dump 的逐项对齐。

## EXP PWL 流程

`exp_pwl_fixed` 输入为 signed Q22.16，输出为 UQ1.23。该单元同时用于：

```text
b = exp(old_m - new_m)
P = exp(S_scaled - new_m)
```

计算流程为：

```text
x: signed Q22.16
z = x * log2(e), log2e uses signed Q2.16, value 94548
z is saturated to signed Q22.16
t = -z
I = integer(t)
f = fraction(t), UQ0.16
2^(-f) is approximated by 8-piece PWL
2^(-I) is implemented by right shift
exp(x) output is UQ1.23
```

默认 `exp_clamp_min_real = -16.0`。当 `x >= 0` 时输出 1.0；当 `x <= -16`
时输出 0。

## Online Softmax 状态

每个 query row 独立维护：

- `old_m`：当前 row 的 running max，格式 signed Q22.16。
- `old_l`：当前 row 的 running denominator，格式 UQ9.23。
- `old_o`：当前 row 的未归一化输出累加值，格式 signed Q16.23。

每个 row 都有独立的 `has_state` 标志。causal mask 中 invalid 的位置不会参与
rowmax，也不会进入 exp。

## Block-Wise FlashAttention 流程

每个 Q block 依次遍历 K/V block：

1. 计算整数 `S = QK^T`。
2. 通过右移实现 `S / sqrt(d)`。
3. 生成 causal valid mask。
4. 对 valid score 计算 `local_m`。
5. 计算 `new_m`，并用 `b = exp(old_m - new_m)` 缩放旧状态。
6. 计算 `N = S_scaled - new_m`。
7. 计算 `P = exp(N)`。
8. 计算 `local_l = rowsum(P)`。
9. 计算 `local_o = P * V`。
10. 更新 `old_l` 和 `old_o`。
11. 所有 K/V block 完成后计算 `O = old_o / old_l`，输出 signed Q8.8。

默认 baseline 中 `head_dim=64`，所以 `sqrt(d)=8`，缩放等价于右移 3 位。
测试中也支持 `head_dim=4` 这类 `sqrt(d)` 为 2 的幂的尺寸。

## 如何运行实验

进入工程目录：

```powershell
cd D:\wangyan77\FlashAttention\flash_attention_python\flash_attn_fixed_model
```

直接运行：

```powershell
python run_experiment.py
```

脚本会默认读取：

```text
experiment_config.json
```

如果想使用另一份配置：

```powershell
python run_experiment.py --config experiment_config_alt.json
```

## 如何查看结果

默认结果写入：

```text
debug_logs/run_001/
```

误差结果在：

```text
debug_logs/run_001/error_summary.json
```

示例：

```json
{
  "mean_abs_error": 0.0009777933981246995,
  "max_abs_error": 0.002107666533727598,
  "rmse": 0.0011304317313358637,
  "meets_competition_target": true
}
```

默认目标为：

```text
mean_abs_error <= 0.03
max_abs_error <= 0.10
```

## Debug Log 目录

当 `debug.dump_debug = true` 时，会输出完整中间变量：

```text
debug_logs/run_001/
|-- config.json
|-- input_q_raw.csv
|-- input_k_raw.csv
|-- input_v_raw.csv
|-- input_q_float.csv
|-- input_k_float.csv
|-- input_v_float.csv
|-- output_o_raw.csv
|-- output_o_float.csv
|-- golden_o_float.csv
|-- error_summary.json
`-- q_block_000/
    |-- q_block_info.json
    |-- q_block_output_raw.csv
    |-- q_block_output_float.csv
    `-- kv_round_000/
        |-- round_info.json
        |-- S.csv
        |-- S_scaled.csv
        |-- valid_mask.csv
        |-- local_m.csv
        |-- old_m_before.csv
        |-- new_m.csv
        |-- b.csv
        |-- N.csv
        |-- P.csv
        |-- local_l.csv
        |-- old_l_before.csv
        |-- new_l.csv
        |-- local_o.csv
        |-- old_o_before.csv
        `-- new_o.csv
```

CSV 默认保存 raw integer。如果 `debug.dump_hex = true`，还会增加 `hex` 列。
hex 按每个变量自己的 `total_bits` 输出补码值，方便和 RTL 波形对齐。

如果某个 K/V tile 因 causal mask 完全在未来位置而被跳过，会记录在
`q_block_info.json` 的 `skipped_kv_blocks` 中。

## 如何修改 Fixed-Point 格式

直接修改 `experiment_config.json` 中的 `hardware.formats`。每个格式都有：

```json
"score_fmt": {
  "name": "Q22.16",
  "signed": true,
  "total_bits": 38,
  "frac_bits": 16
}
```

可以修改的格式包括：

```text
q_fmt
k_fmt
v_fmt
out_fmt
prod_qk_fmt
s_fmt
score_fmt
m_fmt
log2e_fmt
exp_fmt
locall_fmt
l_fmt
localo_fmt
oacc_fmt
```

修改后重新运行：

```powershell
python run_experiment.py
```

新的格式会同时影响 fixed-point datapath、PWL exp、统计和 debug dump。

## 如何修改随机输入

在 `experiment_config.json` 中修改：

```json
"data": {
  "seed": 42,
  "value_range": [-1.0, 1.0]
}
```

例如测试更大输入范围：

```json
"value_range": [-4.0, 4.0]
```

## 如何运行测试

先安装测试依赖：

```powershell
python -m pip install -e ".[dev]"
```

然后运行：

```powershell
python -m pytest -q
```

测试覆盖：

- fixed-point saturation 和 rounding。
- float quant/dequant。
- PWL exp 采样点误差。
- FP32 golden model。
- small-size hardware attention。
- baseline `LEN=256, d=64, Br=16, Bc=16, causal=True`。
- `experiment_config.json` 的读取。

## 后续 RTL 对齐方式

推荐流程：

1. 在 `experiment_config.json` 固定随机种子、输入范围和所有格式。
2. 运行 `python run_experiment.py` 生成 debug log。
3. 在 RTL 仿真中使用同一组 Q/K/V raw input。
4. 按 Q block 和 K/V tile 对比 `S`、`S_scaled`、`valid_mask`、`P`、
   `local_l`、`local_o`、`old_o_before`、`new_o` 等 CSV。
5. 最后对比 `output_o_raw.csv` 和 RTL 输出。

这个 Python model 的重点是把每个 fixed-point stage 的格式和整数结果显式化，
让 RTL debug 能逐级定位误差来源。
