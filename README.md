# GreenOpt | 新能源电站最优配置与最优调度

[English](#english) | [中文](#中文)

## 中文

GreenOpt 是一个面向风、光、储及厂内自发电的双层优化示例。外层使用粒子群算法（PSO）搜索装机容量，内层使用开源 HiGHS MILP 求解器进行小时级最优调度。全部计算与出图均由纯 Python 实现，不需要 MATLAB、Gurobi 或商业求解器；日常使用只需要修改 `config.py`。

### 模型做什么

- 外层决策：光伏、风电、储能功率、储能时长和厂内自发电容量。
- 内层决策：风光/自发电利用、弃电、购售电、储能充放电与 SOC。
- 目标：最小化年化总成本 = 年化投资成本 + 年化最优运行成本。
- 约束：逐时功率平衡、储能效率与 SOC 上下限及循环、购售电互斥、可选充放电互斥、并网容量限制。
- 支持：全年 8760 h 或加权典型日、固定装机、平价/分档造价、两阶段 PSO、储能循环寿命、敏感性分析、全年核准。

### 快速开始

要求：Python 3.11+；不需要 MATLAB、Gurobi 或商业求解器。

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
python run_greenopt.py --quick
```

快速模式只用于确认环境和输出链路。正式计算使用：

```powershell
python run_greenopt.py
```

完整配置默认采用“典型日粗搜 + 全年精搜”，并包含敏感性分析；计算量较大，请预留充足时间。若仅需已知容量下的最优调度，请在 `config.py` 的 `fixed` 中填入全部容量，程序会自动跳过 PSO。

### 数据格式

将数据放在 `Dataset.xlsx` 的 `BasicData` 工作表，且列名必须完全为：

| 列名 | 含义 | 单位/范围 |
| --- | --- | --- |
| `Buy_Price` | 购电电价 | 元/kWh |
| `Sell_Price` | 售电电价 | 元/kWh |
| `Load` | 负荷 | MW |
| `PV_pu` | 光伏标幺出力 | 0–1 |
| `WT_pu` | 风电标幺出力 | 0–1 |
| `Gen` | 厂内自发电标幺出力（默认） | 0–1 |

每行代表一个小时，行数必须是 24 的整数倍。若 `Gen` 已是 MW，请将 `config.py` 中的 `data["gen_mode"]` 改为 `"mw"`。

### 输出

运行后，`results/` 将包含：

- `greenopt_results.xlsx`：中英文两套工作簿内容 —— 最优配置、成本与电量、分档明细、
  典型日调度、典型周调度、全年 SOC 充放电、全年 SOC 逐小时、PSO 收敛、搜索设置、
  数据说明、专业指标、全年核准、敏感性分析（含列宽、边框、表头底色与冻结首行）；
- `result_summary.json`：便于复现实验的机器可读摘要；
- `fig_*_zh.png` 与 `fig_*_en.png`：中英文各一套出版级图表。

### 图表

出图样式与原 MATLAB 版逐项对齐，由 `greenopt/style.py` 统一管理：

| 项目 | 口径 |
| --- | --- |
| 配色 | Okabe-Ito 色盲友好调色板，语义固定（光伏橙 / 风电天蓝 / 购电朱红 / 售电绿 / 充电浅紫 / 放电深紫 / 自发电灰） |
| 字体 | 中文：宋体 SimSun + 数字与西文 Times New Roman 混排；英文：Times New Roman |
| 字号 | 正文 8 pt、标题 9 pt、柱顶数值 7 pt |
| 坐标轴 | 刻度朝内、四周带框、开启次刻度，点状浅灰网格（α = 0.20） |
| 画布 | 以厘米定尺寸（双栏 17.5 cm），导出 600 dpi PNG，不在 Word/LaTeX 中二次缩放 |
| 纵轴 | 按「数据包络 + 8% 余量」显式设定，避免柱顶与曲线极值贴住边框 |

图表清单：`fig_pso_convergence`（群体最优 + 种群均值）、`fig_source`（源荷曲线 + 净负荷）、
`fig_dispatch`（出力堆叠图，弃风/弃光/弃自发电按源拆分）、`fig_soc`（SOC + 上下限参考线）、
`fig_typical_week`（3 格：堆叠 / 充放电 / SOC 与电价）、`fig_cost_breakdown`（7 根柱的年化成本构成）、
`fig_pro_metrics`（LCOE 双口径 + 三个比例指标）、`fig_sensitivity`（8 子图敏感性分析）。

执行核心自检：

```powershell
python run_greenopt.py --self-test
```

### 项目结构

```text
config.py                 唯一日常配置入口（含绘图样式段）
run_greenopt.py           运行入口
greenopt/data.py          数据读取、典型日和典型周
greenopt/dispatch.py      内层 HiGHS MILP 调度
greenopt/optimizer.py     外层 PSO 与局部精修
greenopt/economics.py     分档造价、年化成本、指标与专业指标
greenopt/sensitivity.py   一维敏感性分析
greenopt/style.py         MATLAB 风格统一的绘图样式层
greenopt/plots.py         中英文图表
greenopt/reporting.py     中英文 Excel 与 JSON
Dataset.xlsx              示例数据
```

`.env.example` 只放非敏感运行设置。将它复制为 `.env` 后可自行覆盖求解器、随机种子和输出目录；`.env` 与 `results/` 均不会被 Git 提交。

## English

GreenOpt is a two-level capacity-planning and dispatch model for PV, wind, battery storage, and on-site generation. A particle swarm optimiser (PSO) chooses capacities; the open-source HiGHS MILP solver produces hourly dispatch decisions. Everything — including all figures and workbooks — is pure Python; no MATLAB or commercial solver is required. For normal use, edit `config.py` only.

### Features

- Five planning variables: PV, wind, ESS power, ESS duration, and on-site generation capacity.
- Hourly dispatch of generation usage, curtailment, grid import/export, charging/discharging, and SOC.
- Annualised CAPEX plus optimised operating cost objective.
- Full-year or weighted representative-day modelling, tiered CAPEX, fixed-capacity dispatch, two-stage PSO, cycle-life accounting, sensitivity analysis, and full-year validation.
- Bilingual plots and Excel sheets.

### Run

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
python run_greenopt.py --quick
python run_greenopt.py
```

`--quick` is a smoke test only. The standard run performs a representative-day coarse search, full-year refinement, and sensitivity analysis, so it can take substantial time. Use `python run_greenopt.py --self-test` after changing assumptions.

Input data must be in `Dataset.xlsx`, worksheet `BasicData`, with hourly columns `Buy_Price`, `Sell_Price`, `Load`, `PV_pu`, `WT_pu`, and `Gen`. See the Chinese section for units, figure styles, and the full list of output sheets.

Figures are rendered in the MATLAB look: Okabe-Ito palette with fixed semantics, SimSun + Times New Roman for Chinese, 8/9/7 pt type, inward ticks with minor ticks, dotted light grid, centimetre-based canvas sizes (17.5 cm double column), 600 dpi PNG, and explicit y-limits with an 8% margin.

## License

This project is released under the included MIT License.
