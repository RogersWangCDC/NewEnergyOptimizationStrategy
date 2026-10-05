"""MATLAB 风格的统一绘图样式层。

本模块是全部出图的**唯一样式来源**，逐项复刻原 MATLAB 版 ``run_greenopt.m`` 的
绘图体系，保证 Python 输出与 MATLAB 输出在视觉上一致：

    gopt_palette      L4177  Okabe-Ito 色盲友好调色板（8 色全色盲可辨）
    gopt_labels       L4194  图内文字标签（中英）
    gopt_style        L4427  坐标轴样式（FontName / TickDir in / 次刻度 / Box / Layer top）
    gopt_newfig       L4421  以厘米为单位的物理画布尺寸
    gopt_ylim_pad     L4121  「数据包络 + 比例余量」显式纵轴
    gopt_numlabel     L4444  柱顶数值按量级精简小数位
    gopt_style 的网格配置 L4432  点状虚线、α=0.20、灰 0.45

字体口径（用户在 2026-10-05 会话中指定）：
    中文 -> 宋体 SimSun + 数字/西文 Times New Roman 混排
    英文 -> Times New Roman
混排的实现依赖 matplotlib >= 3.6 的逐字形回退：字体列表里 Times New Roman 在前，
西文与数字由它渲染，汉字因 Times 不含该字形而回退到 SimSun。
"""
from __future__ import annotations

import logging
from pathlib import Path

import matplotlib
matplotlib.use("Agg")

import matplotlib.pyplot as plt
import numpy as np

# SimSun / SimHei 没有 bold 字面，标题取粗体时 matplotlib 会逐条打日志刷屏；
# 这里降级为静默（实际仍以常规字重渲染，视觉可接受）。
logging.getLogger("matplotlib.font_manager").setLevel(logging.ERROR)


CM = 1.0 / 2.54          # 厘米 -> 英寸

# --------------------------------------------------------------------------
# 调色板：与 run_greenopt.m 的 gopt_palette() (L4177) 逐值一致
# --------------------------------------------------------------------------
PALETTE = {
    "black":   (0.000, 0.000, 0.000),
    "orange":  (0.902, 0.624, 0.000),   # 光伏
    "sky":     (0.337, 0.706, 0.914),   # 风电
    "green":   (0.000, 0.620, 0.451),   # 售电 / 绿电消纳
    "yellow":  (0.941, 0.894, 0.259),
    "blue":    (0.000, 0.447, 0.698),   # PSO 群体最优 / SOC
    "verm":    (0.835, 0.369, 0.000),   # 购电
    "purple":  (0.600, 0.310, 0.640),   # 储能充电（浅紫）
    "purple2": (0.400, 0.160, 0.480),   # 储能放电（深紫）
    "grey":    (0.450, 0.450, 0.450),   # 厂内自发电
    "grey2":   (0.780, 0.780, 0.780),   # 弃光伏
    "grey3":   (0.620, 0.620, 0.620),   # 弃风电
    "grey4":   (0.880, 0.880, 0.880),   # 弃自发电
    "zero":    (0.200, 0.200, 0.200),   # 零轴
}

# 「出力堆叠图」的堆叠顺序：(调度结果字段, 图例标签键, 配色)，直接对应 gopt_stack_pack (L4062)。
# 零轴上方（自下而上）：储能放电 / 风电 / 光伏 / 自发电 / 购电
# 零轴下方（自上而下）：储能充电 / 售电 / 弃光伏 / 弃风电 / 弃自发电
STACK_POS = (
    ("discharge", "discharge", "purple2"),
    ("wt", "wt", "sky"),
    ("pv", "pv", "orange"),
    ("gen", "gen", "grey"),
    ("buy", "buy", "verm"),
)
STACK_NEG = (
    ("charge", "charge", "purple"),
    ("sell", "sell", "green"),
    ("pv_curt", "curt_pv", "grey2"),
    ("wt_curt", "curt_wt", "grey3"),
    ("gen_curt", "curt_gen", "grey4"),
)

FONT_ZH = ["Times New Roman", "SimSun", "SimHei", "DejaVu Sans"]
FONT_EN = ["Times New Roman", "DejaVu Serif", "DejaVu Sans"]


# --------------------------------------------------------------------------
# 文字标签：对应 gopt_labels (L4194)
# --------------------------------------------------------------------------
LABELS = {
    "zh": {
        "load": "负荷", "pv": "光伏", "wt": "风电", "net": "净负荷", "gen": "自发电",
        "buy": "购电", "sell": "售电", "charge": "储能充电", "discharge": "储能放电",
        "curt": "弃风弃光", "soc": "SOC",
        "curt_pv": "弃光伏", "curt_wt": "弃风电", "curt_gen": "弃自发电",
        "buy_price": "购电价", "sell_price": "售电价",
        "hour": "时刻 (h)", "power": "功率 (MW)", "soc_y": "SOC (%)", "price_y": "电价 (元/kWh)",
        "iter": "迭代代数", "cost_y": "年化总成本 (万元/年)",
        "gbest": "群体最优", "gmean": "种群均值",
        "rate_y": "比例 (%)", "lcoe_y": "度电成本 (元/kWh)",
        "capex_y": "年化成本 (万元/年)", "unused_y": "未自用率 (%)",
        "self_rate": "绿电自用率", "sell_rate": "上网率", "curt_rate": "弃电率",
        "lcoe_gen": "LCOE 发电口径", "lcoe_con": "LCOE 消纳口径",
        "m_green": "用户绿电占比", "m_absorb": "新能源消纳比例", "m_save": "成本节省率",
        "min_pt": "最低点",
    },
    "en": {
        "load": "Load", "pv": "PV", "wt": "Wind", "net": "Net load", "gen": "Gen",
        "buy": "Grid purchase", "sell": "Grid sale", "charge": "ESS charging", "discharge": "ESS discharging",
        "curt": "Curtailment", "soc": "SOC",
        "curt_pv": "Curtail PV", "curt_wt": "Curtail wind", "curt_gen": "Curtail gen",
        "buy_price": "Purchase price", "sell_price": "Sale price",
        "hour": "Time (h)", "power": "Power (MW)", "soc_y": "SOC (%)", "price_y": "Price (CNY/kWh)",
        "iter": "Iteration", "cost_y": "Annualized cost (10^4 CNY/yr)",
        "gbest": "Global best", "gmean": "Swarm mean",
        "rate_y": "Share (%)", "lcoe_y": "LCOE (CNY/kWh)",
        "capex_y": "Annualized cost (10^4 CNY/yr)", "unused_y": "Non-self-used share (%)",
        "self_rate": "Self-used share", "sell_rate": "Grid-sale share", "curt_rate": "Curtailment share",
        "lcoe_gen": "Generation basis", "lcoe_con": "Consumption basis",
        "m_green": "Green share of load", "m_absorb": "Renewable absorption", "m_save": "Cost saving rate",
        "min_pt": "minimum",
    },
}

# 成本构成图横轴类别：顺序必须与 plots.py 的 vals 完全一致（对应 gopt_catlabels L4282）
COST_CATS = {
    "zh": ["光伏投资", "风电投资", "储能投资", "自发电投资", "自发电运行", "购电成本", "售电收益"],
    "en": ["PV capex", "Wind capex", "ESS capex", "Gen capex", "Gen fuel", "Grid purchase", "Grid sale"],
}

TITLES = {
    "zh": {
        "pso": "外层搜索收敛曲线",
        "source": "典型日源荷曲线", "dispatch": "典型日出力堆叠图", "soc": "典型日储能 SOC",
        "week": "典型周调度结果", "cost": "年化成本构成", "pro": "专业化指标",
        "sensitivity": "敏感性分析",
        "pro_lcoe": "绿电度电成本 LCOE（不含税）", "pro_rate": "关键比例指标",
    },
    "en": {
        "pso": "PSO convergence",
        "source": "Typical-day source-load profiles", "dispatch": "Stacked generation dispatch on typical days",
        "soc": "Battery SOC on typical days", "week": "Optimal dispatch over the typical week",
        "cost": "Annual cost breakdown", "pro": "Professional metrics",
        "sensitivity": "Sensitivity analysis",
        "pro_lcoe": "LCOE of green power (excl. tax)", "pro_rate": "Key ratio indicators",
    },
}


def label(lang: str, key: str) -> str:
    return LABELS[lang][key]


# --------------------------------------------------------------------------
# 样式：对应 gopt_style (L4427) + cfg_greenopt.m 第 552~576 行
# --------------------------------------------------------------------------
def apply_style(lang: str, style: dict) -> None:
    """设置全局 rcParams，使后续所有图与 MATLAB 的 gopt_style 同口径。"""
    fonts = FONT_ZH if lang == "zh" else FONT_EN
    base = style["font_size"]
    plt.rcParams.update({
        # 字体：直接给「具体字体名列表」才能触发 matplotlib>=3.6 的逐字形回退——
        # Times New Roman 在前负责西文与数字，汉字因 Times 无该字形而回退到 SimSun。
        "font.family": fonts,
        "font.serif": fonts,
        "font.sans-serif": fonts,
        "font.size": base,
        "axes.titlesize": base,
        "axes.labelsize": style["title_size"],
        "xtick.labelsize": base,
        "ytick.labelsize": base,
        "legend.fontsize": max(base - 1, 5),
        "axes.unicode_minus": False,          # 修负号方框
        "mathtext.fontset": "stix",
        # 坐标框：TickDir in + Box on
        "axes.linewidth": style["axis_line_width"],
        "axes.edgecolor": "black",
        "xtick.direction": "in", "ytick.direction": "in",
        "xtick.top": True, "ytick.right": True,
        "xtick.major.size": 3.0, "ytick.major.size": 3.0,
        "xtick.minor.size": 1.7, "ytick.minor.size": 1.7,
        "xtick.minor.visible": True, "ytick.minor.visible": True,
        "xtick.major.width": style["axis_line_width"],
        "ytick.major.width": style["axis_line_width"],
        "xtick.minor.width": style["axis_line_width"] * 0.8,
        "ytick.minor.width": style["axis_line_width"] * 0.8,
        # 网格：点状虚线、灰 0.45、α 0.20；次网格关闭
        "axes.grid": bool(style["grid"]),
        "grid.linestyle": ":", "grid.color": "0.45", "grid.alpha": 0.20,
        "grid.linewidth": 0.4,
        "axes.axisbelow": True,               # 网格在数据之下（等效 MATLAB Layer top 的观感）
        # 线宽
        "lines.linewidth": style["line_width"],
        # 画布
        "figure.facecolor": "white", "savefig.facecolor": "white",
        "figure.dpi": 100, "savefig.dpi": style["dpi"],
        "legend.frameon": False,
        "axes.titleweight": "normal",
    })


def decorate(ax) -> None:
    """逐个坐标轴的收尾修饰：次刻度、点状网格、次网格关闭、背景透明。"""
    ax.minorticks_on()
    ax.grid(True, which="major", linestyle=":", color="0.45", alpha=0.20, linewidth=0.4)
    ax.grid(False, which="minor")
    ax.set_axisbelow(True)
    for spine in ax.spines.values():
        spine.set_linewidth(plt.rcParams["axes.linewidth"])
        spine.set_color("black")


# --------------------------------------------------------------------------
# 画布：对应 gopt_newfig (L4421) —— 以厘米为单位
# --------------------------------------------------------------------------
def new_fig(width_cm: float, height_cm: float, **kwargs):
    return plt.subplots(figsize=(width_cm * CM, height_cm * CM), **kwargs)


# --------------------------------------------------------------------------
# 纵轴留白：对应 gopt_ylim_pad (L4121)
# --------------------------------------------------------------------------
def pad_ylim(ax, ext=(0.0, 0.0), extra=None, pad_frac: float = 0.08) -> None:
    """用「真实数据包络 + 比例余量」显式设 ylim，避免柱顶/曲线极值贴住坐标框。

    下界规则：数据全非负 -> 下界钉 0，余量只加在顶部；含负值 -> 上下各留同样余量。
    """
    values = [float(ext[0]), float(ext[1]), 0.0]
    if extra is not None:
        arr = np.asarray(extra, float).ravel()
        values.extend(arr[np.isfinite(arr)].tolist())
    values = [v for v in values if np.isfinite(v)]
    if not values:
        return
    lo, hi = min(values), max(values)
    span = hi - lo
    if not span > 0:
        span = max(abs(hi), 1.0)
    pad = pad_frac * span
    ax.set_ylim(0.0, hi + pad) if lo >= 0 else ax.set_ylim(lo - pad, hi + pad)


# --------------------------------------------------------------------------
# 数值标签：对应 gopt_numlabel (L4444)
# --------------------------------------------------------------------------
def num_label(value: float, max_dec: int = 2) -> str:
    """柱顶数值按量级精简小数位：|v|>=100 取整；10~100 留 1 位；<10 留 2 位。"""
    if abs(value) < 5e-3:          # 避免出现 "-0.00" 这类负零标签
        value = 0.0
    a = abs(value)
    if a >= 100:
        nd = 0
    elif a >= 10:
        nd = min(1, max_dec)
    else:
        nd = min(2, max_dec)
    return f"{value:.{nd}f}"


def bar_labels(ax, xs, values, *, font_size: float, gap_frac: float = 0.25,
               color=(0.15, 0.15, 0.15), offset_frac: float = 0.0, fmt=None) -> None:
    """在柱顶/柱底写数值标签；正柱标在上方，负柱标在下方（对应 gopt_plots L3994）。"""
    span = max((abs(float(v)) for v in values), default=1.0) or 1.0
    gap = gap_frac * span
    for x, v in zip(xs, values):
        v = float(v)
        if v >= 0:
            va, y = "bottom", v + gap * 0.5 + offset_frac * span
        else:
            va, y = "top", v - gap * 0.5 - offset_frac * span
        ax.text(x, y, num_label(v) if fmt is None else fmt(v), ha="center", va=va,
                fontsize=font_size, color=color)


# --------------------------------------------------------------------------
# 保存：对应 gopt_save (L4637)
# --------------------------------------------------------------------------
def save(fig, directory: Path, name: str, lang: str, style: dict) -> Path:
    """按 cfg 的格式与 dpi 导出；bbox_inches='tight' 保证标签不被裁掉。"""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{name}_{lang}.png"
    fig.savefig(path, dpi=style["dpi"], bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return path


def stack_ext(positive, negative) -> tuple[float, float]:
    """堆叠柱的真实极值 [ymin, ymax]（对应 gopt_stack_ext L4108）。

    输入是「分量列表」，每个分量是一条逐时序列；需按**分量**求和才得到每小时的堆叠
    总高。注意分量放在 axis=0（形状 分量 × 小时），故沿 axis=0 归约。
    """
    def height(series) -> np.ndarray:
        if series is None or len(series) == 0:
            return np.zeros(0, float)
        arr = np.asarray(series, float)
        return arr.sum(axis=0) if arr.ndim == 2 else arr

    top, bottom = height(positive), height(negative)
    ymax = float(top.max()) if top.size else 0.0
    ymin = float(bottom.min()) if bottom.size else 0.0
    return ymin, ymax
