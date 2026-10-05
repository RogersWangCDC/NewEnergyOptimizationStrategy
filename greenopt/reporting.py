"""生成中英文 Excel 工作簿和 JSON 结果快照。

工作表清单与口径逐张对齐原 MATLAB 版 ``run_greenopt.m`` 的 ``gopt_export`` (L4747)：

    最优配置 / 成本与电量 / 分档明细 / 典型日调度 / 典型周调度 /
    全年SOC充放电 / 全年SOC逐小时 / PSO收敛 / 搜索设置 / 数据说明 /
    专业指标 / 全年核准 / 敏感性分析

中英双语各出一套（除「全年SOC逐小时」为纯数值表）；全部表带表头底色、边框、
列宽自适应、数字格式与冻结首行。行数超过 ``_FAST_ROWS`` 的表走批量写入快通道，
避免逐格上样式导致 8760 行表导出极慢。
"""
from __future__ import annotations

import json
import unicodedata
from pathlib import Path

import numpy as np
from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

_FAST_ROWS = 2000        # 超过此行数的表改用批量写入（不逐格描边）

# --------------------------------------------------------------------------
# 文案
# --------------------------------------------------------------------------
T = {
    "item": ("项目", "Item"), "value": ("数值", "Value"), "unit": ("单位", "Unit"),
    "note": ("说明", "Note"), "cost_item": ("成本项", "Cost item"),
    "energy_item": ("电量项", "Energy item"), "index": ("指标", "Metric"),
    "basis": ("口径 / 说明", "Basis / note"), "pct": ("占比 (%)", "Share (%)"),
    "device": ("设备", "Asset"), "capacity": ("容量", "Capacity"),
    "unit_price": ("命中单价", "Unit price"), "tier_desc": ("档位说明", "Tier"),
    "annual": ("年化投资(万元/年)", "Annualised (10^4 CNY/yr)"),
    "seq": ("序号", "#"), "iteration": ("迭代代数", "Iteration"),
    "gbest": ("群体最优(万元/年)", "Global best (10^4 CNY/yr)"),
    "gmean": ("种群均值(万元/年)", "Swarm mean (10^4 CNY/yr)"),
    "hour": ("时刻(h)", "Hour"), "day_no": ("典型日", "Day index"),
    "days": ("代表天数", "Days represented"),
    "buy_price": ("购电价(元/kWh)", "Purchase price (CNY/kWh)"),
    "sell_price": ("售电价(元/kWh)", "Sale price (CNY/kWh)"),
    "load": ("负荷(MW)", "Load (MW)"),
    "pv_used": ("光伏出力(MW)", "PV used (MW)"), "wt_used": ("风电出力(MW)", "Wind used (MW)"),
    "gen_used": ("自发电出力(MW)", "Gen used (MW)"), "gen_pu": ("自发电标幺(-)", "Gen p.u. (-)"),
    "buy": ("购电量(MW)", "Grid buy (MW)"), "sell": ("售电量(MW)", "Grid sell (MW)"),
    "charge": ("储能充电(MW)", "ESS charge (MW)"), "discharge": ("储能放电(MW)", "ESS discharge (MW)"),
    "ess_net": ("储能净出力(MW)", "ESS net (MW)"),
    "soc_mwh": ("SOC(MWh)", "SOC (MWh)"), "soc_pct": ("SOC(%)", "SOC (%)"),
    "curt_pv": ("弃光伏(MW)", "Curtail PV (MW)"), "curt_wt": ("弃风电(MW)", "Curtail wind (MW)"),
    "curt_gen": ("弃自发电(MW)", "Curtail gen (MW)"),
}

SHEETS = {
    "summary": ("最优配置", "Optimum configuration"),
    "cost_energy": ("成本与电量", "Cost and energy"),
    "tier": ("分档明细", "Tiered price detail"),
    "day": ("典型日调度", "Representative day"),
    "week": ("典型周调度", "Typical week"),
    "soc_sum": ("全年SOC充放电", "Full-year ESS throughput"),
    "soc_hourly": ("全年SOC逐小时", "Full-year hourly ESS"),
    "pso": ("PSO收敛", "PSO convergence"),
    "search": ("搜索设置", "Search settings"),
    "data": ("数据说明", "Data notes"),
    "pro": ("专业指标", "Professional metrics"),
    "validate": ("全年核准", "Full-year validation"),
    "sens": ("敏感性分析", "Sensitivity analysis"),
}

_HEAD_FILL = PatternFill("solid", fgColor="0072B2")
_HEAD_FONT = Font(bold=True, color="FFFFFF", size=10)
_TITLE_FONT = Font(bold=True, size=11)
_BODY_FONT = Font(size=10)
_SIDE = Side(style="thin", color="B0B0B0")
_BORDER = Border(left=_SIDE, right=_SIDE, top=_SIDE, bottom=_SIDE)
_CENTER = Alignment(horizontal="center", vertical="center")
_LEFT = Alignment(horizontal="left", vertical="center")
_RIGHT = Alignment(horizontal="right", vertical="center")

NUM = "0.###"


def t(lang: str, key: str) -> str:
    return T[key][0 if lang == "zh" else 1]


def sheet_name(key: str, lang: str) -> str:
    base, en = SHEETS[key]
    return (base if lang == "zh" else en)[:28] + ("_zh" if lang == "zh" else "_en")


def _clean(value):
    if isinstance(value, np.generic):
        value = value.item()
    if isinstance(value, float) and not np.isfinite(value):
        return "—"
    return value


def _text_width(value) -> int:
    """按东亚全角字符计 2 列的显示宽度，用于列宽自适应。"""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in str(value))


# --------------------------------------------------------------------------
# 写表：小叶走装饰通道，大表走批量快通道
# --------------------------------------------------------------------------
def _write_block(ws, row: int, title, header, rows, *, freeze=False, number_format=None,
                 left_align_cols=(1,)):
    """写「标题 + 表头 + 数据」块，返回下一块起始行。"""
    if title:
        ws.cell(row=row, column=1, value=title).font = _TITLE_FONT
        row += 1
    head_row = row
    for j, name in enumerate(header, start=1):
        cell = ws.cell(row=row, column=j, value=name)
        cell.fill, cell.font, cell.alignment, cell.border = _HEAD_FILL, _HEAD_FONT, _CENTER, _BORDER
    row += 1
    for record in rows:
        for j, raw in enumerate(record, start=1):
            cell = ws.cell(row=row, column=j, value=_clean(raw))
            cell.font, cell.border = _BODY_FONT, _BORDER
            cell.alignment = (_LEFT if j in left_align_cols
                              else _RIGHT if isinstance(raw, (int, float)) else _LEFT)
            if number_format and j in number_format and isinstance(raw, (int, float)):
                cell.number_format = number_format[j]
        row += 1
    if freeze:
        ws.freeze_panes = ws.cell(row=head_row + 1, column=1)
    return row + 1


def _write_big(ws, title, header, rows, *, number_format=None):
    """大表批量写入：用 ws.append 提升速度，数字格式按列设置。"""
    if title:
        ws.append([title])
    ws.append(list(header))
    head_row = ws.max_row
    for j in range(1, len(header) + 1):
        cell = ws.cell(row=head_row, column=j)
        cell.fill, cell.font, cell.alignment, cell.border = _HEAD_FILL, _HEAD_FONT, _CENTER, _BORDER
    for record in rows:
        ws.append([_clean(v) for v in record])
    ws.freeze_panes = ws.cell(row=head_row + 1, column=1)
    for j, fmt in (number_format or {}).items():
        ws.column_dimensions[get_column_letter(j)].number_format = fmt


def _emit(ws, row, title, header, rows, **kwargs):
    """按行数自动选择写入通道。"""
    if len(rows) > _FAST_ROWS:
        _write_big(ws, title, header, rows, number_format=kwargs.get("number_format"))
        return ws.max_row + 2
    return _write_block(ws, row, title, header, rows, **kwargs)


def _autofit(ws, max_width: int = 44, limit_rows: int = 400) -> None:
    for j, column in enumerate(ws.iter_cols(), start=1):
        best = 0
        for i, cell in enumerate(column):
            if i > limit_rows:
                break
            if cell.value is not None:
                best = max(best, _text_width(cell.value))
        ws.column_dimensions[get_column_letter(j)].width = min(max(best + 3, 10), max_width)


# --------------------------------------------------------------------------
# 各表内容
# --------------------------------------------------------------------------
def _tier_info(capacity: float, flat: float, tiers, mode: str, cap_unit: str, price_unit: str):
    """返回 (命中单价, 档位说明)，与 economics.unit_price 的取价规则保持一致。"""
    table = np.asarray(tiers, float)
    if mode == "flat" or table.size == 0:
        return float(flat), f"常数单价 {flat:g} {price_unit}"
    if capacity >= table[-2, 0]:
        return float(table[-1, 1]), f"容量 ≥ {table[-2, 0]:g} {cap_unit}，取末档 {table[-1, 1]:g} {price_unit}"
    below, above = table[table[:, 0] <= capacity], table[table[:, 0] > capacity]
    lo = below[-1, 0] if len(below) else table[0, 0]
    hi = above[0, 0] if len(above) else table[-1, 0]
    price = float(np.interp(capacity, table[:, 0], table[:, 1]))
    return price, f"区间 {lo:g}~{hi:g} {cap_unit} 内分段线性插值，单价 {price:.2f} {price_unit}"


def _sheet_summary(ws, lang, result, metric, dispatch, validation, cfg):
    e, cap, detail = dispatch["energy"], result.cap, metric["cost_detail"]
    load_mwh = e["load"] or np.nan
    rows = [
        ("光伏最优容量 / PV", cap[0], "MW"),
        ("风电最优容量 / Wind", cap[1], "MW"),
        ("储能最优功率 / ESS power", cap[2], "MW"),
        ("储能最优时长 / ESS duration", result.s[3], "h"),
        ("储能最优容量 / ESS energy", cap[3], "MWh"),
        ("厂内自发电最优容量 / Gen", cap[4], "MW"),
        ("年化总成本 / Annual total", metric["annual_total"] / 1e4, "万元/年"),
        ("其中：年化投资成本 / CAPEX", metric["annual_capex"] / 1e4, "万元/年"),
        ("其中：年化运行成本 / OPEX", metric["annual_operation"] / 1e4, "万元/年"),
        ("年化总成本(全年8760h核准) / Validated",
         (validation["metric"]["annual_total"] / 1e4) if validation else None, "万元/年"),
        ("单位负荷年化用电成本 / Cost per MWh load",
         metric["annual_total"] / load_mwh if load_mwh else None, "元/(MWh·年)"),
        ("外层求解模式 / Search mode",
         "固定配置（仅内层调度）/ Fixed" if result.fixed_mode else "PSO + 局部精修 / PSO + refine", ""),
        ("内层求解次数 / MILP solves", result.n_eval, "次"),
        ("寻优耗时 / Wall time", result.elapsed, "s"),
        ("初始投资合计 / Total investment", detail["total_investment"] / 1e4, "万元"),
        ("储能实际寿命(年化口径) / ESS life used", detail["ess_life"], "年"),
    ]
    _write_block(ws, 1, SHEETS["summary"][0 if lang == "zh" else 1],
                 (t(lang, "item"), t(lang, "value"), t(lang, "unit")), rows, freeze=True,
                 number_format={2: "0.0000"})


def _sheet_cost_energy(ws, lang, result, metric, dispatch, cfg):
    e, detail, gen = dispatch["energy"], metric["cost_detail"], cfg["cost"]["gen"]
    cost_rows = [
        ("购电成本 / Grid purchase", dispatch["cost_buy"] / 1e4, "Σ 购电价 × 购电量"),
        ("售电收益 / Grid sale revenue", dispatch["revenue_sell"] / 1e4, "Σ 售电价 × 售电量（抵减）"),
        ("自发电运行成本 / Gen fuel", dispatch["cost_gen_var"] / 1e4,
         f"实发电量 × {gen['var_cost']:.2f} 元/kWh（弃电部分不付费）"),
        ("净运行成本 / Net operation", dispatch["cost"] / 1e4, "购电 − 售电 + 自发电运行"),
        ("初始投资合计 / Total investment", detail["total_investment"] / 1e4,
         f"口径：cost.mode = {cfg['cost']['mode']}"),
        ("光伏年化投资 / PV capex", detail["pv"]["annual"] / 1e4,
         f"寿命 {cfg['cost']['pv']['life']} 年，运维 {cfg['cost']['pv']['opex_rate'] * 100:.1f}%/年"),
        ("风电年化投资 / Wind capex", detail["wt"]["annual"] / 1e4,
         f"寿命 {cfg['cost']['wt']['life']} 年，运维 {cfg['cost']['wt']['opex_rate'] * 100:.1f}%/年"),
        ("储能年化投资 / ESS capex", (detail["ess_p"]["annual"] + detail["ess_e"]["annual"]) / 1e4,
         f"功率 + 容量两块；实际寿命 {detail['ess_life']:.2f} 年"),
        ("自发电年化投资 / Gen capex", detail["gen"]["annual"] / 1e4,
         f"寿命 {cfg['cost']['gen']['life']} 年，运维 {cfg['cost']['gen']['opex_rate'] * 100:.1f}%/年"),
        ("年化总成本 / Annual total", metric["annual_total"] / 1e4, "运行成本 + 投资成本"),
    ]
    row = _write_block(ws, 1, "成本项 / Cost",
                       (t(lang, "cost_item"), t(lang, "value") + " (万元/年)", t(lang, "note")),
                       cost_rows, freeze=True, number_format={2: "0.00"})

    ren_avail = e["pv_avail"] + e["wt_avail"]
    energy_rows = [
        ("负荷电量 / Load", e["load"], "典型日加权年化"),
        ("购电量 / Grid purchase", e["buy"], ""),
        ("售电量 / Grid sell", e["sell"], ""),
        ("储能充电量 / ESS charge", e["charge"], ""),
        ("储能放电量 / ESS discharge", e["discharge"], ""),
        ("光伏+风电可用量 / Renewable available", ren_avail, "绿电口径（不含自发电）"),
        ("自发电可用量 / Gen available", e["gen_avail"], "= 自发电容量 × Σ标幺出力"),
        ("自发电实发电量 / Gen generated", e["gen"], "= 可用量 − 弃自发电"),
        ("弃风弃光电量 / Curtailment", e["pv_curt"] + e["wt_curt"] + e["gen_curt"],
         "= 弃光伏 + 弃风电 + 弃自发电"),
        ("  其中 弃光伏 / of which PV", e["pv_curt"], ""),
        ("  其中 弃风电 / of which wind", e["wt_curt"], ""),
        ("  其中 弃自发电 / of which gen", e["gen_curt"], ""),
        ("光伏+风电利用率(%) / Renewable utilisation",
         (1 - (e["pv_curt"] + e["wt_curt"]) / ren_avail) * 100 if ren_avail > 1e-9 else None,
         "未装光伏/风电时无定义"),
        ("自发电利用率(%) / Gen utilisation",
         (1 - e["gen_curt"] / e["gen_avail"]) * 100 if e["gen_avail"] > 1e-9 else None,
         "未建自发电时无定义"),
        ("可再生能源利用率(%) / Overall utilisation",
         (1 - (e["pv_curt"] + e["wt_curt"] + e["gen_curt"]) / (ren_avail + e["gen_avail"])) * 100
         if (ren_avail + e["gen_avail"]) > 1e-9 else None, "合计口径"),
    ]
    _write_block(ws, row, "电量项 / Energy",
                 (t(lang, "energy_item"), t(lang, "value") + " (MWh/年)", t(lang, "note")),
                 energy_rows, number_format={2: "0.0"})


def _sheet_tier(ws, lang, result, metric, cfg):
    cap, c = result.cap, cfg["cost"]
    devices = [
        ("光伏 / PV", cap[0], c["pv"]["capex"], c["pv"]["tier"], "MW", "元/kW", "pv"),
        ("风电 / Wind", cap[1], c["wt"]["capex"], c["wt"]["tier"], "MW", "元/kW", "wt"),
        ("储能功率 / ESS power", cap[2], c["ess"]["capex_p"], c["ess"]["tier_p"], "MW", "元/kW", "ess_p"),
        ("储能容量 / ESS energy", cap[3], c["ess"]["capex_e"], c["ess"]["tier_e"], "MWh", "元/kWh", "ess_e"),
    ]
    rows = []
    for name, capacity, flat, tiers, cap_unit, price_unit, key in devices:
        price, desc = _tier_info(capacity, flat, tiers, c["mode"], cap_unit, price_unit)
        rows.append((name, capacity, cap_unit, price, price_unit, desc,
                     metric["cost_detail"][key]["annual"] / 1e4))
    row = _write_block(ws, 1, "本次命中档 / Effective tier",
                       (t(lang, "device"), t(lang, "capacity"), t(lang, "unit"), t(lang, "unit_price"),
                        "", t(lang, "tier_desc"), t(lang, "annual")), rows, freeze=True,
                       number_format={2: "0.####", 4: "0.##", 7: "0.00"})

    table_rows = []
    for name, _capacity, _flat, tiers, cap_unit, price_unit, _key in devices:
        table = np.asarray(tiers, float)
        for k, (brk, price) in enumerate(table):
            table_rows.append((name, float(brk), cap_unit, float(price), price_unit,
                               "末档（容量 ≥ 倒数第二档时直接取本档单价）" if k == len(table) - 1 else ""))
    _write_block(ws, row, "逐档对照表 / Tier table",
                 (t(lang, "device"), t(lang, "capacity"), t(lang, "unit"), t(lang, "unit_price"), "",
                  t(lang, "note")), table_rows, number_format={2: "0.####", 4: "0.##"})


def _dispatch_rows(sc, dispatch, cap):
    """逐时调度明细，列序与 MATLAB gopt_sheet 一致（序号在标题栏另加）。"""
    n = sc.n
    soc = dispatch["soc"]
    e_ess = max(float(cap[3]), 1e-12)
    gen_pu = dispatch["gen"] / cap[4] if cap[4] > 1e-9 else np.zeros(n)
    return np.column_stack([
        np.arange(1, n + 1), sc.day_id + 1, np.tile(np.arange(1, 25), n // 24), sc.weight,
        sc.buy_price, sc.sell_price, sc.load,
        dispatch["pv"], dispatch["wt"], dispatch["gen"], gen_pu,
        dispatch["buy"], dispatch["sell"], dispatch["charge"], dispatch["discharge"],
        dispatch["discharge"] - dispatch["charge"],
        soc[:-1], soc[:-1] / e_ess * 100,
        dispatch["pv_curt"], dispatch["wt_curt"], dispatch["gen_curt"],
    ]).tolist()


def _write_dispatch_sheet(ws, lang, sc, dispatch, cap, key):
    header = [t(lang, "seq"), t(lang, "day_no"), t(lang, "hour"), t(lang, "days"),
              t(lang, "buy_price"), t(lang, "sell_price"), t(lang, "load"),
              t(lang, "pv_used"), t(lang, "wt_used"), t(lang, "gen_used"), t(lang, "gen_pu"),
              t(lang, "buy"), t(lang, "sell"), t(lang, "charge"), t(lang, "discharge"),
              t(lang, "ess_net"), t(lang, "soc_mwh"), t(lang, "soc_pct"),
              t(lang, "curt_pv"), t(lang, "curt_wt"), t(lang, "curt_gen")]
    _emit(ws, 1, SHEETS[key][0 if lang == "zh" else 1], header, _dispatch_rows(sc, dispatch, cap),
          freeze=True, number_format={i: NUM for i in range(4, 22)})


def _sheet_pso(ws, lang, result):
    hist = np.asarray(result.history, float)
    if hist.ndim == 1:
        hist = np.column_stack([hist, hist])
    rows = [(i, hist[i, 0] / 1e4, hist[i, 1] / 1e4) for i in range(hist.shape[0])]
    _write_block(ws, 1, SHEETS["pso"][0 if lang == "zh" else 1],
                 (t(lang, "iteration"), t(lang, "gbest"), t(lang, "gmean")), rows, freeze=True,
                 number_format={2: "0.0000", 3: "0.0000"})


def _search_rows(lang, cfg):
    pso, s = cfg["pso"], cfg["sensitivity"]
    names = ["光伏容量", "风电容量", "储能功率", "储能时长", "自发电容量"]
    rows = [(f"优化变量 {i + 1} {nm}",
             f"搜索范围 [{lo:g}, {hi:g}] {'h' if i == 3 else 'MW'}")
            for i, (nm, lo, hi) in enumerate(zip(names, pso["lb"], pso["ub"]))]
    rows += [
        ("储能容量关系", "储能容量(MWh) = 储能功率(MW) × 储能时长(h)"),
        ("Gen 列口径", f"data.gen_mode = '{cfg['data']['gen_mode']}'"),
        ("时间尺度模式", cfg["time"]["mode"]),
        ("成本计价口径", f"cost.mode = '{cfg['cost']['mode']}'，贴现率 {cfg['cost']['discount_rate']:.1%}"),
        ("PSO 粒子数 × 迭代数", f"{pso['n_pop']} × {pso['max_iter']}"),
        ("两阶段搜索", (f"开启（阶段A {pso['stage_a']['n_pop']} × {pso['stage_a']['max_iter']}，"
                    f"K = {pso['stage_a']['k']}，收缩 {pso['stage_a']['shrink']:.0%}）")
         if pso["two_stage"] else "关闭"),
        ("参数自适应", "开启" if pso["adaptive"] else "关闭"),
        ("局部精修", (f"开启（上限 {pso['refine_max_eval']} 次，起始步长 {pso['refine_step0']:.2f}）")
         if pso["local_refine"] else "关闭"),
        ("随机种子", pso["seed"]),
        ("敏感性扫描", f"{s.get('n_point', '-')} 点，±{s.get('rel_range', 0):.0%}"),
        ("MILP 求解器", f"{cfg['milp']['solver']}，相对间隙 {cfg['milp']['rel_gap']:g}，"
                    f"时限 {cfg['milp']['time_limit']} s"),
        ("储能充放互斥", "开启" if cfg["milp"]["cd_binary"] else "关闭"),
    ]
    return rows


def _sheet_data_notes(ws, lang, sc, dispatch, cfg, week_sc):
    e = dispatch["energy"]
    rows = [
        ("数据文件", str(cfg["path"].get("data_file", ""))),
        ("数据时长", f"{sc.n} 小时 / {sc.n // 24} 天"),
        ("时间尺度模式", sc.mode),
        ("Gen 列口径", f"data.gen_mode = '{cfg['data']['gen_mode']}'"),
        ("储能参数", f"η_ch {cfg['ess']['eta_ch']}，η_dis {cfg['ess']['eta_dis']}，"
                 f"SOC {cfg['ess']['soc_min']:.0%}~{cfg['ess']['soc_max']:.0%}，"
                 f"自放电 {cfg['ess']['self_dis']:g}/h"),
        ("储能寿命口径", f"life_mode = {cfg['ess']['life_mode']}，额定循环 {cfg['ess']['cycle_life']:g} 次，"
                   f"本次等效循环 {dispatch.get('equiv_cycles', 0):.3f} 次"),
        ("分源弃电合计校验(MWh)",
         f"弃光伏 {e['pv_curt']:.1f} + 弃风电 {e['wt_curt']:.1f} + 弃自发电 {e['gen_curt']:.1f} = "
         f"{e['pv_curt'] + e['wt_curt'] + e['gen_curt']:.1f}"),
        ("自发电电量校验(MWh)",
         f"可用 {e['gen_avail']:.1f} − 弃 {e['gen_curt']:.1f} = 实发 {e['gen']:.1f}"),
        ("典型周数据", f"{week_sc.n} 小时（week_mode = {cfg['time']['week_mode']}）"),
        ("内层求解器", f"HiGHS（scipy.optimize.milp，solver = {cfg['milp']['solver']}）"),
        ("全年SOC逐小时表", "8760 行 × 3 列（时间序号 / 充电MW / 放电MW），Δt = 1 h 故数值上即 MWh"),
        ("绘图样式口径", f"正文 {cfg['out']['style']['font_size']} pt / 标题 "
                   f"{cfg['out']['style']['title_size']} pt / 柱标 "
                   f"{cfg['out']['style']['bar_label_font_size']} pt，{cfg['out']['dpi']} dpi，"
                   f"中文字体 宋体 + Times New Roman 混排"),
    ]
    _write_block(ws, 1, SHEETS["data"][0 if lang == "zh" else 1], (t(lang, "item"), t(lang, "note")),
                 rows, freeze=True)


def _sheet_pro(ws, lang, result, metric, dispatch, cfg, sc):
    from .economics import metrics_pro
    pro = metrics_pro(dispatch, result.cap, cfg, sc)
    e, detail = dispatch["energy"], metric["cost_detail"]
    e_load = e["load"] or np.nan
    gen_lcoe = ((detail["gen"]["annual"] + dispatch["cost_gen_var"]) / (e["gen"] * 1000)
                if e["gen"] > 1e-9 else np.nan)
    rows = [
        ("用户绿电占用电量比例 / Green share of load", pro["green_rate"], "%",
         "= （负荷电量 − 购电量）/ 负荷电量"),
        ("新能源发电量消纳比例 / Renewable absorption", pro["absorb_rate"], "%",
         "= 100 − 弃电率（绿电口径，不含自发电）"),
        ("用电成本综合节省率 / Cost saving rate", pro["save_rate"], "%",
         "= （基准购电成本 − 年化总成本）/ 基准购电成本"),
        ("  基准购电成本 / Baseline purchase cost", pro["baseline_purchase_cost"] / 1e4, "万元/年",
         "不建任何绿电、负荷全靠电网买电的年电费"),
        ("  年化总成本 / Annualised total", pro["annual_total"] / 1e4, "万元/年", "投资 + 运行"),
        ("用户综合度电成本 / Average price",
         pro["annual_total"] / (e_load * 1000) if e_load else np.nan, "元/kWh",
         "= 年化总成本 / 年用电量"),
        ("基准购电均价 / Baseline price",
         pro["baseline_purchase_cost"] / (e_load * 1000) if e_load else np.nan, "元/kWh",
         "= 基准购电成本 / 年用电量"),
        ("绿电度电成本 LCOE（发电口径） / LCOE, generation basis", pro["lcoe_gen"], "元/kWh",
         f"分子 = 风光储年化投资 {pro['asset_annual'] / 1e4:.2f} 万元/年；"
         f"分母 = 风光扣弃电发电量 {pro['e_gen_green']:.1f} MWh/年"),
        ("绿电度电成本 LCOE（消纳口径） / LCOE, consumption basis", pro["lcoe_con"], "元/kWh",
         f"分子 = 风光储年化投资；分母 = 绿电供负荷电量 {pro['e_green_load']:.1f} MWh/年"),
        ("绿电 LCOE（含自发电对照） / LCOE incl. gen", metric["lcoe_green_yuan_per_kwh"], "元/kWh",
         "分子含自发电投资与运行成本，分母含自发电发电量；用于纵向对比"),
        ("储能年损耗电量 / ESS losses", e["charge"] - e["discharge"], "MWh/年",
         "= 年充电量 − 年放电量（含转换损耗与自放电）"),
        ("储能年损耗占充电量比例 / Loss ratio",
         (e["charge"] - e["discharge"]) / e["charge"] * 100 if e["charge"] > 1e-9 else np.nan, "%",
         "= 年损耗电量 / 年充电量"),
        ("自发电装机容量 / Gen capacity", result.cap[4], "MW",
         f"投资 {cfg['cost']['gen']['capex']:g} 元/kW"),
        ("自发电可用电量 / Gen available", e["gen_avail"], "MWh/年", "= 容量 × Σ标幺出力"),
        ("自发电实发电量 / Gen generated", e["gen"], "MWh/年", "= 可用电量 − 弃自发电"),
        ("自发电利用率 / Gen utilisation",
         (1 - e["gen_curt"] / e["gen_avail"]) * 100 if e["gen_avail"] > 1e-9 else np.nan, "%",
         "= 实发电量 / 可用电量"),
        ("自发电度电成本 / Gen LCOE", gen_lcoe, "元/kWh",
         "= （年化投资 + 年运行成本）/ 实发电量；弃电越多该值越高"),
        ("比价参照 光伏全成本 / PV reference LCOE",
         detail["pv"]["annual"] / (e["pv"] * 1000) if e["pv"] > 1e-9 else np.nan, "元/kWh",
         "= 光伏年化投资 /（光伏扣弃电发电量 × 1000）"),
        ("比价参照 风电全成本 / Wind reference LCOE",
         detail["wt"]["annual"] / (e["wt"] * 1000) if e["wt"] > 1e-9 else np.nan, "元/kWh",
         "= 风电年化投资 /（风电扣弃电发电量 × 1000）"),
    ]
    _write_block(ws, 1, SHEETS["pro"][0 if lang == "zh" else 1],
                 (t(lang, "index"), t(lang, "value"), t(lang, "unit"), t(lang, "basis")), rows,
                 freeze=True, number_format={2: "0.0000"})


def _sheet_validation(ws, lang, sc, dispatch, metric, validation):
    if not validation:
        note = ("本次运行即为全年 8760 h 口径，无需再做典型日核准" if sc.mode == "full_year"
                else "未启用全年核准或核准未求解成功（cfg.out.full_year_check）")
        _write_block(ws, 1, SHEETS["validate"][0 if lang == "zh" else 1],
                     (t(lang, "item"), t(lang, "note")),
                     [(t(lang, "item"), note)])
        return
    v_metric, v_dispatch = validation["metric"], validation["dispatch"]
    use_year = sc.mode == "full_year"
    e = dispatch["energy"] if use_year else v_dispatch["energy"]
    rows = [
        ("全年8760h 年化总成本 / Validated annual total", v_metric["annual_total"] / 1e4, "万元/年"),
        ("全年8760h 年化运行成本 / Validated operation", v_metric["annual_operation"] / 1e4, "万元/年"),
        ("典型日模型 年化总成本 / Representative-day total", metric["annual_total"] / 1e4, "万元/年"),
        ("相对偏差(%) / Deviation",
         (v_metric["annual_total"] - metric["annual_total"]) / metric["annual_total"] * 100
         if metric["annual_total"] else None, "%"),
        ("全年 购电量 / Grid purchase", e["buy"], "MWh"),
        ("全年 售电量 / Grid sell", e["sell"], "MWh"),
        ("全年 储能充电量 / ESS charge", e["charge"], "MWh"),
        ("全年 储能放电量 / ESS discharge", e["discharge"], "MWh"),
        ("全年 弃风弃光电量 / Curtailment", e["pv_curt"] + e["wt_curt"], "MWh"),
        ("全年 自发电实发电量 / Gen generated", e["gen"], "MWh"),
        ("说明", "典型日模型强制每典型日 SOC 日循环，属保守近似，成本通常略高于全年口径"),
    ]
    _write_block(ws, 1, SHEETS["validate"][0 if lang == "zh" else 1],
                 (t(lang, "item"), t(lang, "value"), t(lang, "unit")), rows, freeze=True,
                 number_format={2: "0.00"})


def _sheet_sensitivity(ws, lang, sensitivity):
    if not sensitivity:
        _write_block(ws, 1, SHEETS["sens"][0 if lang == "zh" else 1],
                     (t(lang, "item"), t(lang, "note")),
                     [("状态 / Status", "敏感性分析未启用（cfg.sensitivity.enable）")])
        return
    frame = sensitivity["table"].rename(columns={
        "dimension": "维度 / Dimension", "capacity": "容量 / Capacity",
        "annual_total": "年化总成本(元) / Annual total (CNY)",
        "annual_capex": "年化投资(元) / CAPEX (CNY)",
        "annual_operation": "年化运行(元) / OPEX (CNY)",
        "curtailment_rate": "弃电率 / Curtailment", "self_use_rate": "自用率 / Self-use",
        "green_share": "绿电占比 / Green share", "gen_lcoe": "绿电LCOE(元/kWh) / LCOE",
        "unused_rate": "未自用率(%) / Non-self-used", "sell_rate": "上网率(%) / Grid-sale",
        "curt_rate": "弃电率(%) / Curtailment %",
    })
    if lang == "zh":
        frame["维度 / Dimension"] = frame["维度 / Dimension"].replace(
            {"PV": "光伏", "Wind": "风电", "ESS power": "储能功率",
             "ESS energy": "储能容量", "Generation": "自发电"})
    _write_block(ws, 1, SHEETS["sens"][0 if lang == "zh" else 1], list(frame.columns),
                 frame.to_numpy().tolist(), freeze=True,
                 number_format={i: NUM for i in range(2, len(frame.columns) + 1)})


# --------------------------------------------------------------------------
# 入口
# --------------------------------------------------------------------------
def export_excel(result, metric: dict, dispatch: dict, sc, sensitivity: dict | None, out_dir: Path,
                 validation: dict | None = None, week: tuple | None = None,
                 cfg: dict | None = None) -> Path:
    """把全部结果写入中英文工作簿 ``greenopt_results.xlsx``。"""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "greenopt_results.xlsx"
    week_dispatch, week_sc = week if week else (None, None)
    if cfg is None:
        raise ValueError("export_excel 需要传入 cfg")

    wb = Workbook()
    wb.remove(wb.active)
    for lang in ("zh", "en"):
        _sheet_summary(wb.create_sheet(sheet_name("summary", lang)), lang, result, metric, dispatch, validation, cfg)
        _sheet_cost_energy(wb.create_sheet(sheet_name("cost_energy", lang)), lang, result, metric, dispatch, cfg)
        _sheet_tier(wb.create_sheet(sheet_name("tier", lang)), lang, result, metric, cfg)
        _write_dispatch_sheet(wb.create_sheet(sheet_name("day", lang)), lang, sc, dispatch, result.cap, "day")
        if week_dispatch and week_dispatch.get("ok"):
            _write_dispatch_sheet(wb.create_sheet(sheet_name("week", lang)), lang, week_sc,
                                  week_dispatch, result.cap, "week")
        _sheet_pso(wb.create_sheet(sheet_name("pso", lang)), lang, result)
        _write_block(wb.create_sheet(sheet_name("search", lang)), 1, SHEETS["search"][0 if lang == "zh" else 1],
                     (t(lang, "item"), t(lang, "note")), _search_rows(lang, cfg), freeze=True)
        _sheet_data_notes(wb.create_sheet(sheet_name("data", lang)), lang, sc, dispatch, cfg,
                          week_sc or sc)
        _sheet_pro(wb.create_sheet(sheet_name("pro", lang)), lang, result, metric, dispatch, cfg, sc)
        _sheet_validation(wb.create_sheet(sheet_name("validate", lang)), lang, sc, dispatch, metric, validation)
        _sheet_sensitivity(wb.create_sheet(sheet_name("sens", lang)), lang, sensitivity)

    # 全年 SOC 逐小时：纯数值表，只出一份
    year = dispatch if sc.mode == "full_year" else (validation or {}).get("dispatch")
    if year and len(year.get("charge", [])) == 8760:
        ws = wb.create_sheet(SHEETS["soc_hourly"][0] + "_hourly")
        rows = [(i, year["charge"][i - 1], year["discharge"][i - 1]) for i in range(1, 8761)]
        _write_big(ws, SHEETS["soc_hourly"][0] + " / " + SHEETS["soc_hourly"][1],
                   ("时间(h) / Hour", "储能充电(MW) / Charge", "储能放电(MW) / Discharge"), rows,
                   number_format={1: "0", 2: "0.####", 3: "0.####"})

    for ws in wb.worksheets:
        _autofit(ws)
    wb.save(path)
    return path


def export_json(result, metric: dict, out_dir: Path, pro: dict | None = None) -> Path:
    """写出轻量机器可读摘要，便于复现实验和比较不同配置。"""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "result_summary.json"
    content = {"search_variable": np.asarray(result.s, float).tolist(),
               "capacity": np.asarray(result.cap, float).tolist(),
               "objective_cny_per_year": result.fit,
               "n_evaluations": result.n_eval, "elapsed_seconds": result.elapsed,
               "fixed_mode": bool(result.fixed_mode),
               "metrics": {k: v for k, v in metric.items() if k != "cost_detail"}}
    if pro:
        content["professional_metrics"] = {
            k: (None if isinstance(v, float) and not np.isfinite(v) else v) for k, v in pro.items()}
    path.write_text(json.dumps(content, ensure_ascii=False, indent=2, default=float), encoding="utf-8")
    return path
