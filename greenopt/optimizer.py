"""外层：粒子群搜索装机容量，并在末端进行轻量局部精修。"""
from __future__ import annotations

from dataclasses import dataclass
import time
import numpy as np

from .dispatch import solve_dispatch
from .economics import annual_capex


@dataclass
class SearchResult:
    s: np.ndarray; cap: np.ndarray; fit: float; dispatch: dict; capex: float
    history: list[tuple[float, float]]; n_eval: int; elapsed: float; fixed_mode: bool


def _bounds(cfg: dict) -> tuple[np.ndarray, np.ndarray]:
    lb, ub = np.array(cfg["pso"]["lb"], float), np.array(cfg["pso"]["ub"], float)
    fixed = cfg["fixed"]
    mapping = {0: fixed["pv"], 1: fixed["wt"], 2: fixed["ess_p"], 4: fixed["gen"]}
    for idx, value in mapping.items():
        if value is not None: lb[idx] = ub[idx] = float(value)
    if fixed["ess_t"] is not None:
        lb[3] = ub[3] = float(fixed["ess_t"])
    if fixed["ess_e"] is not None:
        if fixed["ess_p"] in (None, 0):
            raise ValueError("固定储能容量时，也需要设置非零 fixed['ess_p']")
        lb[3] = ub[3] = float(fixed["ess_e"]) / float(fixed["ess_p"])
    if np.any(ub < lb): raise ValueError("PSO 上下界不合法")
    return lb, ub


def to_capacity(s: np.ndarray) -> np.ndarray:
    """把搜索变量 [PV, WT, 储能功率, 储能时长, 自发电] 转为实际容量。"""
    return np.array([s[0], s[1], s[2], s[2] * s[3], s[4]], float)


def _evaluate(s: np.ndarray, cfg: dict, scenario, cache: dict) -> tuple[float, dict, float]:
    cap = to_capacity(s)
    key = tuple(np.round(cap, 8))
    if key in cache: return cache[key]
    dispatch = solve_dispatch(cap, scenario, cfg)
    if not dispatch["ok"]:
        ans = (1e30, dispatch, 1e30)
    else:
        capex, _ = annual_capex(cap, cfg, dispatch)
        ans = (capex + dispatch["cost"], dispatch, capex)
    cache[key] = ans
    return ans


def _pso(cfg: dict, scenario, lb: np.ndarray, ub: np.ndarray, n_pop: int, max_iter: int,
         seed_offset: int = 0) -> tuple[np.ndarray, float, dict, float, list[tuple[float, float]], int]:
    """执行一轮带确定性种子点的 PSO。"""
    rng = np.random.default_rng(cfg["pso"]["seed"] + seed_offset)
    d, width = len(lb), ub - lb
    fixed = width < 1e-12
    x = rng.uniform(lb, ub, size=(n_pop, d)); x[:, fixed] = lb[fixed]
    # 加入中点和可行的零储能/无自发电候选，增强可解释性与收敛稳定性。
    x[0] = (lb + ub) / 2
    for idx in (0, 1, 2, 4):
        if n_pop > idx + 1:
            x[idx + 1] = x[0]; x[idx + 1, idx] = lb[idx]
    velocity = rng.uniform(-.15 * width, .15 * width, size=(n_pop, d)); velocity[:, fixed] = 0
    cache: dict = {}; pbest = x.copy(); pfit = np.full(n_pop, np.inf)
    best_x, best_fit, best_d, best_capex = x[0].copy(), np.inf, {}, np.inf
    history: list[tuple[float, float]] = []
    for it in range(max_iter + 1):
        fits = []
        for i in range(n_pop):
            fit, dispatch, capex = _evaluate(x[i], cfg, scenario, cache)
            fits.append(fit)
            if fit < pfit[i]: pfit[i], pbest[i] = fit, x[i].copy()
            if fit < best_fit: best_x, best_fit, best_d, best_capex = x[i].copy(), fit, dispatch, capex
        # 逐代记录「群体最优 + 种群均值」，两列口径与 MATLAB 收敛图一致。
        # 不可行粒子被罚到 1e30，若计入均值会让曲线完全失真，故只对可行粒子取均值。
        feasible = [f for f in fits if f < 1e29]
        history.append((best_fit, float(np.mean(feasible)) if feasible else best_fit))
        if it == max_iter: break
        frac = it / max(max_iter, 1)
        w = cfg["pso"]["w_max"] + (cfg["pso"]["w_min"] - cfg["pso"]["w_max"]) * frac
        c1 = cfg["pso"]["c1"] + (cfg["pso"]["c1_end"] - cfg["pso"]["c1"]) * frac
        c2 = cfg["pso"]["c2"] + (cfg["pso"]["c2_end"] - cfg["pso"]["c2"]) * frac
        velocity = w * velocity + c1 * rng.random((n_pop,d)) * (pbest-x) + c2 * rng.random((n_pop,d)) * (best_x-x)
        velocity = np.clip(velocity, -cfg["pso"]["v_max_rate"]*width, cfg["pso"]["v_max_rate"]*width)
        x = np.clip(x + velocity, lb, ub); x[:, fixed] = lb[fixed]
        # 重撒最差粒子，防止早期全体收缩在同一个局部区域。
        n_reset = int(n_pop * cfg["pso"]["reset_frac"])
        if n_reset and it > 0:
            worst = np.argsort(pfit)[-n_reset:]
            x[worst] = rng.uniform(lb, ub, (n_reset, d)); x[worst, fixed] = lb[fixed]
    return best_x, best_fit, best_d, best_capex, history, len(cache)


def _refine(s: np.ndarray, fit: float, cfg: dict, scenario, lb: np.ndarray, ub: np.ndarray) -> tuple[np.ndarray, float, dict, float, int]:
    """坐标模式搜索：不额外引入黑箱优化包，且便于学习和复现。"""
    if not cfg["pso"]["local_refine"]: return s, fit, {}, np.nan, 0
    cache: dict = {}; best, best_fit, best_d, best_capex = s.copy(), fit, {}, np.nan
    step = cfg["pso"]["refine_step0"] * (ub-lb); step[ub-lb < 1e-12] = 0
    floor = cfg["pso"]["refine_tol_rel"] * (ub-lb)
    for _ in range(cfg["pso"]["refine_max_eval"]):
        changed = False
        for j in range(len(best)):
            for sign in (-1, 1):
                candidate = best.copy(); candidate[j] = np.clip(candidate[j] + sign*step[j], lb[j], ub[j])
                value, dispatch, capex = _evaluate(candidate, cfg, scenario, cache)
                if value + 1e-7 < best_fit:
                    best, best_fit, best_d, best_capex, changed = candidate, value, dispatch, capex, True
        if not changed:
            step *= .5
            if np.all(step <= floor): break
    if not best_d: _, best_d, best_capex = _evaluate(best, cfg, scenario, cache)
    return best, best_fit, best_d, best_capex, len(cache)


def optimize(cfg: dict, scenario) -> SearchResult:
    """运行两阶段或单阶段 PSO；所有维度固定时自动只求解一次。"""
    start = time.perf_counter(); lb, ub = _bounds(cfg); fixed_mode = bool(np.allclose(lb, ub))
    if fixed_mode:
        fit, dispatch, capex = _evaluate(lb, cfg, scenario, {})
        return SearchResult(lb, to_capacity(lb), fit, dispatch, capex, [(fit, fit)], 1,
                            time.perf_counter()-start, True)
    histories: list[tuple[float, float]] = []; n_eval = 0
    if cfg["pso"]["two_stage"] and scenario.mode == "full_year":
        from .data import build_scenario, load_dataset
        # 用原数据重建典型日粗搜，避免把 8760 h MILP 重复数千次。
        ds = load_dataset(cfg); stage = cfg["pso"]["stage_a"]
        coarse = build_scenario(ds, cfg, "typical_days", stage["k"])
        s, _, _, _, h, ne = _pso(cfg, coarse, lb, ub, stage["n_pop"], stage["max_iter"])
        histories.extend(h); n_eval += ne
        radius = (ub-lb) * stage["shrink"] / 2
        lb2, ub2 = np.maximum(lb, s-radius), np.minimum(ub, s+radius)
        s, fit, dispatch, capex, h, ne = _pso(cfg, scenario, lb2, ub2, cfg["pso"]["n_pop"], cfg["pso"]["max_iter"], 1)
        histories.extend(h); n_eval += ne
        lb_refine, ub_refine = lb2, ub2
    else:
        s, fit, dispatch, capex, h, ne = _pso(cfg, scenario, lb, ub, cfg["pso"]["n_pop"], cfg["pso"]["max_iter"])
        histories.extend(h); n_eval += ne; lb_refine, ub_refine = lb, ub
    s, fit, refined, refined_capex, ne = _refine(s, fit, cfg, scenario, lb_refine, ub_refine)
    n_eval += ne
    if refined: dispatch, capex = refined, refined_capex
    return SearchResult(s, to_capacity(s), fit, dispatch, capex, histories, n_eval, time.perf_counter()-start, False)
