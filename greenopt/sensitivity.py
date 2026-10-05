"""基于最优配置的一维敏感性分析。

每个扫描点除成本外，还保留**成本明细与消纳指标**，供
`fig_sensitivity` 的 8 子图版式使用（对应 MATLAB ``gopt_plot_sensitivity``）：
成本曲线 / 未自用率 / 自用·上网·弃电率 / 成本构成分解 / 自发电占比与度电成本。
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from .dispatch import solve_dispatch
from .economics import annual_capex, metrics


def _grid(base: float, cfg: dict) -> np.ndarray:
    ref = base if base > 1e-9 else cfg["sensitivity"]["zero_ref"]
    low = 0 if cfg["sensitivity"]["scan_from_zero"] else max(0, ref * (1 - cfg["sensitivity"]["rel_range"]))
    return np.linspace(low, ref * (1 + cfg["sensitivity"]["rel_range"]), cfg["sensitivity"]["n_point"])


def run_sensitivity(result, scenario, cfg: dict) -> dict | None:
    """扫描 PV、风电、储能功率、储能容量和自发电容量。"""
    if not cfg["sensitivity"]["enable"]:
        return None
    base = result.cap.copy()
    scans: dict[str, pd.DataFrame] = {}
    rows = []
    dimensions = [("PV", 0, cfg["sensitivity"]["grid_pv"]), ("Wind", 1, cfg["sensitivity"]["grid_wt"]),
                  ("ESS power", 2, cfg["sensitivity"]["grid_p"]), ("ESS energy", 3, cfg["sensitivity"]["grid_e"]),
                  ("Generation", 4, cfg["sensitivity"]["grid_gen"])]
    for name, idx, specified in dimensions:
        points = np.asarray(specified if specified is not None else _grid(base[idx], cfg), float)
        one = []
        for x in points:
            cap = base.copy()
            cap[idx] = x
            # 改储能功率时保持时长；改储能容量时保持功率（cap[2] 不动，仅时长随之变化）。
            if idx == 2:
                cap[3] = x * (base[3] / base[2] if base[2] > 1e-9 else 2)
            dispatch = solve_dispatch(cap, scenario, cfg)
            if not dispatch["ok"]:
                continue
            capex, detail = annual_capex(cap, cfg, dispatch)
            m = metrics(dispatch, cap, cfg)
            e = dispatch["energy"]
            ren_gen = e["pv"] + e["wt"]
            gen_used = min(e["gen"], max(e["load"] - e["buy"], 0.0))
            one.append({
                "dimension": name, "capacity": x,
                "annual_total": capex + dispatch["cost"],
                "annual_capex": capex, "annual_operation": dispatch["cost"],
                "curtailment_rate": m["curtailment_rate"],
                "self_use_rate": m["renewable_self_use_rate"],
                "green_share": m["green_share_of_load"],
                "gen_lcoe": m["lcoe_green_yuan_per_kwh"],
                # ---- 以下为 8 子图版式补充列 ----
                "unused_rate": (1 - m["renewable_self_use_rate"]) * 100,
                "sell_rate": (e["sell"] / ren_gen * 100) if ren_gen > 1e-9 else 0.0,
                "curt_rate": m["curtailment_rate"] * 100,
                "self_rate": m["renewable_self_use_rate"] * 100,
                "capex_pv": detail["pv"]["annual"] / 1e4,
                "capex_wt": detail["wt"]["annual"] / 1e4,
                "capex_ess": (detail["ess_p"]["annual"] + detail["ess_e"]["annual"]) / 1e4,
                "capex_op": dispatch["cost"] / 1e4,
                "gen_share": (gen_used / e["load"] * 100) if e["load"] > 1e-9 else 0.0,
                "gen_lcoe_yuan": ((detail["gen"]["annual"] + dispatch["cost_gen_var"]) / (e["gen"] * 1000))
                if e["gen"] > 1e-9 else np.nan,
            })
        scans[name] = pd.DataFrame(one)
        rows.extend(one)
    return {"scans": scans, "table": pd.DataFrame(rows)}
