"""快速一致性自检；不取代完整算例，但可在改参数后先运行。"""
from __future__ import annotations

import copy
import numpy as np

from .data import build_scenario
from .dispatch import solve_dispatch
from .economics import annual_capex, crf, unit_price


def run_selftest(df, cfg: dict) -> list[tuple[str, bool, str]]:
    """返回可打印的断言结果，覆盖核心单位、成本和能量平衡。"""
    out: list[tuple[str, bool, str]] = []
    def check(name, condition, detail=""):
        out.append((name, bool(condition), detail))
    c = cfg["cost"]
    check("CRF is positive", crf(.06, 25) > 0, "资金回收系数为正")
    price = unit_price(37.5, c["pv"]["capex"], c["pv"]["tier"], "tiered")
    check("Tier interpolation", abs(price - 3041.6666667) < 1e-5, f"PV price={price:.4f}")
    check("Tier top rule", unit_price(500, c["wt"]["capex"], c["wt"]["tier"], "tiered") == c["wt"]["tier"][-1][1], "500 MW 取最后一档")
    short = df.iloc[:24*min(4, len(df)//24)].copy(); cfg2 = copy.deepcopy(cfg)
    cfg2["time"]["mode"] = "typical_days"; cfg2["time"]["n_typical_days"] = min(2, len(short)//24)
    cfg2["milp"]["time_limit"] = 30
    sc = build_scenario(short, cfg2); cap = np.array([30., 20., 10., 20., 10.])
    d = solve_dispatch(cap, sc, cfg2)
    check("MILP solved", d["ok"], d.get("message", ""))
    if d["ok"]:
        balance = d["pv"]+d["wt"]+d["gen"]+d["buy"]+d["discharge"]-d["sell"]-d["charge"]-sc.load
        check("Hourly power balance", np.max(np.abs(balance)) < 1e-6, f"max residual={np.max(np.abs(balance)):.2e}")
        capex, detail = annual_capex(cap, cfg2, d)
        check("Annual capex finite", np.isfinite(capex) and capex > 0, f"{capex:.2f} CNY/y")
        check("ESS capacity conversion", cap[3] == cap[2]*2, "E=P×duration")
    return out
