"""项目唯一的日常配置入口。

容量单位为 MW/MWh，电价为 元/kWh，时间步长为 h。修改本文件后运行
``python run_greenopt.py``；无需改动其它模块。
"""
from __future__ import annotations

import os
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def _env_file() -> dict[str, str]:
    """读取本地 .env；不依赖额外包，且 .env 不提交到 Git。"""
    values: dict[str, str] = {}
    file = ROOT / ".env"
    if file.exists():
        for line in file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"').strip("'")
    return values


ENV = {**_env_file(), **os.environ}


def get_config() -> dict:
    """返回完整配置。这里是唯一建议用户日常修改的 Python 文件。"""
    return {
        "path": {
            "root": ROOT,
            "data_file": ROOT / "Dataset.xlsx",
            "sheet": "BasicData",
            "out_dir": ROOT / ENV.get("OUTPUT_DIR", "results"),
        },
        "data": {"gen_mode": "pu"},  # ``pu``: Gen 为标幺；``mw``: Gen 直接为 MW
        "time": {
            "mode": "full_year",       # ``typical_days`` 或 ``full_year``
            "n_typical_days": 6,
            "rep_method": "mean",      # ``mean`` 或 ``medoid``
            "typ_day_sort": "median",  # ``median``/``mean``/``first``/``repday``/``none``
            "dt": 1.0,
            "load_repair": False,
            "year_cyclic": "day",      # ``day``/``month``/``year``
            "week_mode": "auto",       # ``auto`` 或 1..52
        },
        "cost": {
            "mode": "tiered",          # ``flat`` 或 ``tiered``
            "allow_tier_edge_bound": False,
            "discount_rate": 0.06,
            "pv": {"capex": 3800, "life": 25, "opex_rate": .01,
                   "tier": [[0,3500],[6,3200],[20,3100],[50,3000],[100,3000],[200,3000],[500,3000],[20000,3000]]},
            "wt": {"capex": 6000, "life": 20, "opex_rate": .02,
                   "tier": [[0,4719],[6,4611.75],[20,4504.5],[50,4397.25],[100,4343.625],[200,4290],[500,4182.75],[20000,3968.25]]},
            "ess": {"capex_p": 1000, "capex_e": 400, "life": 10, "opex_rate": .01,
                    "tier_p": [[0,600],[6,500],[20,480],[50,470],[100,460],[200,450],[500,440],[20000,430]],
                    "tier_e": [[0,900],[6,850],[20,800],[50,760],[100,740],[200,720],[500,700],[20000,680]]},
            "gen": {"capex": 400, "life": 25, "opex_rate": .02, "var_cost": .10},
        },
        "ess": {
            "eta_ch": .93, "eta_dis": .93, "soc_min": .05, "soc_max": .95,
            "soc_init": .50, "fix_initial_soc": False, "self_dis": 2e-4,
            "cycle_life": 6000, "life_mode": "cycle_min", "cycle_basis": "discharge",
            "life_floor": 1.0,
        },
        "grid": {"import_max": 1e4, "export_max": 1e4, "allow_curtail": True,
                 "gen_curt_mode": "economic"},
        "milp": {"use_binary": True, "cd_binary": False, "rel_gap": 1e-4,
                 "time_limit": 120, "solver": ENV.get("SOLVER", "highs")},
        "pso": {
            "n_pop": 5, "max_iter": 3, "w_max": .9, "w_min": .4, "c1": 1.5, "c2": 1.5,
            "c1_end": .5, "c2_end": 2.5, "v_max_rate": 1.1,
            "seed": int(ENV.get("RANDOM_SEED", "2026")), "cache_eval": True,
            "stall_iter": 10, "tol_cost": 1e-4, "reset_frac": .10,
            "adaptive": True, "two_stage": True,
            "stage_a": {"n_pop": 60, "max_iter": 100, "k": 12, "shrink": .50},
            "local_refine": True, "refine_max_eval": 60, "refine_step0": .15,
            "refine_tol_rel": .002, "multi_run": 0,
            "lb": [5, 5, 5, 2, 5], "ub": [40, 40, 40, 4, 10],
        },
        # 填数字即固定对应装机；全填后将跳过 PSO，只进行一次最优调度。
        "fixed": {"pv": None, "wt": None, "ess_p": None, "ess_t": None,
                  "ess_e": None, "gen": None},
        "metrics": {"enable": True, "gen_in_green": False},
        "out": {
            "write_excel": True, "make_plots": True, "save_json": True,
            "full_year_check": True, "strict_dispatch": True,
            "languages": ["zh", "en"], "dpi": 600,
            # 绘图样式：逐项对齐仓库原 MATLAB 版 cfg_greenopt.m 第 552~576 行
            "style": {
                "font_size": 8,             # 正文字号 [pt]
                "title_size": 9,            # 标题字号 [pt]
                "bar_label_font_size": 7,   # 柱顶数值标签字号 [pt]
                "line_width": 1.2,          # 数据线线宽 [pt]
                "axis_line_width": 0.75,    # 坐标轴线宽 [pt]
                "pad_frac": 0.08,           # 纵轴留白比例
                "alpha": 0.78,              # 堆叠/填充透明度
                "grid": True,               # 点状浅色网格
            },
            "plot": {"pso": True, "source": True, "dispatch": True, "soc": True,
                     "week": True, "cost": True, "pro": True, "sensitivity": True},
        },
        "sensitivity": {
            "enable": True, "mode": "follow", "n_typical_days": 12,
            "rel_range": .50, "n_point": 9, "scan_from_zero": False, "zero_ref": 100,
            "grid_pv": list(range(0, 201, 25)), "grid_wt": None, "grid_p": None,
            "grid_e": None, "grid_gen": None,
            "mark_tiers": False,   # 在容量轴上标出分档档位（对应 MATLAB cfg.sens.markTiers）
        },
    }
