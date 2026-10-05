"""内层：给定装机容量后的小时级 MILP 最优调度。"""
from __future__ import annotations

import numpy as np
from scipy.optimize import Bounds, LinearConstraint, milp
from scipy.sparse import lil_matrix

from .data import Scenario


def _periods(scenario: Scenario, cfg: dict) -> list[np.ndarray]:
    """按日、月或全年返回 SOC 闭合区间。"""
    n = scenario.n
    cycle = cfg["ess"].get("cycle_mode", cfg["time"]["year_cyclic"])
    if scenario.mode == "typical_days": cycle = "day"
    if cycle == "year": return [np.arange(n)]
    if cycle == "month" and scenario.mode == "full_year":
        # 数据从 1 月 1 日开始时，按非闰年日历分月；不足全年则按连续 30 日分段。
        lengths = [31,28,31,30,31,30,31,31,30,31,30,31]
        out, start = [], 0
        for length in lengths:
            end = min(n, start + length * 24)
            if end > start: out.append(np.arange(start, end))
            start = end
            if start == n: break
        return out or [np.arange(n)]
    return [np.arange(i, min(i + 24, n)) for i in range(0, n, 24)]


def solve_dispatch(cap: np.ndarray, sc: Scenario, cfg: dict, strict: bool = False) -> dict:
    """求解最小运行成本调度。

    变量为风光/自发电利用、购售电、充放电、SOC 及可选二进制互斥变量；
    未利用的可再生电量在求解后按 ``available - used`` 计算。
    """
    cap = np.asarray(cap, dtype=float)
    if np.any(cap < -1e-9): return {"ok": False, "message": "容量不能为负"}
    pv_cap, wt_cap, p_ess, e_ess, gen_cap = cap
    n, dt = sc.n, sc.dt
    pv_av = pv_cap * sc.pv_pu
    wt_av = wt_cap * sc.wt_pu
    gen_av = sc.gen if cfg["data"]["gen_mode"] == "mw" else gen_cap * sc.gen
    # 索引：每一类时间变量 n 个，SOC 为 n+1 个。
    names = ("pv", "wt", "gen", "buy", "sell", "charge", "discharge")
    offsets = {name: i * n for i, name in enumerate(names)}
    soc0 = len(names) * n
    binary_grid = cfg["milp"]["use_binary"]
    binary_cd = cfg["milp"]["cd_binary"] or strict
    z_grid = soc0 + n + 1 if binary_grid else None
    z_cd = (z_grid + n if binary_grid else soc0 + n + 1) if binary_cd else None
    nvar = soc0 + n + 1 + (n if binary_grid else 0) + (n if binary_cd else 0)
    lb, ub = np.zeros(nvar), np.full(nvar, np.inf)
    for name, avail in (("pv", pv_av), ("wt", wt_av), ("gen", gen_av)):
        ub[offsets[name]:offsets[name]+n] = avail
    ub[offsets["buy"]:offsets["buy"]+n] = cfg["grid"]["import_max"]
    ub[offsets["sell"]:offsets["sell"]+n] = cfg["grid"]["export_max"]
    if not cfg["grid"]["allow_curtail"]:
        lb[offsets["pv"]:offsets["pv"]+n] = pv_av
        lb[offsets["wt"]:offsets["wt"]+n] = wt_av
        lb[offsets["gen"]:offsets["gen"]+n] = gen_av
    ub[offsets["charge"]:offsets["charge"]+n] = p_ess
    ub[offsets["discharge"]:offsets["discharge"]+n] = p_ess
    lb[soc0:soc0+n+1] = cfg["ess"]["soc_min"] * e_ess
    ub[soc0:soc0+n+1] = cfg["ess"]["soc_max"] * e_ess
    if binary_grid: ub[z_grid:z_grid+n] = 1
    if binary_cd: ub[z_cd:z_cd+n] = 1
    # 能量平衡、SOC 演化、循环闭合及互斥约束。
    rows = n + n + sum(len(p) > 0 for p in _periods(sc, cfg)) + (2*n if binary_grid else 0) + (2*n if binary_cd else 0)
    A = lil_matrix((rows, nvar)); lo = np.zeros(rows); hi = np.zeros(rows); row = 0
    for t in range(n):
        for name, sign in (("pv",1),("wt",1),("gen",1),("buy",1),("discharge",1),
                           ("sell",-1),("charge",-1)):
            A[row, offsets[name] + t] = sign
        lo[row] = hi[row] = sc.load[t]; row += 1
    loss, eta_c, eta_d = cfg["ess"]["self_dis"], cfg["ess"]["eta_ch"], cfg["ess"]["eta_dis"]
    for t in range(n):
        A[row, soc0 + t + 1] = 1; A[row, soc0 + t] = -(1 - loss)
        A[row, offsets["charge"] + t] = -eta_c * dt
        A[row, offsets["discharge"] + t] = dt / eta_d
        row += 1
    for period in _periods(sc, cfg):
        start, end = int(period[0]), int(period[-1] + 1)
        A[row, soc0 + end] = 1; A[row, soc0 + start] = -1
        row += 1
        if cfg["ess"]["fix_initial_soc"]:
            # 起点已被边界固定；此行用于让下一段不需要额外状态处理。
            lb[soc0+start] = ub[soc0+start] = cfg["ess"]["soc_init"] * e_ess
    import_max, export_max = cfg["grid"]["import_max"], cfg["grid"]["export_max"]
    if binary_grid:
        for t in range(n):
            A[row, offsets["buy"]+t] = 1; A[row, z_grid+t] = -import_max; lo[row] = -np.inf; hi[row] = 0; row += 1
            A[row, offsets["sell"]+t] = 1; A[row, z_grid+t] = export_max; lo[row] = -np.inf; hi[row] = export_max; row += 1
    if binary_cd:
        for t in range(n):
            A[row, offsets["charge"]+t] = 1; A[row, z_cd+t] = -p_ess; lo[row] = -np.inf; hi[row] = 0; row += 1
            A[row, offsets["discharge"]+t] = 1; A[row, z_cd+t] = p_ess; lo[row] = -np.inf; hi[row] = p_ess; row += 1
    objective = np.zeros(nvar)
    w = sc.weight * dt * 1000  # MW*h -> kWh；典型日成本按代表天数加权。
    objective[offsets["buy"]:offsets["buy"]+n] = sc.buy_price * w
    objective[offsets["sell"]:offsets["sell"]+n] = -sc.sell_price * w
    objective[offsets["gen"]:offsets["gen"]+n] = cfg["cost"]["gen"]["var_cost"] * w
    integrality = np.zeros(nvar, dtype=int)
    if binary_grid: integrality[z_grid:z_grid+n] = 1
    if binary_cd: integrality[z_cd:z_cd+n] = 1
    options = {"time_limit": cfg["milp"]["time_limit"], "mip_rel_gap": cfg["milp"]["rel_gap"]}
    result = milp(objective, integrality=integrality, bounds=Bounds(lb, ub),
                  constraints=LinearConstraint(A.tocsr(), lo, hi), options=options)
    if not result.success or result.x is None:
        return {"ok": False, "message": result.message, "status": result.status}
    x = result.x
    data = {name: x[offsets[name]:offsets[name]+n] for name in names}
    data["soc"] = x[soc0:soc0+n+1]
    data.update({"pv_avail": pv_av, "wt_avail": wt_av, "gen_avail": gen_av,
                 "pv_curt": np.maximum(0, pv_av-data["pv"]), "wt_curt": np.maximum(0, wt_av-data["wt"]),
                 "gen_curt": np.maximum(0, gen_av-data["gen"]), "ok": True,
                 "cost": float(result.fun), "message": result.message})
    energy = {key: float(np.sum(value * sc.weight) * dt) for key, value in data.items()
              if isinstance(value, np.ndarray) and len(value) == n and key != "soc"}
    energy["load"] = float(np.sum(sc.load * sc.weight) * dt)
    data["energy"] = energy
    data["cost_gen_var"] = float(np.sum(data["gen"] * sc.weight) * dt * 1000 * cfg["cost"]["gen"]["var_cost"])
    # 购电成本与售电收益单独留存（与 cost 同为年化口径，单位：元/年）。
    # 口径只定义一次：成本构成图与 Excel 均直接取用，不在别处重算。
    data["cost_buy"] = float(np.sum(sc.buy_price * data["buy"] * sc.weight) * dt * 1000)
    data["revenue_sell"] = float(np.sum(sc.sell_price * data["sell"] * sc.weight) * dt * 1000)
    basis = data["discharge"] if cfg["ess"]["cycle_basis"] == "discharge" else data["charge"]
    data["equiv_cycles"] = float(np.sum(basis * sc.weight) * dt / max(e_ess, 1e-12))
    return data
