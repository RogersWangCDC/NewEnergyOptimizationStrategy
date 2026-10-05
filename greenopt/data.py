"""读取数据、构建全年或典型日调度场景。"""
from __future__ import annotations

from dataclasses import dataclass
import numpy as np
import pandas as pd


REQUIRED = ("Buy_Price", "Sell_Price", "Load", "PV_pu", "WT_pu", "Gen")


@dataclass
class Scenario:
    buy_price: np.ndarray; sell_price: np.ndarray; load: np.ndarray
    pv_pu: np.ndarray; wt_pu: np.ndarray; gen: np.ndarray; weight: np.ndarray
    day_id: np.ndarray; mode: str; dt: float

    @property
    def n(self) -> int: return len(self.load)


def load_dataset(cfg: dict) -> pd.DataFrame:
    """读取并校验 BasicData 工作表。"""
    df = pd.read_excel(cfg["path"]["data_file"], sheet_name=cfg["path"]["sheet"])
    missing = set(REQUIRED) - set(df.columns)
    if missing:
        raise ValueError(f"Dataset.xlsx 缺少列: {', '.join(sorted(missing))}")
    df = df.loc[:, REQUIRED].apply(pd.to_numeric, errors="raise").dropna().reset_index(drop=True)
    if len(df) % 24:
        raise ValueError("数据行数必须是 24 的整数倍，才能按自然日调度")
    if (df[["Buy_Price", "Sell_Price", "Load", "PV_pu", "WT_pu", "Gen"]] < 0).any().any():
        raise ValueError("数据不能包含负值")
    if cfg["time"]["load_repair"]:
        good = df["Load"] > 0
        if good.any():
            by_hour = df.loc[good].groupby(df.index[good] % 24)["Load"].median()
            zero = df["Load"] == 0
            df.loc[zero, "Load"] = [by_hour[i % 24] for i in df.index[zero]]
    return df


def _kmeans(x: np.ndarray, k: int, seed: int, n_iter: int = 100) -> tuple[np.ndarray, np.ndarray]:
    """小型确定性 k-means，避免增加 scikit-learn 依赖。"""
    rng = np.random.default_rng(seed)
    centers = x[rng.choice(len(x), size=k, replace=False)].copy()
    labels = np.zeros(len(x), dtype=int)
    for _ in range(n_iter):
        new_labels = ((x[:, None] - centers[None]) ** 2).sum(axis=2).argmin(axis=1)
        new_centers = np.array([x[new_labels == j].mean(axis=0) if (new_labels == j).any() else centers[j]
                                for j in range(k)])
        if np.array_equal(new_labels, labels): break
        labels, centers = new_labels, new_centers
    return labels, centers


def build_scenario(df: pd.DataFrame, cfg: dict, force_mode: str | None = None,
                   k: int | None = None) -> Scenario:
    """构建全年或加权典型日场景。"""
    mode = force_mode or cfg["time"]["mode"]
    dt, n = cfg["time"]["dt"], len(df)
    if mode == "full_year":
        return Scenario(*(df[c].to_numpy(float) for c in REQUIRED), np.ones(n),
                        np.arange(n) // 24, mode, dt)
    days = n // 24
    k = k or cfg["time"]["n_typical_days"]
    if not 1 <= k <= days: raise ValueError("典型日数量必须在 1 和数据天数之间")
    cols = ["Load", "PV_pu", "WT_pu", "Buy_Price", "Sell_Price", "Gen"]
    raw = df[cols].to_numpy(float).reshape(days, 24 * len(cols))
    scale = raw.std(axis=0); scale[scale < 1e-12] = 1
    labels, centers = _kmeans(raw / scale, k, cfg["pso"]["seed"])
    order_key = {"median": [np.median(np.where(labels == j)[0]) for j in range(k)],
                 "mean": [np.mean(np.where(labels == j)[0]) for j in range(k)],
                 "first": [np.min(np.where(labels == j)[0]) for j in range(k)],
                 "none": [-np.sum(labels == j) for j in range(k)]}
    order = np.argsort(order_key.get(cfg["time"]["typ_day_sort"], order_key["median"]))
    blocks, weights, ids = [], [], []
    for out_id, j in enumerate(order):
        members = np.where(labels == j)[0]
        block = df.iloc[np.repeat(members * 24, 24) + np.tile(np.arange(24), len(members))]
        if cfg["time"]["rep_method"] == "medoid":
            day_data = raw[members] / scale
            representative = members[np.argmin(((day_data - centers[j]) ** 2).sum(axis=1))]
            profile = df.iloc[representative * 24:(representative + 1) * 24]
        else:
            profile = block.groupby(np.arange(len(block)) % 24).mean(numeric_only=True)
        blocks.append(profile.loc[:, REQUIRED].to_numpy(float))
        weights.extend([len(members)] * 24); ids.extend([out_id] * 24)
    merged = np.vstack(blocks)
    return Scenario(*[merged[:, i] for i in range(6)], np.asarray(weights, float),
                    np.asarray(ids), mode, dt)


def typical_week(df: pd.DataFrame, cfg: dict) -> Scenario:
    """选取负荷、风光和电价形态最接近全年均值的一周，用于展示。"""
    n_weeks = len(df) // 168
    if n_weeks < 1: return build_scenario(df, cfg, "full_year")
    feature = df.loc[:n_weeks * 168 - 1, ["Load", "PV_pu", "WT_pu", "Buy_Price"]].to_numpy().reshape(n_weeks, -1)
    idx = int(cfg["time"]["week_mode"]) - 1 if cfg["time"]["week_mode"] != "auto" else np.argmin(((feature - feature.mean(0)) ** 2).sum(1))
    week = df.iloc[idx * 168:(idx + 1) * 168]
    return Scenario(*(week[c].to_numpy(float) for c in REQUIRED), np.ones(len(week)),
                    np.arange(len(week)) // 24, "week", cfg["time"]["dt"])
