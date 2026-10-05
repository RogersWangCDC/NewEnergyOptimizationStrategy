"""投资成本、寿命和结果指标。"""
from __future__ import annotations

import numpy as np


def crf(rate: float, years: float) -> float:
    """资金回收系数。"""
    return rate / (1 - (1 + rate) ** -years) if rate else 1 / years


def unit_price(capacity: float, flat: float, tiers: list, mode: str) -> float:
    """按原模型规则取得单位造价；达到倒数第二档后采用最后一档价格。"""
    if mode == "flat" or not tiers:
        return float(flat)
    table = np.asarray(tiers, dtype=float)
    if table.ndim != 2 or table.shape[1] != 2 or np.any(np.diff(table[:, 0]) <= 0):
        raise ValueError("分档表必须是容量严格递增的两列数组")
    if capacity >= table[-2, 0]:
        return float(table[-1, 1])
    return float(np.interp(capacity, table[:, 0], table[:, 1]))


def validate_config(cfg: dict) -> None:
    """在求解前拦截分档表和搜索边界中的常见输入错误。"""
    cost = cfg["cost"]
    for name, flat, tiers in (("PV", cost["pv"]["capex"], cost["pv"]["tier"]),
                              ("Wind", cost["wt"]["capex"], cost["wt"]["tier"]),
                              ("ESS power", cost["ess"]["capex_p"], cost["ess"]["tier_p"]),
                              ("ESS energy", cost["ess"]["capex_e"], cost["ess"]["tier_e"])):
        if flat <= 0: raise ValueError(f"{name} 的常数单价必须为正")
        table = np.asarray(tiers, float)
        if table.ndim != 2 or table.shape[0] < 2 or table.shape[1] != 2 or np.any(table[:,1] <= 0) or np.any(np.diff(table[:,0]) <= 0):
            raise ValueError(f"{name} 的分档表必须为容量递增、单价为正的两列数组")
    if cost["mode"] not in ("flat", "tiered"): raise ValueError("cost.mode 必须为 flat 或 tiered")
    if cfg["time"]["mode"] not in ("full_year", "typical_days"): raise ValueError("time.mode 必须为 full_year 或 typical_days")


def annual_capex(cap: np.ndarray, cfg: dict, dispatch: dict | None = None) -> tuple[float, dict]:
    """计算年化投资成本，并给出可直接输出的明细。"""
    pv, wt, ess_p, ess_e, gen = map(float, cap)
    c, mode = cfg["cost"], cfg["cost"]["mode"]
    p = {
        "pv": unit_price(pv, c["pv"]["capex"], c["pv"]["tier"], mode),
        "wt": unit_price(wt, c["wt"]["capex"], c["wt"]["tier"], mode),
        "ess_p": unit_price(ess_p, c["ess"]["capex_p"], c["ess"]["tier_p"], mode),
        "ess_e": unit_price(ess_e, c["ess"]["capex_e"], c["ess"]["tier_e"], mode),
        "gen": c["gen"]["capex"],
    }
    life_ess = c["ess"]["life"]
    if dispatch and ess_e > 1e-9 and cfg["ess"]["life_mode"] == "cycle_min":
        cycles = dispatch.get("equiv_cycles", 0.0)
        if cycles > 1e-9:
            life_ess = max(cfg["ess"]["life_floor"], min(life_ess, cfg["ess"]["cycle_life"] / cycles))
    assets = [("pv", pv, c["pv"]["life"], c["pv"]["opex_rate"]),
              ("wt", wt, c["wt"]["life"], c["wt"]["opex_rate"]),
              ("ess_p", ess_p, life_ess, c["ess"]["opex_rate"]),
              ("ess_e", ess_e, life_ess, c["ess"]["opex_rate"]),
              ("gen", gen, c["gen"]["life"], c["gen"]["opex_rate"])]
    detail, annual = {}, 0.0
    for name, qty, life, opex in assets:
        investment = qty * 1000 * p[name]
        value = investment * (crf(c["discount_rate"], life) + opex)
        detail[name] = {"capacity": qty, "unit_price": p[name], "investment": investment,
                        "life": life, "annual": value}
        annual += value
    detail["total_investment"] = sum(v["investment"] for v in detail.values())
    detail["ess_life"] = life_ess
    return annual, detail


def metrics(dispatch: dict, cap: np.ndarray, cfg: dict) -> dict:
    """计算能量比例、成本和 LCOE 等易读指标。"""
    e = dispatch["energy"]
    annual, detail = annual_capex(cap, cfg, dispatch)
    total = annual + dispatch["cost"]
    green = e["pv"] + e["wt"] + (e["gen"] if cfg["metrics"]["gen_in_green"] else 0.0)
    renewable_avail = e["pv_avail"] + e["wt_avail"]
    return {
        "annual_capex": annual, "annual_operation": dispatch["cost"], "annual_total": total,
        "renewable_self_use_rate": (e["pv"] + e["wt"] - e["sell"]) / renewable_avail if renewable_avail else 0,
        "curtailment_rate": (e["pv_curt"] + e["wt_curt"]) / renewable_avail if renewable_avail else 0,
        "green_share_of_load": green / e["load"] if e["load"] else 0,
        "lcoe_green_yuan_per_kwh": (annual + dispatch["cost_gen_var"]) / (green * 1000) if green else np.nan,
        "grid_purchase_share": e["buy"] / e["load"] if e["load"] else 0,
        "cost_detail": detail,
    }


def baseline_purchase_cost(sc) -> float:
    """基准购电成本：不建任何绿电、负荷全部从电网买电时的年电费（元/年）。

    对应 MATLAB gopt_metrics_pro 的 costBase —— 逐时购电价按权重加权，不含任何投资。
    注意单位：load 为 MW、dt 为 h、电价元/kWh，故需 ×1000 把 MW·h 换成 kWh，
    否则量级会比年化总成本小 1000 倍（与 dispatch 的目标函数同一口径）。
    """
    return float(np.sum(sc.buy_price * sc.load * sc.weight) * sc.dt * 1000)


def metrics_pro(dispatch: dict, cap: np.ndarray, cfg: dict, sc) -> dict:
    """专业化指标：LCOE 双口径 + 三个比例指标（对应 MATLAB gopt_metrics_pro）。

    只为 ``fig_pro_metrics`` 出图服务，不改动 :func:`metrics` 的任何口径，
    两者数值可交叉核对。

    - LCOE 发电口径 = 风光储年化投资 / 风光扣弃电后的实际发电量
    - LCOE 消纳口径 = 风光储年化投资 / 绿电供负荷电量（负荷电量 - 购电量）
    - 用户绿电占比 = （负荷电量 - 购电量）/ 负荷电量
    - 新能源消纳比例 = 1 - 弃电率
    - 成本节省率 = （基准购电成本 - 年化总成本）/ 基准购电成本
    """
    e = dispatch["energy"]
    annual, detail = annual_capex(cap, cfg, dispatch)
    annual_total = annual + dispatch["cost"]
    asset_annual = sum(detail[k]["annual"] for k in ("pv", "wt", "ess_p", "ess_e"))
    e_gen_green = e["pv"] + e["wt"]                       # 风光扣弃电后的实际发电量
    e_green_load = e["load"] - e["buy"]                   # 绿电供负荷电量
    e_load = e["load"] or np.nan
    base = baseline_purchase_cost(sc)
    return {
        "lcoe_gen": asset_annual / (e_gen_green * 1000) if e_gen_green > 1e-9 else np.nan,
        "lcoe_con": asset_annual / (e_green_load * 1000) if e_green_load > 1e-9 else np.nan,
        "green_rate": e_green_load / e_load * 100 if e_load else np.nan,
        "absorb_rate": (1 - (e["pv_curt"] + e["wt_curt"]) / (e["pv_avail"] + e["wt_avail"])) * 100
        if (e["pv_avail"] + e["wt_avail"]) > 1e-9 else np.nan,
        "save_rate": (base - annual_total) / base * 100 if base > 1e-9 else np.nan,
        "asset_annual": asset_annual,
        "baseline_purchase_cost": base,
        "annual_total": annual_total,
        "e_gen_green": e_gen_green,
        "e_green_load": e_green_load,
    }
