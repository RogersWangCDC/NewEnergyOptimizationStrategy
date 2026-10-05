"""以中英文分别输出论文级图表（MATLAB 风格）。

出图清单与版式逐张对齐原 MATLAB 版 ``run_greenopt.m`` 的 ``gopt_plots`` (L3600)：

    fig_pso_convergence   外层搜索收敛曲线（群体最优 + 种群均值）
    fig_source            典型日源荷曲线（源侧填充带 + 负荷 + 净负荷）
    fig_dispatch          典型日出力堆叠图（含按源拆分的弃风 / 弃光 / 弃自发电）
    fig_soc               典型日储能 SOC（含 SOC 上下限参考线）
    fig_typical_week      典型周调度（3 格：堆叠 / 充放电 / SOC 与电价）
    fig_cost_breakdown    年化成本构成（7 柱，柱顶标注数值）
    fig_pro_metrics       专业化指标（LCOE 双口径 + 三个比例指标）
    fig_sensitivity       敏感性分析（8 子图）

全部样式取自 ``greenopt.style``，本模块只负责数据到图元的映射。
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

from .economics import metrics_pro
from .style import (CM, COST_CATS, LABELS, PALETTE, STACK_NEG, STACK_POS, TITLES, apply_style,
                    decorate, label, num_label, pad_ylim, save, stack_ext)
# 敏感性分析 8 子图：(扫描维度, 面板类型, 标题键)
SENS_PANELS = (
    ("ESS power", "cost_unused", "tSensP"),
    ("ESS energy", "cost_unused", "tSensE"),
    ("PV", "cost_unused", "tSensPV"),
    ("Wind", "cost_unused", "tSensWT"),
    ("ESS energy", "util", "tSensUtil"),
    ("ESS energy", "cost_split", "tSensCost"),
    ("Generation", "cost_unused", "tSensGen"),
    ("Generation", "gen_share", "tSensGenShare"),
)

SENS_TEXT = {
    "zh": {"tSensP": "储能功率敏感性", "tSensE": "储能容量敏感性",
           "tSensPV": "光伏装机敏感性", "tSensWT": "风电装机敏感性",
           "tSensUtil": "消纳指标随储能容量变化", "tSensCost": "成本构成随储能容量变化",
           "tSensGen": "自发电容量敏感性", "tSensGenShare": "自发电占比与度电成本",
           "xP": "储能额定功率 P (MW)", "xE": "储能容量 E (MWh)",
           "xPV": "光伏装机 (MW)", "xWT": "风电装机 (MW)", "xGen": "自发电容量 (MW)",
           "yCost": "年化总成本 (万元/年)", "yUnused": "未自用率 (%)",
           "yRate": "比例 (%)", "yCapex": "年化成本 (万元/年)",
           "yGenShare": "自发电占负荷比例 (%)", "yGenLcoe": "自发电度电成本 (元/kWh)",
           "capexPv": "光伏年化", "capexWt": "风电年化", "capexEss": "储能年化",
           "opCost": "运行成本", "selfRate": "绿电自用率", "sellRate": "上网率",
           "curtRate": "弃电率", "minPt": "最低点"},
    "en": {"tSensP": "ESS power sensitivity", "tSensE": "ESS capacity sensitivity",
           "tSensPV": "PV capacity sensitivity", "tSensWT": "Wind capacity sensitivity",
           "tSensUtil": "Utilization indices vs ESS capacity", "tSensCost": "Cost breakdown vs ESS capacity",
           "tSensGen": "Gen capacity sensitivity", "tSensGenShare": "Gen share of load and its LCOE",
           "xP": "Rated ESS power P (MW)", "xE": "ESS capacity E (MWh)",
           "xPV": "PV capacity (MW)", "xWT": "Wind capacity (MW)", "xGen": "Gen capacity (MW)",
           "yCost": "Annualized total cost (10^4 CNY/yr)", "yUnused": "Non-self-used share (%)",
           "yRate": "Share (%)", "yCapex": "Annualized cost (10^4 CNY/yr)",
           "yGenShare": "Gen share of load (%)", "yGenLcoe": "Gen LCOE (CNY/kWh)",
           "capexPv": "PV capex", "capexWt": "Wind capex", "capexEss": "ESS capex",
           "opCost": "Operation cost", "selfRate": "Self-used share", "sellRate": "Grid-sale share",
           "curtRate": "Curtailment share", "minPt": "minimum"},
}

X_KEYS = {"ESS power": "xP", "ESS energy": "xE", "PV": "xPV", "Wind": "xWT", "Generation": "xGen"}


# --------------------------------------------------------------------------
# 内部工具
# --------------------------------------------------------------------------
def _style_of(cfg: dict) -> dict:
    """把 config.py 的样式配置整理成 style.py 需要的扁平结构。"""
    s = cfg["out"]["style"]
    return {"font_size": s["font_size"], "title_size": s["title_size"],
            "bar_label_font_size": s["bar_label_font_size"],
            "line_width": s["line_width"], "axis_line_width": s["axis_line_width"],
            "grid": s["grid"], "dpi": cfg["out"]["dpi"], "pad_frac": s["pad_frac"],
            "alpha": s["alpha"], "bold_title": True}


def _day_idx(sc, day: int = 0) -> np.ndarray:
    """取第 day 个典型日的 24 个小时下标。"""
    idx = np.where(sc.day_id == day)[0]
    return idx if len(idx) else np.arange(min(24, sc.n))


def _stack_fill(ax, x, arrays, colors, names, alpha):
    """阶梯式累加填充，模拟 MATLAB ``bar(...,'stacked')`` 的块状观感。

    ``arrays`` 全为正即向上堆叠，全为负即向下堆叠；返回句柄供图例使用。
    """
    base = np.zeros_like(np.asarray(x, float))
    handles = []
    for arr, color, name in zip(arrays, colors, names):
        arr = np.asarray(arr, float)
        top = base + arr
        handles.append(ax.fill_between(x, base, top, step="mid", color=color,
                                       alpha=alpha, linewidth=0, label=name))
        base = top
    return handles


def _legend_north(ax, n_items: int, style: dict, ncol: int = 0):
    """图例置于坐标框上方（对应 MATLAB 的 Layout.Tile='north'），避免压住数据。

    返回占用行数，供 :func:`_title_above_legend` 计算标题需要避让的高度。
    """
    ncol = ncol or min(max(n_items, 1), 6)
    rows = max(1, -(-n_items // ncol))
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.01), ncol=ncol,
              frameon=False, fontsize=style["font_size"] - 1,
              columnspacing=1.0, handlelength=1.5, handletextpad=0.5, borderaxespad=0.0)
    return rows


def _title_above_legend(ax, text, style, legend_rows: int, **kwargs):
    """把标题抬到图例之上，避免长标题（含容量参数）与图例重叠。"""
    ax.set_title(text, pad=6 + 12 * max(legend_rows, 0), **kwargs)


def _tick_rotation(ax, angle: float) -> None:
    for tick in ax.get_xticklabels():
        tick.set_rotation(angle)
        tick.set_ha("right" if angle else "center")


def _visible(series, scale: float) -> bool:
    """判断某个堆叠分量是否值得画：恒为零（或相对整体小到看不见）的不占图例。"""
    arr = np.abs(np.asarray(series, float))
    return bool(arr.size and arr.max() > 1e-4 * max(scale, 1e-9))


NEG_SIGN = -1          # 零轴下方分量统一取负号，保证自上而下堆叠顺序


def _scale_of(dispatch) -> float:
    """整条调度曲线里的最大幅值，作为「分量是否值得画」的相对阈值基准。"""
    values = [np.abs(np.asarray(dispatch[k], float)).max() for k, _l, _c in STACK_POS + STACK_NEG]
    return max(values or [0.0])


def _stack_parts(dispatch, keys, idx, lang, scale, sign=1):
    """按堆叠顺序取出「有可见值」的分量，返回 (arrays, colors, names)。

    ``keys`` 为 ``(调度结果字段, 图例标签键, 配色)`` 三元组序列；
    ``idx`` 为 None 表示取整条曲线（典型周），否则按小时下标切片（典型日）。
    """
    arrays, colors, names = [], [], []
    for key, lab, color in keys:
        raw = np.asarray(dispatch[key], float)
        arr = (raw if idx is None else raw[idx]) * sign
        if _visible(arr, scale):
            arrays.append(arr)
            colors.append(PALETTE[color])
            names.append(label(lang, lab))
    return arrays, colors, names


# --------------------------------------------------------------------------
# 各张图
# --------------------------------------------------------------------------
def _plot_pso(result, lang, style, out_dir):
    t = LABELS[lang]
    fig, ax = plt.subplots(figsize=(8.8 * CM, 6.2 * CM))
    hist = np.asarray(result.history, float)
    if hist.ndim == 1:                    # 兼容只有群体最优一列的历史
        hist = np.column_stack([hist, hist])
    x = np.arange(hist.shape[0])
    ax.plot(x, hist[:, 0] / 1e4, "-o", color=PALETTE["blue"], markersize=3.0,
            markerfacecolor=PALETTE["blue"], markeredgecolor="none", label=t["gbest"])
    if hist.shape[1] >= 2:
        ax.plot(x, hist[:, 1] / 1e4, "-s", color=PALETTE["verm"], markersize=3.0,
                markerfacecolor=PALETTE["verm"], markeredgecolor="none",
                linewidth=style["line_width"] * 0.85, label=t["gmean"])
    ax.set_xlabel(t["iter"])
    ax.set_ylabel(t["cost_y"])
    ax.set_title(TITLES[lang]["pso"])
    ax.xaxis.set_major_locator(MaxNLocator(integer=True))   # 迭代代数取整刻度
    decorate(ax)
    ax.legend(loc="upper right", frameon=False, fontsize=style["font_size"] - 1)
    return save(fig, out_dir, "fig_pso_convergence", lang, style)


def _plot_source(sc, dispatch, cap, lang, style, out_dir):
    t = TITLES[lang]
    idx = _day_idx(sc)
    x = np.arange(1, len(idx) + 1)
    load = sc.load[idx]
    pv, wt = dispatch["pv_avail"][idx], dispatch["wt_avail"][idx]
    gen = dispatch["gen_avail"][idx]
    net = load - pv - wt - gen

    fig, ax = plt.subplots(figsize=(17.5 * CM, 6.5 * CM))
    ax.fill_between(x, 0, pv, step="mid", color=PALETTE["orange"], alpha=style["alpha"], linewidth=0, label=label(lang, "pv"))
    ax.fill_between(x, 0, wt, step="mid", color=PALETTE["sky"], alpha=style["alpha"], linewidth=0, label=label(lang, "wt"))
    ax.plot(x, load, "-", color=PALETTE["black"], linewidth=style["line_width"], label=label(lang, "load"))
    ax.plot(x, net, "--", color=PALETTE["blue"], linewidth=style["line_width"] * 0.9, label=label(lang, "net"))
    pad_ylim(ax, (0.0, 0.0), np.concatenate([pv, wt, load, net]), style["pad_frac"])
    ax.set_xlim(0.5, len(idx) + 0.5)
    ax.set_xlabel(label(lang, "hour"))
    ax.set_ylabel(label(lang, "power"))
    decorate(ax)
    _title_above_legend(ax, f"{t['source']}  (PV = {cap[0]:.2f} MW, Wind = {cap[1]:.2f} MW)",
                        style, _legend_north(ax, 4, style), fontweight="bold")
    return save(fig, out_dir, "fig_source", lang, style)


def _plot_dispatch(sc, dispatch, cap, lang, style, out_dir):
    t = TITLES[lang]
    idx = _day_idx(sc)
    x = np.arange(1, len(idx) + 1)

    scale = _scale_of(dispatch)
    pos_series, pos_colors, pos_names = _stack_parts(dispatch, STACK_POS, idx, lang, scale, 1)
    neg_series, neg_colors, neg_names = _stack_parts(dispatch, STACK_NEG, idx, lang, scale, -1)

    fig, ax = plt.subplots(figsize=(17.5 * CM, 7.0 * CM))
    handles = _stack_fill(ax, x, pos_series, pos_colors, pos_names, style["alpha"])
    handles += _stack_fill(ax, x, neg_series, neg_colors, neg_names, style["alpha"])
    handles.append(ax.plot(x, sc.load[idx], "-", color=PALETTE["black"],
                           linewidth=style["line_width"], label=label(lang, "load"))[0])
    ax.axhline(0, color=PALETTE["zero"], linewidth=style["axis_line_width"])
    pad_ylim(ax, stack_ext(pos_series, neg_series), sc.load[idx], style["pad_frac"])
    ax.set_xlim(0.5, len(idx) + 0.5)
    ax.set_xlabel(label(lang, "hour"))
    ax.set_ylabel(label(lang, "power"))
    decorate(ax)
    _title_above_legend(ax, f"{t['dispatch']}  (PV = {cap[0]:.2f} MW, Wind = {cap[1]:.2f} MW, "
                            f"ESS = {cap[2]:.2f} MW / {cap[3]:.2f} MWh, Gen = {cap[4]:.2f} MW)",
                        style, _legend_north(ax, len(handles), style), fontweight="bold")
    return save(fig, out_dir, "fig_dispatch", lang, style)


def _plot_soc(sc, dispatch, cap, cfg, lang, style, out_dir):
    t = TITLES[lang]
    idx = _day_idx(sc)
    x = np.arange(1, len(idx) + 1)
    e_ess = float(cap[3])

    fig, ax = plt.subplots(figsize=(17.5 * CM, 6.0 * CM))
    if e_ess > 0:
        soc = dispatch["soc"][idx[0] + 1: idx[0] + len(idx) + 1]   # 每小时末的 SOC
        ax.plot(x, soc / e_ess * 100, "-", color=PALETTE["blue"], linewidth=style["line_width"])
        ax.axhline(cfg["ess"]["soc_max"] * 100, ls="--", color=PALETTE["grey"], linewidth=0.7)
        ax.axhline(cfg["ess"]["soc_min"] * 100, ls="--", color=PALETTE["grey"], linewidth=0.7)
    else:
        ax.text(12, 50, "ESS = 0", ha="center", va="center", fontsize=style["font_size"])
    ax.set_ylim(0, 100)
    ax.set_xlim(0.5, len(idx) + 0.5)
    ax.set_xlabel(label(lang, "hour"))
    ax.set_ylabel(label(lang, "soc_y"))
    ax.set_title(t["soc"], fontweight="bold")
    decorate(ax)
    return save(fig, out_dir, "fig_soc", lang, style)


def _plot_week(week_dispatch, week_sc, cap, lang, style, out_dir):
    t = TITLES[lang]
    n = week_sc.n
    x = np.arange(1, n + 1)
    fig, axes = plt.subplots(3, 1, figsize=(17.5 * CM, 15.0 * CM), layout="constrained")

    # (a) 出力堆叠图
    ax = axes[0]
    scale = _scale_of(week_dispatch)
    pos_series, pos_colors, pos_names = _stack_parts(week_dispatch, STACK_POS, None, lang, scale, 1)
    neg_series, neg_colors, neg_names = _stack_parts(week_dispatch, STACK_NEG, None, lang, scale, -1)
    handles = _stack_fill(ax, x, pos_series, pos_colors, pos_names, style["alpha"])
    handles += _stack_fill(ax, x, neg_series, neg_colors, neg_names, style["alpha"])
    handles.append(ax.plot(x, week_sc.load, "-", color=PALETTE["black"],
                           linewidth=style["line_width"], label=label(lang, "load"))[0])
    ax.axhline(0, color=PALETTE["zero"], linewidth=style["axis_line_width"])
    pad_ylim(ax, stack_ext(pos_series, neg_series), week_sc.load, style["pad_frac"])
    ax.set_ylabel(label(lang, "power"))
    _legend_north(ax, len(handles), style)

    # (b) 储能充放电（充电为负）
    ax = axes[1]
    dis, ch = week_dispatch["discharge"], week_dispatch["charge"]
    ax.fill_between(x, 0, dis, step="mid", color=PALETTE["purple2"], alpha=style["alpha"],
                    linewidth=0, label=label(lang, "discharge"))
    ax.fill_between(x, 0, -ch, step="mid", color=PALETTE["purple"], alpha=style["alpha"],
                    linewidth=0, label=label(lang, "charge"))
    ax.axhline(0, color=PALETTE["zero"], linewidth=style["axis_line_width"] * 0.8)
    pad_ylim(ax, (float(np.min(-ch)), float(np.max(dis))), None, style["pad_frac"])
    ax.set_ylabel(label(lang, "power"))
    _legend_north(ax, 2, style)

    # (c) SOC 与电价（双 y 轴）
    ax = axes[2]
    e_ess = float(cap[3])
    soc = week_dispatch["soc"][1: n + 1] / e_ess * 100 if e_ess > 0 else np.zeros(n)
    ax.plot(x, soc, "-", color=PALETTE["blue"], linewidth=style["line_width"], label=label(lang, "soc"))
    ax.set_ylabel(label(lang, "soc_y"))
    ax.set_ylim(0, 100)
    twin = ax.twinx()
    twin.plot(x, week_sc.buy_price, "-", color=PALETTE["verm"], linewidth=style["line_width"] * 0.9,
              label=label(lang, "buy_price"))
    twin.plot(x, week_sc.sell_price, "--", color=PALETTE["green"], linewidth=style["line_width"] * 0.9,
              label=label(lang, "sell_price"))
    pad_ylim(twin, (0.0, 0.0), np.concatenate([week_sc.buy_price, week_sc.sell_price]), style["pad_frac"])
    twin.set_ylabel(label(lang, "price_y"))
    twin.grid(False)
    twin.minorticks_on()
    handles = ax.get_lines() + twin.get_lines()
    ax.legend(handles, [h.get_label() for h in handles], loc="lower center", bbox_to_anchor=(0.5, 1.01),
              ncol=3, frameon=False, fontsize=style["font_size"] - 1,
              handlelength=1.5, handletextpad=0.5, borderaxespad=0.0)

    for axis in axes:
        axis.set_xlim(0.5, n + 0.5)
        for d in range(1, n // 24):
            axis.axvline(d * 24, ls=":", color="0.85", linewidth=0.6)
        decorate(axis)
    axes[2].set_xlabel(label(lang, "hour"))
    fig.suptitle(t["week"], fontsize=style["title_size"], fontweight="bold")
    return save(fig, out_dir, "fig_typical_week", lang, style)


def _bar_limits(values) -> tuple[float, float]:
    """柱状图纵轴范围：非负数据下界钉 0，含负值时下探，顶部统一留 18% 标注余量。"""
    finite = [float(z) for z in values if np.isfinite(z)] or [1.0]
    lo, hi = min(finite), max(finite)
    span = hi - lo
    if not span > 0:
        span = max(abs(hi), 1.0)
    return (lo - 0.05 * span if lo < 0 else 0.0), hi + 0.18 * span


def _plot_cost(dispatch, metric, cap, lang, style, out_dir):
    """7 根柱：四个资产的投资 + 自发电运行 + 购电成本 + 售电收益（负值）。"""
    t = TITLES[lang]
    detail = metric["cost_detail"]
    vals = np.array([
        detail["pv"]["annual"], detail["wt"]["annual"],
        detail["ess_p"]["annual"] + detail["ess_e"]["annual"], detail["gen"]["annual"],
        dispatch["cost_gen_var"], dispatch["cost_buy"], -dispatch["revenue_sell"],
    ]) / 1e4
    colors = [PALETTE[k] for k in ("orange", "sky", "purple", "grey", "grey3", "verm", "green")]

    fig, ax = plt.subplots(figsize=(8.8 * CM, 6.2 * CM))
    bars = ax.bar(np.arange(len(vals)), vals, 0.62)
    for rect, color in zip(bars, colors):
        rect.set_facecolor(color)
        rect.set_edgecolor("none")
    ax.set_xticks(np.arange(len(vals)))
    ax.set_xticklabels(COST_CATS[lang])
    ax.set_ylabel(label(lang, "cost_y"))
    ax.set_title(t["cost"])
    _tick_rotation(ax, 20)

    # 纵向留白按数据量级自适应（对应 gopt_plots L3987）
    span = float(np.max(np.abs(vals))) or 1.0
    gap, room = 0.030 * span, 0.120 * span
    lo, hi = min(float(np.min(vals)), 0.0), max(float(np.max(vals)), 0.0)
    ax.set_ylim(lo - gap - room, hi + gap + room)
    for i, v in enumerate(vals):
        if v >= 0:
            va, y = "bottom", v + 0.25 * gap
        else:
            va, y = "top", v - 0.25 * gap
        ax.text(i, y, num_label(float(v)), ha="center", va=va,
                fontsize=style["bar_label_font_size"], color=(0.15, 0.15, 0.15))
    decorate(ax)
    return save(fig, out_dir, "fig_cost_breakdown", lang, style)


def _plot_pro_metrics(dispatch, cap, cfg, sc, lang, style, out_dir):
    """左格两个 LCOE，右格三个比例指标（对应 gopt_plot_pro_metrics L4674）。"""
    t = TITLES[lang]
    pro = metrics_pro(dispatch, cap, cfg, sc)
    fig, axes = plt.subplots(1, 2, figsize=(17.5 * CM, 6.8 * CM), layout="constrained")

    # (a) LCOE 双口径
    ax = axes[0]
    v = [pro["lcoe_gen"], pro["lcoe_con"]]
    bars = ax.bar([0, 1], [0 if not np.isfinite(z) else z for z in v], 0.55)
    for rect, color in zip(bars, (PALETTE["orange"], PALETTE["blue"])):
        rect.set_facecolor(color); rect.set_edgecolor("none")
    ax.set_xticks([0, 1])
    ax.set_xticklabels([label(lang, "lcoe_gen"), label(lang, "lcoe_con")])
    ax.set_ylabel(label(lang, "lcoe_y"))
    ax.set_title(t["pro_lcoe"], fontsize=style["font_size"] + 1)
    lo, hi = _bar_limits(v)
    ax.set_ylim(lo, hi)
    for i, z in enumerate(v):
        if np.isfinite(z):
            ax.text(i, z + 0.03 * (hi - lo), f"{z:.4f}", ha="center", va="bottom",
                    fontsize=style["font_size"])
    decorate(ax)

    # (b) 三个比例指标
    ax = axes[1]
    v = [pro["green_rate"], pro["absorb_rate"], pro["save_rate"]]
    bars = ax.bar([0, 1, 2], [0 if not np.isfinite(z) else z for z in v], 0.5)
    for rect, color in zip(bars, (PALETTE["sky"], PALETTE["green"], PALETTE["purple"])):
        rect.set_facecolor(color); rect.set_edgecolor("none")
    ax.set_xticks([0, 1, 2])
    ax.set_xticklabels([label(lang, "m_green"), label(lang, "m_absorb"), label(lang, "m_save")])
    ax.set_ylabel(label(lang, "rate_y"))
    ax.set_title(t["pro_rate"], fontsize=style["font_size"] + 1)
    lo, hi = _bar_limits(v)
    ax.set_ylim(lo, hi)
    for i, z in enumerate(v):
        if np.isfinite(z):
            ax.text(i, z + 0.03 * (hi - lo), f"{z:.2f}%", ha="center", va="bottom",
                    fontsize=style["font_size"])
    _tick_rotation(ax, 20)
    decorate(ax)

    fig.suptitle(t["pro"], fontsize=style["title_size"], fontweight="bold")
    return save(fig, out_dir, "fig_pro_metrics", lang, style)


def _sens_dual(ax, table, style, xkey, ylabel_left, ylabel_right):
    """成本（左轴）+ 未自用率（右轴）+ 最低点标记，对应 MATLAB 的四个成本面板。"""
    xs = table["capacity"].to_numpy(float)
    cost = table["annual_total"].to_numpy(float) / 1e4
    unused = table["unused_rate"].to_numpy(float)
    ax.plot(xs, cost, "-o", color=PALETTE["blue"], markersize=2.6, label=ylabel_left)
    ax.set_xlabel(xkey)
    ax.set_ylabel(ylabel_left)
    i_min = int(np.argmin(cost))
    ax.plot(xs[i_min], cost[i_min], "v", color=PALETTE["blue"], markersize=4.5, zorder=5)
    twin = ax.twinx()
    twin.plot(xs, unused, "--s", color=PALETTE["verm"], markersize=2.6,
              linewidth=style["line_width"] * 0.9, label=ylabel_right)
    twin.set_ylabel(ylabel_right)
    twin.grid(False)
    twin.minorticks_on()
    handles = ax.get_lines() + twin.get_lines()
    ax.legend(handles, [h.get_label() for h in handles], loc="upper right",
              frameon=False, fontsize=style["font_size"] - 1)


def _plot_sensitivity(sensitivity, cfg, lang, style, out_dir):
    t = TITLES[lang]
    tx = SENS_TEXT[lang]
    scans = sensitivity["scans"]
    fig, axes = plt.subplots(4, 2, figsize=(24.0 * CM, 14.0 * CM), layout="constrained")
    for ax, (dim, kind, key) in zip(axes.ravel(), SENS_PANELS):
        table = scans.get(dim)
        if table is None or table.empty:
            ax.axis("off"); continue
        xs = table["capacity"].to_numpy(float)
        ax.set_title(tx[key], fontsize=style["font_size"])

        if kind == "cost_unused":
            _sens_dual(ax, table, style, tx[X_KEYS[dim]], tx["yCost"], tx["yUnused"])
        elif kind == "util":
            ax.plot(xs, table["self_rate"], "-o", color=PALETTE["blue"], markersize=2.6, label=tx["selfRate"])
            ax.plot(xs, table["sell_rate"], "--s", color=PALETTE["verm"], markersize=2.6, label=tx["sellRate"])
            ax.plot(xs, table["curt_rate"], ":^", color=PALETTE["green"], markersize=2.6, label=tx["curtRate"])
            ax.set_xlabel(tx["xE"]); ax.set_ylabel(tx["yRate"])
            ax.legend(loc="upper right", frameon=False, fontsize=style["font_size"] - 1)
        elif kind == "cost_split":
            for col, color, name in (("capex_pv", "orange", tx["capexPv"]), ("capex_wt", "sky", tx["capexWt"]),
                                     ("capex_ess", "purple", tx["capexEss"]), ("capex_op", "grey", tx["opCost"])):
                ax.plot(xs, table[col], "-o", color=PALETTE[color], markersize=2.4, linewidth=style["line_width"] * 0.9, label=name)
            ax.set_xlabel(tx["xE"]); ax.set_ylabel(tx["yCapex"])
            ax.legend(loc="upper right", frameon=False, fontsize=style["font_size"] - 1, ncol=2)
        else:   # gen_share
            ax.plot(xs, table["gen_share"], "-o", color=PALETTE["blue"], markersize=2.6, label=tx["yGenShare"])
            ax.set_xlabel(tx["xGen"]); ax.set_ylabel(tx["yGenShare"])
            twin = ax.twinx()
            twin.plot(xs, table["gen_lcoe_yuan"], "--^", color=PALETTE["verm"], markersize=2.6,
                      linewidth=style["line_width"] * 0.9, label=tx["yGenLcoe"])
            twin.set_ylabel(tx["yGenLcoe"])
            twin.grid(False); twin.minorticks_on()
            handles = ax.get_lines() + twin.get_lines()
            ax.legend(handles, [h.get_label() for h in handles], loc="upper right",
                      frameon=False, fontsize=style["font_size"] - 1)
        decorate(ax)

    fig.suptitle(f"{t['sensitivity']}", fontsize=style["title_size"], fontweight="bold")
    return save(fig, out_dir, "fig_sensitivity", lang, style)


# --------------------------------------------------------------------------
# 入口
# --------------------------------------------------------------------------
def make_plots(result, metric: dict, dispatch: dict, sc, week_dispatch: dict | None, week_sc,
               sensitivity: dict | None, cfg: dict, out_dir: Path):
    """按 config.py 的开关与语言列表生成全部图表。"""
    out_dir = Path(out_dir)
    flags = cfg["out"]["plot"]
    for lang in cfg["out"]["languages"]:
        style = _style_of(cfg)
        apply_style(lang, style)
        if flags.get("pso"):
            _plot_pso(result, lang, style, out_dir)
        if flags.get("source"):
            _plot_source(sc, dispatch, result.cap, lang, style, out_dir)
        if flags.get("dispatch"):
            _plot_dispatch(sc, dispatch, result.cap, lang, style, out_dir)
        if flags.get("soc"):
            _plot_soc(sc, dispatch, result.cap, cfg, lang, style, out_dir)
        if flags.get("week") and week_dispatch and week_dispatch.get("ok"):
            _plot_week(week_dispatch, week_sc, result.cap, lang, style, out_dir)
        if flags.get("cost"):
            _plot_cost(dispatch, metric, result.cap, lang, style, out_dir)
        if flags.get("pro"):
            _plot_pro_metrics(dispatch, result.cap, cfg, sc, lang, style, out_dir)
        if flags.get("sensitivity") and sensitivity:
            _plot_sensitivity(sensitivity, cfg, lang, style, out_dir)
