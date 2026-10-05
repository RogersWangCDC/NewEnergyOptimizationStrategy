%% =========================================================================
%  新能源电站「最优配置搜索 + 最优调度」双层模型 —— 主运行脚本
%  （普通脚本模式：clear all; clc 开头，直接 F5 或命令行输入 run_greenopt 运行）
%==========================================================================
%  配套文件
%    cfg_greenopt.m   参数文件（保持函数形式，返回 cfg 结构体；日常只改这里）
%    Dataset.xlsx     逐小时数据（与这两个 .m 文件放在同一文件夹）
%--------------------------------------------------------------------------
%  模型结构
%    外层 PSO   搜索  s = [ 光伏容量(MW) ; 风电容量(MW) ; 储能功率(MW) ;
%                          储能时长(h) ; 厂内自发电容量(MW) ]
%               储能容量(MWh) = 储能功率(MW) x 储能时长(h)
%               自发电出力(t) = 自发电容量(MW) x Gen_pu(t)  （Gen 列 = 标幺出力）
%               PSO 之后做「局部精修」（Hooke-Jeeves + Nelder-Mead）
%               搜索全程带「边界诊断 + 自动外扩」，并支持两阶段搜索
%               （阶段A 典型日口径粗搜 -> 阶段B 目标口径精搜；
%                双层嵌套结构不变，变的只是内层 MILP 用的时间尺度）
%    内层 MILP  intlinprog 求当前配置下的小时级最优调度
%               目标 = 购电成本 - 售电收益 + 自发电燃料成本
%               弃电按 光伏 / 风电 / 自发电 分源建模（三套独立变量，
%               故优化器会自动「先弃边际成本高的」= 先弃自发电）
%    目标       年化用电成本最低 = 年化投资成本 + 年化最优运行成本
%  详细的目标函数与约束条件注释见本文件末尾 gopt_milp 的说明段。
%--------------------------------------------------------------------------
%  怎么用（脚本模式没有命令行参数了，全部在下面「运行控制区」改）
%    ① 正常搜索      OVR 全部留空  -> 完全按 cfg_greenopt.m 运行
%    ② 只做内层调度  OVR.pvFixed = 30; OVR.wtFixed = 20; OVR.essPFixed = 10; OVR.essTFixed = 2;
%    ③ 固定自发电    OVR.genFixed = 0;   （0 = 不建自发电，等价旧版行为）
%    ④ 单阶段搜索    OVR.twoStage = false;
%    ⑤ 跑模型自检    RUN_SELFTEST = true;
%==========================================================================

clear all; clc;

%% ==================== 运行控制区（脚本模式：只改这里）====================

RUN_SELFTEST = false;    % true  => 只跑模型自检，跑完即结束
                         % false => 正常运行「配置搜索 + 调度」

% --- 参数临时覆盖（不想动 cfg_greenopt.m 时用；留空 [] 表示该参数不变）---
%   可用字段名（与 cfg_greenopt.m 中的参数对应关系见右侧注释）
OVR = struct();
OVR.mode        = [];    % 'typical_days' | 'full_year'   -> cfg.time.mode
OVR.nTypical    = [];    % 典型日个数 K                            -> cfg.time.nTypicalDays
OVR.typDaySort  = [];    % 典型日排序键 'median'|'mean'|'first'|'none'-> cfg.time.typDaySort
OVR.weekMode    = [];    % 'auto' 或 1..52                        -> cfg.time.weekMode
OVR.cycleMode   = [];    % 'day' | 'neutral'（典型日模式储能循环）  -> cfg.ess.cycleMode
OVR.yearCyclic  = [];    % 'day' | 'month' | 'year'（SOC 循环周期）-> cfg.time.yearCyclic
OVR.pvFixed     = [];    % 固定光伏容量 [MW]                       -> cfg.fixed.pv
OVR.wtFixed     = [];    % 固定风电容量 [MW]                       -> cfg.fixed.wt
OVR.essPFixed   = [];    % 固定储能功率 [MW]                       -> cfg.fixed.essP
OVR.essTFixed   = [];    % 固定储能时长 [h]                        -> cfg.fixed.essT
OVR.esseFixed   = [];    % 固定储能容量 [MWh]（需同时给 essPFixed）  -> cfg.fixed.esse
OVR.genFixed    = [];    % 固定自发电容量 [MW]（0 = 不建自发电）      -> cfg.fixed.gen
OVR.costMode    = [];    % 'flat' | 'tiered'（成本计价口径：常数单价 / 分档单价） -> cfg.cost.mode
OVR.pvCapex     = [];    % 光伏常数单价 [元/kW]（仅 mode='flat' 生效）      -> cfg.cost.pv.capex
OVR.wtCapex     = [];    % 风电常数单价 [元/kW]（仅 mode='flat' 生效）      -> cfg.cost.wt.capex
OVR.essCapexP   = [];    % 储能功率常数单价 [元/kW]（仅 mode='flat' 生效）  -> cfg.cost.ess.capexP
OVR.essCapexE   = [];    % 储能容量常数单价 [元/kWh]（仅 mode='flat' 生效） -> cfg.cost.ess.capexE
OVR.pvTier      = [];    % 光伏分档单价表 N x 2 [档位 MW, 单价 元/kW]        -> cfg.cost.pv.tier
OVR.wtTier      = [];    % 风电分档单价表 N x 2 [档位 MW, 单价 元/kW]        -> cfg.cost.wt.tier
OVR.essPTier    = [];    % 储能功率分档单价表 N x 2 [档位 MW, 单价 元/kW]    -> cfg.cost.ess.tierP
OVR.essETier    = [];    % 储能容量分档单价表 N x 2 [档位 MWh, 单价 元/kWh]  -> cfg.cost.ess.tierE
OVR.genCapex    = [];    % 自发电单位投资 [元/kW]                   -> cfg.cost.gen.capex
OVR.genLife     = [];    % 自发电寿命 [年]                          -> cfg.cost.gen.life
OVR.genOpex     = [];    % 自发电年运维费率 [-]                     -> cfg.cost.gen.opexRate
OVR.genVarCost  = [];    % 自发电运行成本 [元/kWh]                  -> cfg.cost.gen.varCost
OVR.genCurtMode = [];    % 'economic' | 'no_curtail'（自发电弃电口径） -> cfg.const.genCurtMode
OVR.genMode     = [];    % 'pu' | 'mw'（Gen 列口径）                -> cfg.data.genMode
OVR.discount    = [];    % 折现率                                  -> cfg.cost.discountRate
OVR.importMax   = [];    % 并网购电功率上限 [MW]                    -> cfg.const.gridImportMax
OVR.exportMax   = [];    % 并网售电功率上限 [MW]（0 = 禁止上网）      -> cfg.const.gridExportMax
OVR.allowCurtail= [];    % 是否允许弃风弃光                          -> cfg.const.allowCurtail
OVR.nPop        = [];    % PSO 粒子数                               -> cfg.pso.nPop
OVR.maxIter     = [];    % PSO 迭代次数                             -> cfg.pso.maxIter
OVR.seed        = [];    % 随机种子                                 -> cfg.pso.seed
OVR.localRefine = [];    % PSO 收敛后是否局部精修                    -> cfg.pso.localRefine
OVR.cache       = [];    % 是否缓存已评估点                          -> cfg.pso.cacheEval
OVR.twoStage    = [];    % 是否两阶段搜索（典型日粗搜 + 目标口径精搜） -> cfg.pso.twoStage
OVR.stageA      = [];    % 阶段 A 参数（结构体：nPop/maxIter/K/shrink）-> cfg.pso.stageA
OVR.boundCheck  = [];    % 是否做边界诊断与自动外扩                    -> cfg.pso.boundCheck
OVR.multiRun    = [];    % 多起点独立运行次数（0 = 关闭）              -> cfg.pso.multiRun
OVR.fullYearCheck = [];  % 是否做全年 8760 h 核准                     -> cfg.out.fullYearCheck
OVR.twoStage    = [];    % 是否两阶段搜索                            -> cfg.pso.twoStage
OVR.sensNPoint  = [];    % 敏感性分析每组扫描点数                     -> cfg.sens.nPoint
OVR.strictDispatch= [];  % 输出前是否严格复算调度                     -> cfg.out.strictDispatch
OVR.makePlots   = [];    % 是否绘图                                  -> cfg.out.makePlots
OVR.plotDays    = [];    % 只画哪些典型日（编号，如 1:4）              -> cfg.out.plotDays
OVR.plotWhichDays = [];  % 只画哪些自然日区间（N x 2，如 [50 120]）    -> cfg.out.plotWhichDays
OVR.plotWhichMinFrac = [];       % 区间命中判据：成员占比阈值                  -> cfg.out.plotWhichMinFrac
OVR.plotFigures = [];    % 图种开关结构体（见 cfg_greenopt.m）        -> cfg.out.plotFigures
OVR.writeExcel  = [];    % 是否导出 Excel                            -> cfg.out.writeExcel
OVR.saveMat     = [];    % 是否保存 .mat                             -> cfg.out.saveMat
OVR.figLang     = [];    % 'zh' | 'en'                               -> cfg.out.figLang
OVR.dpi         = [];    % 图片分辨率 [dpi]                          -> cfg.out.dpi
OVR.quiet       = [];    % true => 只输出关键结果                     -> cfg.io.quiet
OVR.showMonthHist = [];  % 典型日日志是否追加「按月分布」一行          -> cfg.out.showMonthHist
% --- 敏感性分析（第 10 段；不参与寻优，纯事后复盘）---
OVR.sensEnable  = [];    % 是否做敏感性分析                          -> cfg.sens.enable
OVR.sensMode    = [];    % 'follow' | 'typical_days' | 'full_year'   -> cfg.sens.mode
OVR.sensNPoint  = [];    % 每个维度的扫描点数                         -> cfg.sens.nPoint
OVR.sensRelRange= [];    % 扫描半宽系数（0.5 = 底座 ±50%）             -> cfg.sens.relRange
OVR.sensBase    = [];    % 底座配置 [PV;WT;P_ess;E_ess]，留空 = 用最优解 -> cfg.sens.base

% --- 出力堆叠图样式（常规新能源电站口径：正出力向上堆叠、负出力向下堆叠）---
%     纵轴留白比例由 cfg.out.padFrac 统一控制（见 cfg_greenopt.m），不在这里重复定义；
%     理由见该参数的注释与 gopt_ylim_pad —— 本仓库的「口径只定义一次」约定。
STACK.alpha    = 0.78;   % 各色块透明度 0~1（0.75 ~ 0.85 观感最好，便于看清重叠边界）
STACK.barWidth = 1.00;   % 柱宽，1.0 = 柱间无缝，接近面积堆叠效果
STACK.showLoad = true;   % 是否叠加黑色负荷曲线
STACK.showNet  = false;  % 是否叠加灰色净负荷曲线（负荷 - 光伏 - 风电 - 自发电）

%% ==================== 0. 路径与参数准备 ====================
thisDir = fileparts(mfilename('fullpath'));
if ~isempty(thisDir), addpath(thisDir); end

cfg = cfg_greenopt();                          % 读取参数文件
cfg = gopt_apply_overrides(cfg, OVR);          % 应用运行控制区的临时覆盖
cfg = gopt_check_cost_tables(cfg);             % 校验分档单价表（放在流程最开头：宁可在这里
                                               % 报一句清楚的错，也不要搜了几小时才发现表写错了）

if RUN_SELFTEST
    gopt_selftest(cfg);
    return;                                    % 自检结束，不再执行下面的常规流程
end

cfg = gopt_apply_fixed(cfg);                   % 把 cfg.fixed.* 折算进搜索范围
cfg = gopt_check_tier_ub(cfg);                 % ★ 必须在 apply_fixed 之后：fixed 会改写 lb/ub，
                                               %   搜索框定型后才能判「上界是否压在分档跳变点上」

fprintf('%s\n', repmat('=', 1, 82));
fprintf('  新能源电站「最优配置搜索 + 最优调度」双层模型\n');
fprintf('  外层 PSO（光伏 / 风电 / 储能功率 / 储能时长 / 厂内自发电） + 内层 intlinprog 最优调度\n');
fprintf('  %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
fprintf('%s\n', repmat('=', 1, 82));

%% ---------- 1. 打印经济性假设 ----------
if ~cfg.io.quiet
    modeC = gopt_cost_mode(cfg);
    fprintf('\n[参数] 投资与技术经济假设（参数预设在cfg_greenopt.m文件）\n');
    fprintf('       成本计价口径：cfg.cost.mode = ''%s''（%s）\n', modeC, ...
        gopt_tern(strcmp(modeC, 'tiered'), ...
            '分档单价：单价按容量在分档表上分段线性插值，投资额 = 容量 x 插值单价', ...
            '常数单价：单价与容量无关，投资额 = 容量 x 常数单价'));
    if strcmp(modeC, 'tiered')
        % ★ 分档表本身也印出来：参数文件是唯一数据源，但日志里留一份「本次到底用了哪张表」，
        %   日后复核时才不必回到 cfg 去翻（改过参数的人常常忘了自己改的是哪一版）。
        fprintf('         光伏      %s\n', gopt_tier_summary(cfg.cost.pv.tier, 'MW', '元/kW'));
        fprintf('         风电      %s\n', gopt_tier_summary(cfg.cost.wt.tier, 'MW', '元/kW'));
        fprintf('         储能功率  %s\n', gopt_tier_summary(cfg.cost.ess.tierP, 'MW', '元/kW'));
        fprintf('         储能容量  %s\n', gopt_tier_summary(cfg.cost.ess.tierE, 'MWh', '元/kWh'));
    else
        fprintf('         光伏 %.0f 元/kW；风电 %.0f 元/kW；储能 功率 %.0f 元/kW + 容量 %.0f 元/kWh\n', ...
            cfg.cost.pv.capex, cfg.cost.wt.capex, cfg.cost.ess.capexP, cfg.cost.ess.capexE);
    end
    fprintf('       光伏：寿命 %2d 年，运维 %.1f%%/年   -> 年化费用率 %.4f\n', ...
        cfg.cost.pv.life, cfg.cost.pv.opexRate*100, ...
        gopt_crf(cfg.cost.discountRate, cfg.cost.pv.life) + cfg.cost.pv.opexRate);
    fprintf('       风电：寿命 %2d 年，运维 %.1f%%/年   -> 年化费用率 %.4f\n', ...
        cfg.cost.wt.life, cfg.cost.wt.opexRate*100, ...
        gopt_crf(cfg.cost.discountRate, cfg.cost.wt.life) + cfg.cost.wt.opexRate);
    fprintf('       储能：寿命 %2d 年（另与循环寿命取小），运维 %.1f%%/年 -> 年化费用率 %.4f\n', ...
        cfg.cost.ess.life, cfg.cost.ess.opexRate*100, ...
        gopt_crf(cfg.cost.discountRate, cfg.cost.ess.life) + cfg.cost.ess.opexRate);
    fprintf('       厂内自发电：常数单价 %.0f 元/kW（无分档表），寿命 %g 年，运维 %.1f%%/年，运行 %.2f 元/kWh\n', ...
        cfg.cost.gen.capex, cfg.cost.gen.life, cfg.cost.gen.opexRate*100, cfg.cost.gen.varCost);
    fprintf('       折现率 %.2f%%；储能 SOC %.0f%% ~ %.0f%%，充/放效率 %.2f / %.2f，自放电 %.1e /h\n', ...
        cfg.cost.discountRate*100, cfg.ess.socMin*100, cfg.ess.socMax*100, ...
        cfg.ess.etaCh, cfg.ess.etaDis, cfg.ess.selfDis);
end

%% ---------- 2. 读取数据 ----------
ds = gopt_load_dataset(cfg);

if cfg.const.gridImportMax < max(ds.load)
    warning('cfg.const.gridImportMax = %.3g MW 小于峰值负荷 %.3g MW，内层将无可行解，已自动放宽。', ...
        cfg.const.gridImportMax, max(ds.load));
    cfg.const.gridImportMax = max(ds.load) * 1.2;
end

%% ---------- 3. 构建调度场景 ----------
sc = gopt_build_scenario(ds, cfg);

%% ---------- 4. 外层搜索（全维固定时自动退化为单次内层调度）----------
% 传 ds 进去是为了两阶段搜索：阶段 A 需要用数据集另建一个「典型日口径」的内层场景。
res = gopt_pso(cfg, sc, ds);

if ~res.R.ok
    error('内层调度求解失败：%s\n请检查数据与约束设置（并网限值 / SOC 上下限等）。', res.R.message);
end

%% ---------- 5. 输出前的严格调度复算 ----------
% 搜索阶段为提速使用松弛的充放电模型，LP 可能出现「同时充放」的退化顶点。
% 这里在最优配置上用严格互斥重解一次，保证输出两列干净（最优值理论上不变）。
cfgStrict = cfg;
cfgStrict.milp.cdBinary = true;
cfgStrict.milp.relGap   = min(cfg.milp.relGap, 1e-7);   % 严格复算时收紧最优间隙
if cfg.out.strictDispatch && ~cfg.milp.cdBinary
    if res.R.simChDisMWh <= 1e-6
        fprintf('[输出] 调度解本身不含同时充放电，直接采用（无需严格复算）。\n');
    else
        Rs = gopt_milp(res.cap, sc, cfgStrict);
        if Rs.ok && Rs.simChDisMWh <= 1e-9
            fprintf('[输出] 已用严格充放互斥复算最终调度（成本变化 %+.4e 万元/年）。\n', ...
                (Rs.cost - res.R.cost) / 1e4);
            res.R = Rs;
        else
            warning('严格互斥复算未取得「无重叠」的可行解（ok=%d），沿用松弛解（重叠 %.4f MWh/年）。', ...
                Rs.ok, res.R.simChDisMWh);
        end
    end
end

%% ---------- 5b. 全年 8760 h 核准 ----------
% 典型日模型把 8760 h 压缩为 24K h；此处用全年 8760 h 模型在最优点上重算一次，
% 给出高保真成本口径。为做到「只改时域表示、不改物理假设」，核准模型沿用与设计
% 模型相同的 SOC 循环周期 cfg.time.yearCyclic（默认 'day'，即逐日闭合），
% 因此两者之差是纯粹的「时域压缩误差」，可直接用于判断典型日模型的保真度。
res.fitFY = NaN;  res.Rfy = [];  res.dFitFY = NaN;
if cfg.out.fullYearCheck && ~strcmpi(cfg.time.mode, 'full_year')
    cfgFY = cfg;  cfgFY.time.mode = 'full_year';  cfgFY.io.quiet = true;
    scFY  = gopt_build_scenario(ds, cfgFY);
    RFY   = gopt_milp(res.cap, scFY, cfgFY);
    if RFY.ok
        res.fitFY  = res.costCapex + RFY.cost;
        res.Rfy    = RFY;
        res.dFitFY = res.fitFY - res.fit;
        fprintf('[核准] 全年 8760 h 口径：年化总成本 %12.2f 万元/年（典型日模型 %12.2f，相对偏差 %+.3f%%）\n', ...
            res.fitFY / 1e4, res.fit / 1e4, res.dFitFY / res.fit * 100);
        fprintf('       全年口径：购电 %.0f MWh，售电 %.0f MWh，充 %.0f / 放 %.0f MWh，弃电 %.0f MWh，利用率 %.2f%%\n', ...
            RFY.energyBuy, RFY.energySell, RFY.energyCh, RFY.energyDis, RFY.energyCurt, RFY.utilRen*100);
    else
        fprintf('[核准] 全年 8760 h 复核求解失败，跳过（典型日结果仍然有效）。\n');
    end
end

%% ---------- 5c. 专业化指标（储能损耗 / 两个比例 / 成本节省率 / 两个 LCOE）----------
% 位置说明：必须排在 5b 之后——「用电成本综合节省率」与两个 LCOE 的分子默认取
% 「全年 8760 h 核准」口径，而 res.Rfy / res.fitFY 正是 5b 产出的；排在这里两者必然同口径。
% 指标实现集中在 gopt_metrics_pro（内部复用 gopt_metrics，避免绿电消纳口径漂移），
% 本段只算一次、存进 res.pro，供命令行 9c、Excel「专业指标」表与 fig_pro_metrics 三处共用。
res.pro = gopt_metrics_pro(res, ds, sc, cfg);

%% ---------- 6. 典型周调度（用于输出典型周曲线）----------
scw = gopt_typical_week(ds, cfg);
if cfg.out.strictDispatch, Rw = gopt_milp(res.cap, scw, cfgStrict);
else,                      Rw = gopt_milp(res.cap, scw, cfg);
end
if ~Rw.ok
    warning('典型周调度求解失败，跳过典型周输出。');
    Rw = [];
end

%% ---------- 7. 结果自检（约束满足性）----------
fprintf('\n[校验] 内层调度约束满足性\n');
fprintf('       功率平衡最大残差     : %.3e MW\n', res.R.maxResid);
fprintf('       同时充放电小时数     : %d（重叠电量 %.4f MWh）\n', res.R.nSimChDis, res.R.simChDisMWh);
fprintf('       同时购售电小时数     : %d（重叠电量 %.4f MWh）\n', res.R.nSimBuySell, res.R.simBuySellMWh);
if res.R.maxResid > 1e-4
    warning('功率平衡残差偏大，请检查数值条件。');
end
if res.R.simBuySellMWh > 1e-3
    warning('存在实质性同时购电与售电（%.4f MWh），请检查 cfg.milp.useBinary。', res.R.simBuySellMWh);
end

if res.cap(4) > 0
    socLo = min(res.R.E_soc) / res.cap(4);
    socHi = max(res.R.E_soc) / res.cap(4);
    fprintf('       SOC 实际运行区间     : %.2f%% ~ %.2f%%（限值 %.0f%% ~ %.0f%%）\n', ...
        socLo*100, socHi*100, cfg.ess.socMin*100, cfg.ess.socMax*100);
    assert(socLo >= cfg.ess.socMin - 1e-4 && socHi <= cfg.ess.socMax + 1e-4, 'SOC 越界，模型异常。');
end

%% ---------- 8. 输出 ----------
if cfg.out.makePlots,  gopt_plots(res, sc, scw, Rw, cfg, STACK); end
if cfg.out.writeExcel, gopt_export(res, ds, sc, scw, Rw, cfg); end

%% ---------- 9. 汇总打印 ----------
cap = res.cap;
fprintf('\n%s\n', repmat('=', 1, 82));
fprintf('  最优配置结果\n');
fprintf('%s\n', repmat('-', 1, 82));
fprintf('    光伏容量          : %10.3f MW\n',    cap(1));
fprintf('    风电容量          : %10.3f MW\n',    cap(2));
fprintf('    储能功率          : %10.3f MW\n',    cap(3));
fprintf('    储能时长          : %10.3f h\n',     res.s(4));
fprintf('    储能容量          : %10.3f MWh   (= 功率 %.3f MW x 时长 %.3f h)\n', ...
    cap(4), cap(3), res.s(4));
fprintf('    厂内自发电容量    : %10.3f MW    (Gen 列按「标幺出力」解读)\n', cap(5));
fprintf('%s\n', repmat('-', 1, 82));
[~, capD] = gopt_annual_capex(cap, cfg, res.R);   % 传 res.R：储能寿命由本次调度反算
fprintf('    年化投资成本      : %12.2f 万元/年  （光伏 %.2f + 风电 %.2f + 储能 %.2f + 自发电 %.2f）\n', ...
    res.costCapex / 1e4, capD.pv / 1e4, capD.wt / 1e4, capD.ess / 1e4, capD.gen / 1e4);
% ---- ★ 投资单价口径与「命中档」提示（本轮新增：分档单价）----
% 文本由 gopt_price_lines 统一生成（与 Excel 共用同一份实现），不在日志里另写一套。
prL = gopt_price_lines(cap, capD, cfg);
for kL = 1:numel(prL)
    fprintf('%s\n', prL{kL});
end
fprintf('    年化运行成本      : %12.2f 万元/年  （购电 %.2f - 售电 %.2f + 自发电燃料 %.2f）\n', ...
    res.costOp / 1e4, res.R.costBuy / 1e4, res.R.revenueSell / 1e4, res.R.costGenVar / 1e4);
if strcmpi(cfg.time.mode, 'full_year')
    fprintf('    年化总用电成本    : %12.2f 万元/年   （全年 8760 h 口径，SOC 按 %s 闭合）\n', ...
        res.fit / 1e4, cfg.time.yearCyclic);
else
    fprintf('    年化总用电成本    : %12.2f 万元/年   （典型日模型口径）\n', res.fit / 1e4);
end
if ~isnan(res.fitFY)
    fprintf('    全年 8760h 核准   : %12.2f 万元/年   （相对偏差 %+.3f%%，更接近真实运行）\n', ...
        res.fitFY / 1e4, res.dFitFY / res.fit * 100);
end
fprintf('%s\n', repmat('-', 1, 82));
fprintf('    年购电量          : %14.2f MWh\n', res.R.energyBuy);
fprintf('    年售电量          : %14.2f MWh\n', res.R.energySell);
fprintf('    储能年充电量      : %14.2f MWh\n', res.R.energyCh);
fprintf('    储能年放电量      : %14.2f MWh\n', res.R.energyDis);
fprintf('    年弃风弃光电量    : %14.2f MWh\n', res.R.energyCurt);
fprintf('      其中 弃光伏     : %14.2f MWh\n', res.R.energyCurtPV);
fprintf('      其中 弃风电     : %14.2f MWh\n', res.R.energyCurtWT);
fprintf('      其中 弃自发电   : %14.2f MWh\n', res.R.energyCurtGen);
fprintf('    可再生能源利用率  : %s   （仅光伏+风电口径 %s）\n', ...
    gopt_pct(res.R.utilRen), gopt_pct(res.R.utilRenOnly));
% ---- 厂内自发电单列（★ 本轮新增）----
if cap(5) > 0
    gD = capD.genD;
    fprintf('%s\n', repmat('-', 1, 82));
    fprintf('    厂内自发电：容量 %.3f MW，可用 %.0f MWh/年，实发 %.0f MWh/年，弃 %.0f MWh/年（利用率 %s）\n', ...
        cap(5), res.R.energyGenAvail, res.R.energyGen, res.R.energyCurtGen, gopt_pct(res.R.utilGen));
    fprintf('    自发电度电成本    : %10.4f 元/kWh  = （年化投资 %.2f + 年运行 %.2f 万元/年）/ 实发 %.0f MWh\n', ...
        gD.lcoe, gD.annual / 1e4, gD.varCostYuan / 1e4, gD.E_gen);
    fprintf('      其中 投资折算   : %10.4f 元/kWh（分母为实发量，弃电越多该值越高）\n', gD.lcoeCapex);
    fprintf('      其中 运行成本   : %10.4f 元/kWh（按实际发电量计，弃电部分不付费）\n', gD.lcoeVar);
    fprintf('    比价参照（全成本）: %s\n', gopt_lcoe_cmp(gD.lcoe, res.pro.refLcoePV, ...
        res.pro.refLcoeWT, res.pro.basePrice));
end
if res.fit > 0
    fprintf('    单位负荷电成本    : %14.2f 元/MWh\n', res.fit / max(res.R.energyLoad, eps));
end

% ---- 9b. 指标口径与关键公式 ----
% 把「自用率 / 上网率 / 弃电率 / 未自用率」到底怎么算的直接印在命令行里，
% 免得看结果时还要回去翻代码。口径与 gopt_metrics 完全一致（敏感性图共用同一实现）。
m = gopt_metrics(res.R, res.cap, sc, cfg);
fprintf('%s\n', repmat('-', 1, 82));
fprintf('    指标口径（绿电消纳）与关键公式\n');
fprintf('      绿电发电量 = 光伏容量 x 光伏标幺累加量 + 风电容量 x 风电标幺累加量\n');
fprintf('                   （「累加量」= 年化加权求和，即 %s 口径下的全时序求和）\n', sc.mode);
fprintf('                   ★ 本轮改动：自发电**不再计入绿电**（单列成块，见下）\n');
fprintf('      自用率     = （绿电发电量 - 绿电上网电量 - 绿电弃电量） / 绿电发电量\n');
fprintf('      上网率     = 绿电上网电量 / 绿电发电量\n');
fprintf('      弃电率     = 绿电弃电量 / 绿电发电量（仅弃光伏 + 弃风电）\n');
fprintf('      未自用率   = 上网率 + 弃电率 = 1 - 自用率\n');
fprintf('                   （「自用」是绿电发电量扣除上网与弃电后的余量，恒有\n');
fprintf('                     自用率 + 上网率 + 弃电率 = 100%%；注意其中含储能循环损耗\n');
fprintf('                     ≈ 充电量 - 放电量，该损耗未单列、而是计入「自用」）\n');
fprintf('      年化总成本 = 年化投资成本 + 年化运行成本\n');
fprintf('      年化投资成本 = 容量 x 单位投资单价 x （资金回收系数 CRF + 运维费率）\n');
fprintf('        · 单位投资单价：cfg.cost.mode = ''%s'' -> %s\n', gopt_cost_mode(cfg), ...
    gopt_tern(strcmp(gopt_cost_mode(cfg), 'tiered'), ...
        '按容量在分档表上分段线性插值（光伏/风电/储能功率/储能容量四项）', ...
        '与容量无关的常数单价'));
fprintf('        · 分档四项以外的厂内自发电没有分档表，恒为常数单价；\n');
fprintf('          四项资产虽单价不同，但年化口径一致（同为 CRF + 运维费率）。\n');
fprintf('      —— 本次结果 ——\n');
fprintf('      绿电发电量        : %14.2f MWh/年  （光伏 %.2f + 风电 %.2f；不含自发电）\n', ...
    m.E_ren, m.E_pv, m.E_wt);
fprintf('      其中 自用 / 上网 / 弃电 : %12.2f / %12.2f / %12.2f MWh/年\n', ...
    m.E_self, m.E_sell, m.E_curt);
fprintf('      其中 储能循环损耗       : %12.2f MWh/年  （= 充电量 - 放电量，已计入上行的「自用」）\n', ...
    res.R.energyCh - res.R.energyDis);
fprintf('      自用率 %6.2f%%   上网率 %6.2f%%   弃电率 %6.2f%%   未自用率 %6.2f%%\n', ...
    m.selfRate, m.sellRate, m.curtRate, m.unusedRate);

% ---- 9c. 专业化指标 ----
% 口径与公式文本来自 gopt_metrics_pro 里生成的同一份 P.formulaLines（与 Excel 共用），
% 这里只负责排版打印，不再重算任何数字。
if ~isempty(res.pro)
    P = res.pro;
    fprintf('%s\n', repmat('-', 1, 82));
    fprintf('    专业化指标（成本口径：%s）\n', P.refTag);
    fprintf('      储能年损耗电量        : %10.2f 万kWh/年   （= 年充电量 - 年放电量，占充电量 %.2f%%）\n', ...
        P.lossTot, P.lossRate);
    fprintf('        其中 充放转换损耗    : %10.2f 万kWh/年\n', P.lossConv);
    fprintf('        其中 自放电损耗      : %10.2f 万kWh/年\n', P.lossSelf);
    fprintf('      用户绿电占用电量比例  : %10.2f %%           （绿电供负荷 %.0f / 负荷 %.0f MWh）\n', ...
        P.greenRate, P.E_greenLoad, P.E_load);
    fprintf('      新能源发电量消纳比例  : %s\n', ...
        gopt_tern(P.noRen, '   不适用（本方案不含光伏/风电装机，绿电口径无定义）', ...
        sprintf('%10.2f %%           （弃电 %.0f / 绿电发电 %.0f MWh）', P.absorbRate, P.m.E_curt, P.m.E_ren)));
    fprintf('      用电成本综合节省率    : %10.2f %%           （基准购电 %.2f -> 年化总成本 %.2f 万元/年）\n', ...
        P.saveRate, P.costBase / 1e4, P.costRef / 1e4);
    fprintf('      LCOE 发电口径(不含税) : %10.4f 元/kWh      （分子 %.2f 万元/年 / 分母 %.0f MWh）\n', ...
        P.lcoeGen, P.numGen / 1e4, P.denGen);
    fprintf('        └ 含自发电对照      : %10.4f 元/kWh      （复刻上一版口径，便于纵向对比）\n', ...
        P.lcoeGenWG);
    fprintf('      LCOE 消纳口径(不含税) : %10.4f 元/kWh      （分子 %.2f 万元/年 / 分母 %.0f MWh）\n', ...
        P.lcoeCon, P.numCon / 1e4, P.denCon);
    fprintf('      参考电价              : 基准购电均价 %.4f，用户综合度电成本 %.4f 元/kWh\n', ...
        P.basePrice, P.avgPrice);
    % ---- 厂内自发电独立块（★ 本轮新增）----
    fprintf('      ── 厂内自发电（单列，不计入绿电）──\n');
    fprintf('      自发电容量 / 实发电量 : %10.2f MW / %10.0f MWh·年⁻¹（可用 %.0f，利用率 %s）\n', ...
        P.genCap, P.genE, P.genEAvail, gopt_pct(P.genUseRate / 100));
    fprintf('      自发电度电成本        : %10.4f 元/kWh      （年化投资 %.2f + 年运行 %.2f 万元/年，分母 = 实发量）\n', ...
        P.genLcoe, P.genInvAnn / 1e4, P.genVarAnn / 1e4);
    fprintf('        └ 投资折算 / 运行   : %10.4f / %.4f 元/kWh\n', P.genLcoeCap, P.genLcoeVar);
    fprintf('      自发电供负荷          : %10.0f MWh/年       （占负荷电量 %.2f%%；自发电上网 %.0f MWh/年）\n', ...
        P.genLoadE, P.genRate, P.genSellE);
    if isfield(cfg, 'met') && isfield(cfg.met, 'logDetail') && logical(cfg.met.logDetail) ...
            && ~isempty(P.formulaLines)
        FL = P.formulaLines;
        fprintf('      —— 口径与公式（与 Excel「专业指标」表共用同一份文本）——\n');
        for i = 1:size(FL, 1)
            lab = FL{i, 1};  val = FL{i, 2};
            if isempty(lab)
                fprintf('          %s\n', val);
            elseif isempty(val)
                fprintf('        %s\n', lab);
            else
                fprintf('        %s：%s\n', lab, val);
            end
        end
    end
end

fprintf('%s\n', repmat('-', 1, 82));
fprintf('    内层求解次数      : %d 次（含局部精修 %d 次），耗时 %.1f s\n', ...
    res.nEval, res.refineN, res.wall);
fprintf('%s\n', repmat('=', 1, 82));

%% ---------- 10. 敏感性分析（可选；计算量大，故放在最后）----------
% 为什么放在所有主线结果之后：它要额外做「4 组 x 扫描点数」次内层 MILP 求解，
% 是整条流程里最慢的一步；放在最后可以保证「配置 / 成本 / 电量 / 各处图」先出结果，
% 先跑完的先看，不必等这一大段扫描。
% 触发条件（两者取或）：出图开关开启，或（要写 Excel 且 cfg.sens.writeExcel 开启）。
% 该分析不参与寻优，只用 res.cap 反复求内层最优调度，对最优解零影响。
doSens = isfield(cfg, 'sens') && isstruct(cfg.sens) && logical(cfg.sens.enable) && ...
         ( (cfg.out.makePlots && gopt_flag(cfg, 'sensitivity')) || ...
           (cfg.out.writeExcel && logical(cfg.sens.writeExcel)) );

SEN = [];
if doSens
    SEN = gopt_sensitivity(res, ds, sc, cfg);
    if ~isempty(SEN)
        if cfg.out.makePlots && gopt_flag(cfg, 'sensitivity')
            gopt_plot_sensitivity(SEN, res, cfg);
        end
        if cfg.out.writeExcel && logical(cfg.sens.writeExcel)
            gopt_export_sensitivity(SEN, cfg);
        end
        % 敏感性扫描明细单独留档。为什么必须单独存：主线 optimization_results.mat
        % 在这一段之前就已经写出，SEN 只存在于本轮运行的内存里；不留档的话，日后想
        % 调整这张图的样式（配色、子图开关、标注位置……）就得重跑整轮扫描（约 24 min）。
        if isfield(cfg.out, 'saveMat') && cfg.out.saveMat
            sensFile = fullfile(cfg.path.outDir, 'sensitivity_results.mat');
            save(sensFile, 'SEN');
            if ~cfg.io.quiet
                fprintf(['[敏感性] 扫描明细已另存档：%s\n' ...
                         '         （日后只想改图样式时可直接复用该文件，不必重跑扫描）\n'], sensFile);
            end
        end
    end
elseif ~cfg.io.quiet
    fprintf(['[敏感性] 已跳过：cfg.sens.enable = %d，或出图/Excel 的相关开关均未开启。\n'], ...
        double(isfield(cfg, 'sens') && isstruct(cfg.sens) && cfg.sens.enable));
end

%% ---------- 11. 收尾提示 ----------
fprintf('  结果 Excel / 图片 / MAT 已输出到：%s\n', cfg.path.outDir);
fprintf('  提示：只做内层调度 -> 在「运行控制区」填 OVR.pvFixed = 30;（详见文件顶部说明）\n');
fprintf('  提示：改完模型或参数后，建议先把 RUN_SELFTEST 改为 true 跑一次自检。\n');
fprintf('  提示：敏感性分析最耗时，只想快速看主线结果时可把 cfg.sens.enable 设为 false。\n');
fprintf('%s\n', repmat('=', 1, 82));


%% =========================================================================
%% ==============  以下为内部函数（脚本文件末尾允许放本地函数）  ==============
%% =========================================================================

%% ------------------------------------------------- 运行控制区参数覆盖
function cfg = gopt_apply_overrides(cfg, o)
%GOPT_APPLY_OVERRIDES  用「运行控制区」的 OVR 结构体临时覆盖 cfg 中的参数
%   留空（[]）的字段表示不覆盖；未知字段会报错，避免拼写错误被静默忽略。
if isempty(o) || ~isstruct(o), return; end
f = fieldnames(o);
sawFlatCapex = false;      % 是否覆盖过「常数单价」（tiered 口径下这些覆盖会被忽略，需提示）
for i = 1:numel(f)
    key = lower(f{i});
    val = o.(f{i});
    if isempty(val), continue; end
    switch key
        case 'mode',          cfg.time.mode = char(val);
        case 'ntypical',      cfg.time.nTypicalDays = val;
        case 'typdaysort',    cfg.time.typDaySort = char(val);
        case 'weekmode',      cfg.time.weekMode = val;
        case 'cyclemode',     cfg.ess.cycleMode = char(val);
        case 'yearcyclic',    cfg.time.yearCyclic = char(val);
        case 'pvfixed',       cfg.fixed.pv = val;
        case 'wtfixed',       cfg.fixed.wt = val;
        case 'esspfixed',     cfg.fixed.essP = val;
        case 'esstfixed',     cfg.fixed.essT = val;
        case 'essefixed',     cfg.fixed.esse = val;
        case 'genfixed',      cfg.fixed.gen  = val;
        case 'costmode',      cfg.cost.mode = lower(char(val));
        case 'pvcapex',       cfg.cost.pv.capex = val;          sawFlatCapex = true;
        case 'wtcapex',       cfg.cost.wt.capex = val;          sawFlatCapex = true;
        case 'esscapexp',     cfg.cost.ess.capexP = val;        sawFlatCapex = true;
        case 'esscapexe',     cfg.cost.ess.capexE = val;        sawFlatCapex = true;
        case 'pvtier',        cfg.cost.pv.tier  = gopt_check_tier('OVR.pvTier',   val);
        case 'wttier',        cfg.cost.wt.tier  = gopt_check_tier('OVR.wtTier',   val);
        case 'essptier',      cfg.cost.ess.tierP= gopt_check_tier('OVR.essPTier', val);
        case 'essetier',      cfg.cost.ess.tierE= gopt_check_tier('OVR.essETier', val);
        case 'gencapex',      cfg.cost.gen.capex = val;
        case 'genlife',       cfg.cost.gen.life = val;
        case 'genopex',       cfg.cost.gen.opexRate = val;
        case 'genvarcost',    cfg.cost.gen.varCost = val;
        case 'gencurtmode',   cfg.const.genCurtMode = char(val);
        case 'genmode',       cfg.data.genMode = char(val);
        case 'discount',      cfg.cost.discountRate = val;
        case 'importmax',     cfg.const.gridImportMax = val;
        case 'exportmax',     cfg.const.gridExportMax = val;
        case 'allowcurtail',  cfg.const.allowCurtail = logical(val);
        case 'npop',          cfg.pso.nPop = val;
        case 'maxiter',       cfg.pso.maxIter = val;
        case 'seed',          cfg.pso.seed = val;
        case 'localrefine',   cfg.pso.localRefine = logical(val);
        case 'cache',         cfg.pso.cacheEval = logical(val);
        case 'twostage',      cfg.pso.twoStage = logical(val);
        case 'stagea',        cfg.pso.stageA = val;
        case 'boundcheck',    cfg.pso.boundCheck = logical(val);
        case 'multirun',      cfg.pso.multiRun = val;
        case 'fullyearcheck', cfg.out.fullYearCheck = logical(val);
        case 'strictdispatch',cfg.out.strictDispatch = logical(val);
        case 'makeplots',     cfg.out.makePlots = logical(val);
        case 'plotdays',      cfg.out.plotDays = val;          % 按典型日编号选（如 1:4）
        case 'plotwhichdays', cfg.out.plotWhichDays = val;     % 按自然日区间选（N x 2）
        case 'plotwhichminfrac', cfg.out.plotWhichMinFrac = val;
        case 'plotfigures',   cfg.out.plotFigures = val;       % 图种开关结构体
        case 'writeexcel',    cfg.out.writeExcel = logical(val);
        case 'savemat',       cfg.out.saveMat = logical(val);
        case 'figlang',       cfg.out.figLang = char(val);
        case 'dpi',           cfg.out.dpi = val;
        case 'quiet',         cfg.io.quiet = logical(val);
        case 'showmonthhist', cfg.out.showMonthHist = logical(val);
        % ---- 敏感性分析 ----
        case 'sensenable',    cfg.sens.enable = logical(val);
        case 'sensmode',      cfg.sens.mode = char(val);
        case 'sensnpoint',    cfg.sens.nPoint = val;
        case 'sensrelrange',  cfg.sens.relRange = val;
        case 'sensbase',      cfg.sens.base = val(:);
        otherwise
            error(['OVR 中存在未知字段：%s\n' ...
                   '请检查拼写，或对照 run_greenopt.m「运行控制区」的字段清单。'], f{i});
    end
end
% tiered 口径下「常数单价」覆盖会被静默忽略 —— 必须明确提示，
% 否则使用者会以为「改了 pvCapex 却没生效」是程序 bug（本仓库最忌讳的静默行为）。
if sawFlatCapex && strcmp(gopt_cost_mode(cfg), 'tiered')
    fprintf(['[配置] 注意：当前成本口径为 ''tiered''（分档单价），' ...
             'OVR 里给出的 *_Capex 常数单价虽已写入 cfg，但**不参与计算**。\n' ...
             '       要改单价请覆盖对应的分档表：OVR.pvTier / OVR.wtTier / ' ...
             'OVR.essPTier / OVR.essETier；或把 OVR.costMode 设为 ''flat''。\n']);
end
end

%% ------------------------------------------------------- 应用便捷固定配置
function cfg = gopt_apply_fixed(cfg)
%GOPT_APPLY_FIXED  把 cfg.fixed.* 折算进搜索范围，并把搜索维度统一补齐到 5 维
%
%  5 维顺序：[光伏容量 ; 风电容量 ; 储能功率 ; 储能时长 ; 自发电容量]（MW / MW / MW / h / MW）
%  向后兼容：cfg.pso.lb/ub 允许只写前 4 维（旧参数文件），这里自动补第 5 维的默认范围。

% ---- 0. 维度补齐（4 -> 5）----
% 默认上界 100 MW 与 cfg_greenopt.m 里的工程上界一致；自发电这一维是「工程硬界」，
% 不允许自动外扩（见 cfg.pso.expandFree），故补齐时也必须给一个明确的数。
GEN_UB_DEFAULT = 100;
if numel(cfg.pso.lb) == 4
    cfg.pso.lb(5, 1) = 0;
    cfg.pso.ub(5, 1) = GEN_UB_DEFAULT;
    fprintf(['[配置] cfg.pso.lb/ub 仅给出 4 维，已自动补第 5 维「厂内自发电容量」' ...
             '的默认范围 [0, %g] MW。\n'], GEN_UB_DEFAULT);
end
assert(numel(cfg.pso.lb) == 5 && numel(cfg.pso.ub) == 5, ...
    ['cfg.pso.lb / ub 必须是 5 维（或 4 维由程序补齐）：' ...
     '[光伏容量; 风电容量; 储能功率; 储能时长; 自发电容量]。']);

% ---- 1. 便捷固定配置 ----
if ~isempty(cfg.fixed.pv),   cfg.pso.lb(1) = cfg.fixed.pv;   cfg.pso.ub(1) = cfg.fixed.pv;   end
if ~isempty(cfg.fixed.wt),   cfg.pso.lb(2) = cfg.fixed.wt;   cfg.pso.ub(2) = cfg.fixed.wt;   end
if ~isempty(cfg.fixed.essP), cfg.pso.lb(3) = cfg.fixed.essP; cfg.pso.ub(3) = cfg.fixed.essP; end
if ~isempty(cfg.fixed.essT), cfg.pso.lb(4) = cfg.fixed.essT; cfg.pso.ub(4) = cfg.fixed.essT; end
if ~isempty(cfg.fixed.gen),  cfg.pso.lb(5) = cfg.fixed.gen;  cfg.pso.ub(5) = cfg.fixed.gen;  end
if ~isempty(cfg.fixed.esse)
    assert(~isempty(cfg.fixed.essP), ...
        'cfg.fixed.esse 需与 cfg.fixed.essP 同时给出，才能由容量换算时长。');
    assert(cfg.fixed.essP > 0, ...
        'cfg.fixed.essP <= 0 时无法由储能容量换算时长；请直接固定时长（cfg.fixed.essT）。');
    Td = cfg.fixed.esse / cfg.fixed.essP;
    cfg.pso.lb(4) = Td;  cfg.pso.ub(4) = Td;
    fprintf('[配置] 由储能容量 %.4g MWh / 功率 %.4g MW 换算得储能时长 %.4g h。\n', ...
        cfg.fixed.esse, cfg.fixed.essP, Td);
end

% ---- 2. Gen 列是 MW 口径时，把第 5 维锁成「单位容量 = 1」----
% 此时实际出力 = 1 x Gen 列原值 = 旧的 MW 行为，完全向后兼容。
% 用「锁成 1」而不是「锁成 0」是刻意的：锁 0 会让自发电出力恒等于 0，
% 与旧版行为不同；而 1 才是「不改变数据原值」的中性元。
genMode = 'pu';
if isfield(cfg, 'data') && isfield(cfg.data, 'genMode') && ~isempty(cfg.data.genMode)
    genMode = lower(char(cfg.data.genMode));
end
if strcmp(genMode, 'mw')
    assert(isempty(cfg.fixed.gen) || abs(cfg.fixed.gen - 1) < 1e-12, ...
        ['cfg.data.genMode = ''mw'' 时第 5 维必须锁定为「单位容量 1」，' ...
         '不能再固定为其它值（该口径下 Gen 列本身就是 MW）。']);
    cfg.pso.lb(5) = 1;  cfg.pso.ub(5) = 1;
    cfg.pso.expandFree(5) = false;
    fprintf(['[配置] cfg.data.genMode = ''mw''：Gen 列按 MW 直接使用，' ...
             '第 5 维已锁定为 1。\n']);
end
cfg.data.genMode = genMode;

% ---- 3. 自发电容量固定为 0 时，明确告知等价性（便于与旧版结果对照）----
if cfg.pso.lb(5) == 0 && cfg.pso.ub(5) == 0
    fprintf(['[配置] 自发电容量已固定为 0：本算例自发电不参与功率平衡，' ...
             '结果与「未引入自发电」的旧版口径等价。\n']);
end

assert(all(cfg.pso.ub >= cfg.pso.lb), '搜索范围非法：存在 ub < lb 的维度。');
end

%% ------------------------------------------------------------ 资金回收系数
function c = gopt_crf(i, N)
c = i * (1 + i)^N / ((1 + i)^N - 1);
end

%% ------------------------------------------------- 成本计价口径（唯一实现）
function mode = gopt_cost_mode(cfg)
%GOPT_COST_MODE  读取成本计价口径 cfg.cost.mode（缺字段时按 'flat' 处理，旧 cfg 仍能跑）
%   'flat'   常数单价：投资额 = 容量 x capex（改动前的口径）
%   'tiered' 分档单价：投资额 = 容量 x 插值单价（本轮新增）
%   单独抽成函数的原因与 gopt_life_mode 相同：口径被多处读（gopt_unit_price 用它选分支、
%   gopt_gen_cost 用它决定自发电是否走分档表），只定义一次才不会读岔。
mode = 'flat';
if nargin >= 1 && isstruct(cfg) && isfield(cfg, 'cost') ...
        && isfield(cfg.cost, 'mode') && ~isempty(cfg.cost.mode)
    mode = lower(char(cfg.cost.mode));
end
assert(any(strcmp(mode, {'flat', 'tiered'})), ...
    ['cfg.cost.mode 只接受 ''flat''（常数单价）或 ''tiered''（分档单价），当前为 ''%s''。'], mode);
end

%% ------------------------------------------------------ 分档单价表输入校验
function tbl = gopt_check_tier(nm, tbl)
%GOPT_CHECK_TIER  校验分档单价表并规范化（N x 2 双精度、档位严格递增、单价为正）
%   为什么必须在流程最开头校验：分档表是「一眼看不出错」的输入 —— 档位写反、少一列、
%   单价填成 0，传进插值函数都不会当场报错，只会让成本悄悄算错（本仓库最忌讳的问题）。
tbl = double(tbl);
assert(ndims(tbl) == 2 && size(tbl, 2) == 2 && size(tbl, 1) >= 2, ...
    ['%s 必须是 N x 2 的矩阵（N >= 2，每行一档）：第 1 列 = 容量档位，' ...
     '第 2 列 = 该档位处的投资单价。当前尺寸为 %s。'], nm, mat2str(size(tbl)));
assert(all(isfinite(tbl(:))), '%s 中存在非有限数值（NaN / Inf）。', nm);
assert(all(diff(tbl(:, 1)) > 0), ...
    ['%s 的第 1 列（容量档位）必须严格递增，当前为 %s。' ...
     '分段线性插值要求各结点按容量升序排列，写反会得到完全错误的单价。'], ...
     nm, mat2str(tbl(:, 1)'));
assert(all(tbl(:, 1) >= 0), '%s 的第 1 列（容量档位）必须 >= 0。', nm);
assert(all(tbl(:, 2) > 0), ...
    ['%s 的第 2 列（投资单价）必须 > 0。' ...
     '填 0 会让该档容量看起来免费，PSO 会立刻把容量顶到那一档。'], nm);
end

function t = gopt_tier_or_empty(nm, s, f)
%GOPT_TIER_OR_EMPTY  读取可选的 tier 字段并校验（字段缺失或为空 => 返回 []，表示该资产无分档表）
t = [];
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    t = gopt_check_tier(nm, s.(f));
end
end

function cfg = gopt_check_cost_tables(cfg)
%GOPT_CHECK_COST_TABLES  在流程最开头校验 4 张分档单价表，并把规范化后的表写回 cfg
%   位置刻意放在「读完参数之后、任何求解之前」：宁可在这里报一句说得清楚的错，
%   也不要等 PSO 搜了几个小时之后才因为一张表写错而给出错误结论。
cfg.cost.pv.tier   = gopt_tier_or_empty('cfg.cost.pv.tier',   cfg.cost.pv,  'tier');
cfg.cost.wt.tier   = gopt_tier_or_empty('cfg.cost.wt.tier',   cfg.cost.wt,  'tier');
cfg.cost.ess.tierP = gopt_tier_or_empty('cfg.cost.ess.tierP', cfg.cost.ess, 'tierP');
cfg.cost.ess.tierE = gopt_tier_or_empty('cfg.cost.ess.tierE', cfg.cost.ess, 'tierE');
% 开关护栏：允许/禁止「搜索上界压在分档封顶档位」。缺字段时按 false（禁止）处理 ——
% 默认拦下来，而不是默认放过，理由见 gopt_check_tier_ub 的说明。
if ~isfield(cfg.cost, 'allowTierEdgeBound') || isempty(cfg.cost.allowTierEdgeBound)
    cfg.cost.allowTierEdgeBound = false;
end
cfg.cost.allowTierEdgeBound = logical(cfg.cost.allowTierEdgeBound);
if strcmp(gopt_cost_mode(cfg), 'tiered')
    assert(~isempty(cfg.cost.pv.tier) && ~isempty(cfg.cost.wt.tier) && ...
           ~isempty(cfg.cost.ess.tierP) && ~isempty(cfg.cost.ess.tierE), ...
        ['cfg.cost.mode = ''tiered''（分档单价）时四项资产都必须给出分档表：' ...
         'cfg.cost.pv.tier / cfg.cost.wt.tier / cfg.cost.ess.tierP / cfg.cost.ess.tierE。' ...
         '缺哪张补哪张；或把 cfg.cost.mode 改回 ''flat'' 走常数单价。']);
end
end

%% ------------------------------------------------ 单位投资单价（唯一实现）
function [p, info] = gopt_unit_price(C, mode, capexFlat, tierTbl, capUnit, priceUnit)
%GOPT_UNIT_PRICE  单项资产的「单位投资单价」——分档 / 常数两种口径的唯一实现
%
%  为什么必须唯一实现：单价是整条成本链的第一环，它被「年化投资 -> 外层适应度 /
%  Excel 报表 / 成本构成图 / 敏感性堆叠图 / 命令行假设块 / 自检复算」全部继承。
%  若各处各查一次档，必然随时间漂移（本仓库最忌讳的口径漂移）。所以只在这里定义一次。
%
%  ── 口径（投资额 = 容量 x p）──
%     mode = 'flat'   : p = capexFlat（与该资产装了多大无关）
%     mode = 'tiered' : p = 分档表在容量 C 处的**分段线性插值**（档位即插值结点）
%                       容量 >= 表中【倒数第二行】的档位时，p = 【最后一行】的单价
%                       —— 不插值、不外推（按「≥500 按 20000 档」的口径实现）
%
%  输入  C         容量（标量，负数按 0 处理）[capUnit]
%        mode      'flat' | 'tiered'
%        capexFlat 常数单价 [priceUnit]（flat 口径用；tiered 下作为对照值放进 info）
%        tierTbl   分档表 N x 2 [档位, 单价]（tiered 口径用；空 => 自动退化为 flat）
%        capUnit   容量单位文本（'MW' / 'MWh'），仅用于生成提示语
%        priceUnit 单价单位文本（'元/kW' / '元/kWh'），仅用于生成提示语
%  输出  p         单位投资单价 [priceUnit]
%        info      明细结构体：.mode .isTier .tbl .p .flat .idx .lo .hi .pLo .pHi
%                             .xTop .pTop .clamped .capUnit .priceUnit .note
%                  报表 / 出图 / 自检一律读它，不再二次解析字符串（note 只是给人看的）。
%
%  例（本算例的光伏表，结点 0/6/20/50/100/200/500，单价 3500/3200/3100/3000/...）：
%     C = 37.5 MW -> 落在第 3 档（区间 20~50 MW），
%     p = 3100 + (3000 - 3100) x (37.5 - 20) / (50 - 20) = 3041.6667 元/kW

C = max(double(C), 0);
assert(isscalar(C) && isfinite(C), 'gopt_unit_price 的容量入参必须是有限标量。');

info.mode      = mode;
info.capUnit   = capUnit;
info.priceUnit = priceUnit;
info.flat      = capexFlat;
info.p         = capexFlat;
info.isTier    = false;
info.tbl       = [];
info.idx       = 1;
info.lo        = 0;
info.hi        = 0;
info.pLo       = capexFlat;
info.pHi       = capexFlat;
info.xTop      = NaN;
info.pTop      = NaN;
info.clamped   = false;

useTier = strcmp(mode, 'tiered') && ~isempty(tierTbl) && size(tierTbl, 1) >= 2;
if ~useTier
    % ---- flat：常数单价 ----
    % 同时也覆盖「tiered 但该资产没有分档表」的情形（例如厂内自发电）。
    info.note = sprintf('常数单价 %.4g %s', capexFlat, priceUnit);
    p = capexFlat;
    return;
end

x = tierTbl(:, 1);   y = tierTbl(:, 2);
n = numel(x);
xTop = x(n - 1);     % 封顶档位（表中倒数第二行）
pTop = y(n);         % 封顶后的单价（表中最后一行）
info.isTier = true;
info.tbl    = [x, y];
info.xTop   = xTop;
info.pTop   = pTop;

if C >= xTop
    % ---- TOPT：容量 >= 封顶档位 => 直接取最后一行的单价，不插值、不外推 ----
    % 若想让「封顶档位 ~ 最后一行档位」之间（例如 500~20000）也线性过渡，
    % 把本分支整段删掉即可：下面的分段线性插值会自动接管这一段（k 的上限改为 n-1）。
    info.clamped = true;
    info.idx     = n;
    info.lo      = xTop;
    info.hi      = Inf;
    info.pLo     = pTop;
    info.pHi     = pTop;
    p            = pTop;
    info.note = sprintf('落在第 %d 档（区间 >=%g %s，单价 %.4g %s）', ...
        n, xTop, capUnit, p, priceUnit);
    return;
end

% ---- 分段线性插值 ----
% 命中区间 [x(k), x(k+1)]；k 的上限刻意取 n-2，保证最后一段（xTop ~ 最后一行档位）
% 永远不参与插值（那段由上面的 TOPT 分支接管）。
k = find(x <= C, 1, 'last');
if isempty(k), k = 1; end
k  = min(k, n - 2);
lo = x(k);
hi = x(k + 1);
w  = min(max((C - lo) / max(hi - lo, eps), 0), 1);
p  = y(k) + (y(k + 1) - y(k)) * w;

info.idx = k;
info.lo  = lo;
info.hi  = hi;
info.pLo = y(k);
info.pHi = y(k + 1);
info.p   = p;
if w < 1e-12 || w > 1 - 1e-12
    % 容量正好落在档位结点上：单价就是该结点的表内值，不必说「插值」
    info.note = sprintf('落在第 %d 档（区间 %g~%g %s，单价 %.4g %s）', ...
        k, lo, hi, capUnit, p, priceUnit);
else
    info.note = sprintf('落在第 %d 档（区间 %g~%g %s，插值单价 %.4g %s）', ...
        k, lo, hi, capUnit, p, priceUnit);
end
end

%% ------------------------------------------------------- 分档表摘要（一行）
function s = gopt_tier_summary(tbl, capUnit, priceUnit)
%GOPT_TIER_SUMMARY  把一张分档表压成一行可读摘要（命令行「参数」块与 Excel 共用）
if isempty(tbl)
    s = '未定义分档表（该资产按常数单价计）';
    return;
end
x = tbl(:, 1);   y = tbl(:, 2);   n = numel(x);
s = sprintf(['%d 档｜插值结点 %s %s 对应单价 %s %s（分段线性插值）；' ...
             '>=%g %s 取最后一档（%g）的 %.4g %s'], ...
    n, mat2str(x(1:n-1)'), capUnit, mat2str(y(1:n-1)'), priceUnit, ...
    x(n - 1), capUnit, x(n), y(n), priceUnit);
end

%% --------------------------------------------- 各档贡献的投资额（链式分解）
function [base, seg, total] = gopt_tier_chain(info, C)
%GOPT_TIER_CHAIN  「容量 x 插值单价」的链式分解 —— 各档贡献的投资额（各档之和恒等于总投资额）
%
%  为什么需要它：分档单价是非线性的，只报一个总投资额，读者既看不出「多装一点到底
%  省了多少钱」，也无法核对单价是否真的按分档表取。链式分解把投资额摊到每一档上。
%
%  ── 数学（分段线性插值下是**精确恒等式**，不是近似）──
%     p(C) = y1 + Σ_{k=1..j} Δk·wk          Δk = y(k+1) - y(k)，wk = 第 k 段被覆盖的比例
%     => 投资额 = C·y1 + Σ C·Δk·wk
%  于是：
%     · 第 1 项 C·y1            = 「以第 1 档单价为基准」的量（正）；
%     · 其余每项 C·Δk·wk        = 「容量跨过第 k 档时，因单价变化而增减的投资额」
%                                 （本算例各档单价随容量下降 => Δk < 0 => 负贡献 = 省下的钱）。
%  各项之和恒等于该资产的初始投资额 —— 这就是「各档贡献的投资额」的严格定义
%  （在用户选定的「投资额 = 容量 x 插值单价」口径下）。
%
%  输入  info  gopt_unit_price 的返回值（isTier = false 时原样返回 0 / 空 / 0）
%        C     容量 [MW] 或 [MWh]
%  输出  base  第 1 档基准项 [万元]
%        seg   K x 3：[段下标 k, 覆盖比例 wk, 该段贡献(万元)]
%        total 合计 [万元] = base + Σ seg(:,3)，恒等于 容量 x 单价 / 10
base  = 0;
seg   = zeros(0, 3);
total = 0;
if ~isfield(info, 'isTier') || ~info.isTier, return; end

x = info.tbl(:, 1);   y = info.tbl(:, 2);   n = numel(x);
C = max(double(C), 0);

% 单位换算只有一行：投资额(万元) = 容量 x 1000(kW/MW 或 kWh/MWh) x 单价 / 1e4 = 容量 x 单价 / 10
% 因此「万元 = F x 单价」，F = C / 10 对 MW->元/kW 与 MWh->元/kWh 两种组合同时成立。
F = C / 10;

if info.clamped
    jSeg = n - 1;                     % 容量已越过封顶档位：前 n-1 段全部走满
    wk   = ones(jSeg, 1);
else
    jSeg = info.idx;
    wk   = ones(jSeg, 1);
    lo   = x(jSeg);   hi = x(jSeg + 1);
    wk(jSeg) = min(max((C - lo) / max(hi - lo, eps), 0), 1);
end

base = F * y(1);
for k = 1:jSeg
    dk = y(k + 1) - y(k);
    seg(end + 1, :) = [k, wk(k), F * dk * wk(k)];      %#ok<AGROW>
end
total = base + sum(seg(:, 3));
end

%% ------------------------------------------------ 五项资产的单价/投资装配
function it = gopt_price_items(cap, capD, cfg)
%GOPT_PRICE_ITEMS  把「资产 -> 容量 -> 单价明细 -> 初始投资 -> 年化费用率」装配成 5 行结构体数组
%   五项 = 光伏 / 风电 / 储能功率 / 储能容量 / 厂内自发电。
%   ★ 储能功率与储能容量刻意分成两行：它们取自两张独立的分档表
%     （BatteryPCS 按 MW 计 元/kW；BatteryCost 按 MWh 计 元/kWh），
%     合成一行就看不清单价到底取自哪张表，也无法核对两类成本是否各自分档。
it = struct('kind', {}, 'name', {}, 'qty', {}, 'unit', {}, 'info', {}, 'inv', {}, 'rate', {});
it(1) = struct('kind', 'pv',   'name', '光伏',       'qty', cap(1), 'unit', 'MW',  ...
    'info', capD.u.pv,   'inv', capD.inv.pv,   'rate', capD.crfPv  + cfg.cost.pv.opexRate);
it(2) = struct('kind', 'wt',   'name', '风电',       'qty', cap(2), 'unit', 'MW',  ...
    'info', capD.u.wt,   'inv', capD.inv.wt,   'rate', capD.crfWt  + cfg.cost.wt.opexRate);
it(3) = struct('kind', 'essP', 'name', '储能功率',   'qty', cap(3), 'unit', 'MW',  ...
    'info', capD.u.essP, 'inv', capD.inv.essP, 'rate', capD.crfEss + cfg.cost.ess.opexRate);
it(4) = struct('kind', 'essE', 'name', '储能容量',   'qty', cap(4), 'unit', 'MWh', ...
    'info', capD.u.essE, 'inv', capD.inv.essE, 'rate', capD.crfEss + cfg.cost.ess.opexRate);
it(5) = struct('kind', 'gen',  'name', '厂内自发电', 'qty', cap(5), 'unit', 'MW',  ...
    'info', capD.genD.u, 'inv', capD.inv.gen,  'rate', capD.genD.a);
end

function L = gopt_price_lines(cap, capD, cfg)
%GOPT_PRICE_LINES  投资单价口径 + 五项资产「命中档」提示（命令行与 Excel 共用同一份文本）
%   为什么要抽成函数：同一段口径说明要同时出现在命令行「最优配置结果」与 Excel 两处，
%   分散写必然随时间漂移（改了一处忘了另一处），所以只生成一次、两处都引用它。
%   提示语格式即需求指定的那个：落在第 X 档（区间 a~b MW，单价 c 元/kW）。
it = gopt_price_items(cap, capD, cfg);
L  = cell(0, 1);
if strcmp(capD.costMode, 'tiered')
    L{end + 1} = '投资单价口径      : 分档单价（按容量在分档表上分段线性插值；投资额 = 容量 x 插值单价）';
else
    L{end + 1} = '投资单价口径      : 常数单价（cfg.cost.mode = ''flat''；投资额 = 容量 x 单价）';
end
for k = 1:numel(it)
    L{end + 1} = sprintf('    %s %.3f %s : %s  ->  初始投资 %.2f 万元', ...
        it(k).name, it(k).qty, it(k).unit, it(k).info.note, it(k).inv / 1e4);
end
L{end + 1} = sprintf(['    初始投资合计      : %.2f 万元（五项之和）' ...
    '；逐档明细（各档贡献的投资额 / 逐档对照）见 Excel「分档明细」工作表'], ...
    sum([it.inv]) / 1e4);
end

%% ------------------------------------------------------ 单元格整行补齐
function c = gopt_rowpad(c, n)
%GOPT_ROW_PAD  把一行 cell 补齐 / 截断到 n 列（writecell 要求写入的 cell 块是矩形）
c = c(:)';
if numel(c) < n, c(end + 1:n) = {''}; end
if numel(c) > n, c = c(1:n); end
end

%% ------------------------------------------------ 「分档明细」工作表单元格
function C = gopt_tier_detail_cells(cap, capD, cfg)
%GOPT_TIER_DETAIL_CELLS  生成 Excel「分档明细」工作表的全部单元格（甲 / 乙 / 丙 三块）
%
%  甲  本次配置命中档：五项资产各自的容量、命中档、本次单价、初始投资、年化费用率
%  乙  阶梯明细：各档贡献的投资额（链式分解，**各档之和恒等于甲块的投资额**）
%  丙  逐档对照：分档表本身的规模效应（本档容量上限 x 本档表内单价 = 该档对应投资额）
%
%  为什么三块都要：只报一个总投资额，读者既看不出单价取了哪一档，也看不出「容量再大
%  一档，钱会多多少 / 少多少」。乙块回答「多装一点省了多少钱」，丙块回答「表里每一档
%  在什么量级」，甲块回答「本次到底用了哪一档」。
NC = 9;                                    % 固定 9 列：writecell 要求整块矩形
it = gopt_price_items(cap, capD, cfg);
C  = cell(0, NC);

% ---- 0. 口径说明 ----
C(end + 1, :) = gopt_rowpad({'项目', '内容'}, NC);
C(end + 1, :) = gopt_rowpad({'成本计价口径', sprintf('cfg.cost.mode = ''%s''（%s）', ...
    capD.costMode, gopt_tern(strcmp(capD.costMode, 'tiered'), ...
    '分档单价：单位投资单价按容量在分档表上分段线性插值，投资额 = 容量 x 插值单价', ...
    '常数单价：单位投资单价与容量无关，投资额 = 容量 x 常数单价'))}, NC);
C(end + 1, :) = gopt_rowpad({'分档表来源', ...
    'BasicDataTables.xlsx -> PVCost / WindCost / BatteryPCS / BatteryCost（投资单价已含税）'}, NC);
C(end + 1, :) = gopt_rowpad({'计取规则', ...
    '容量 <= 表中倒数第二行的档位（500）分段线性插值；容量 >= 500 直接取最后一行（20000 档）的单价，不插值、不外推（故 500 处有一个单点跳变）'}, NC);
C(end + 1, :) = gopt_rowpad({'储能分档说明', ...
    '储能功率按 BatteryPCS 表（元/kW）独立分档、储能容量按 BatteryCost 表（元/kWh）独立分档，两者互不影响'}, NC);
C(end + 1, :) = gopt_rowpad({'厂内自发电', '无分档表，按常数单价计（与 cfg.cost.mode 无关）'}, NC);
C(end + 1, :) = gopt_rowpad({sprintf('初始投资合计：%.2f 万元（五项之和）', sum([it.inv]) / 1e4)}, NC);
C(end + 1, :) = gopt_rowpad({''}, NC);

% ---- 甲：本次配置命中情况 ----
C(end + 1, :) = gopt_rowpad({'【甲】本次配置命中档（本块五项之和 = 上面的初始投资合计）'}, NC);
C(end + 1, :) = gopt_rowpad({'资产', '容量', '单位', '命中档提示', '本次采用单价', ...
    '单价单位', '初始投资(万元)', '年化费用率(CRF+运维)'}, NC);
for k = 1:numel(it)
    C(end + 1, :) = gopt_rowpad({it(k).name, it(k).qty, it(k).unit, it(k).info.note, ...
        it(k).info.p, it(k).info.priceUnit, it(k).inv / 1e4, it(k).rate}, NC);
end
C(end + 1, :) = gopt_rowpad({'合计', '', '', '', '', '', sum([it.inv]) / 1e4, ''}, NC);
C(end + 1, :) = gopt_rowpad({''}, NC);

% ---- 乙：阶梯明细（各档贡献的投资额，链式分解）----
C(end + 1, :) = gopt_rowpad({'【乙】阶梯明细：各档贡献的投资额（链式分解；各档之和恒等于该资产在【甲】块的投资额）'}, NC);
C(end + 1, :) = gopt_rowpad({'口径：单价 p(C) = 第 1 档单价 + Σ(Δk x wk)，投资额 = 容量 x p(C) = 基准项 + Σ(该档贡献)'}, NC);
C(end + 1, :) = gopt_rowpad({'资产', '阶梯项', '单价变动 Δ', 'Δ单位', '覆盖比例 w', ...
    '该档贡献(万元)', '含义', '', ''}, NC);
for k = 1:numel(it)
    info = it(k).info;
    if ~info.isTier
        C(end + 1, :) = gopt_rowpad({it(k).name, '常数单价', '-', info.priceUnit, '-', ...
            it(k).inv / 1e4, '无分档表，投资额 = 容量 x 常数单价，不作阶梯分解', '', ''}, NC);
        continue;
    end
    [bse, seg, tot] = gopt_tier_chain(info, it(k).qty);
    C(end + 1, :) = gopt_rowpad({it(k).name, '基准项（第 1 档单价 y1）', '-', info.priceUnit, '-', ...
        bse, sprintf('= 容量 x 第 1 档单价 %.4g %s', info.tbl(1, 2), info.priceUnit), '', ''}, NC);
    for j = 1:size(seg, 1)
        dk = info.tbl(j + 1, 2) - info.tbl(j, 2);
        C(end + 1, :) = gopt_rowpad({it(k).name, ...
            sprintf('第 %d 档（%g ~ %g）', j, info.tbl(j, 1), info.tbl(j + 1, 1)), ...
            dk, info.priceUnit, seg(j, 2), seg(j, 3), ...
            gopt_tern(dk < 0, '单价下降 => 负贡献 = 容量跨过本档省下的投资额', ...
                              '单价上升 => 正贡献 = 容量跨过本档多花的投资额'), '', ''}, NC);
    end
    C(end + 1, :) = gopt_rowpad({it(k).name, '合计', '-', info.priceUnit, '-', tot, ...
        '= 该资产初始投资额（万元），与【甲】块一致', '', ''}, NC);
end
C(end + 1, :) = gopt_rowpad({''}, NC);

% ---- 丙：逐档对照（分档表本身的规模效应）----
C(end + 1, :) = gopt_rowpad({'【丙】逐档对照：本档容量上限 x 本档表内单价 = 该档对应的投资额'}, NC);
C(end + 1, :) = gopt_rowpad({'用途：核对「容量再大一档时投资额会变成多少」；本块各行不参与成本汇总，本次实际投资额以【甲】块为准'}, NC);
C(end + 1, :) = gopt_rowpad({'说明：表中的档位是插值结点，相邻两档之间线性过渡（构成下面的「插值段」）；容量 >= 倒数第二行的档位时一律取最后一行的单价，即下面「常数段」那一行，不插值也不外推'}, NC);
C(end + 1, :) = gopt_rowpad({'资产', '档位', '容量区间', '表内单价', '单价单位', ...
    '区间上限容量', '该档对应投资额(万元)', '本次是否命中', '说明'}, NC);
for k = 1:numel(it)
    info = it(k).info;
    if ~info.isTier
        C(end + 1, :) = gopt_rowpad({it(k).name, '-', '常数单价（无分档表）', info.flat, ...
            info.priceUnit, '-', it(k).inv / 1e4, '是（常数单价）', '该资产不参与分档，投资额 = 容量 x 常数单价'}, NC);
        continue;
    end
    xt = info.tbl(:, 1);   yt = info.tbl(:, 2);   n = numel(xt);
    for j = 1:n - 2
        % 真正的插值段：档位 1 ~ n-2（相邻两个插值结点之间线性过渡）。
        % ⚠ 刻意不列「倒数第二档 ~ 最后一档」那一段：按「容量 >= 500 取 20000 档单价」的
        %   口径，那一段根本不参与插值，列出来会被误读成「500~20000 之间线性过渡」。
        upCap = xt(j + 1);
        C(end + 1, :) = gopt_rowpad({it(k).name, j, sprintf('%g ~ %g', xt(j), upCap), ...
            yt(j), info.priceUnit, upCap, upCap * yt(j) / 10, ...
            gopt_tern(~info.clamped && j == info.idx, '是（本次命中）', '否'), ...
            '插值段：本档区间内单价在两端之间线性过渡'}, NC);
    end
    % 常数段：容量 >= 倒数第二行的档位时，一律取最后一行的单价（不插值、不外推）
    C(end + 1, :) = gopt_rowpad({it(k).name, '常数段', sprintf('>=%g', xt(n - 1)), yt(n), ...
        info.priceUnit, '-', '-', gopt_tern(info.clamped, '是（本次命中）', '否'), ...
        sprintf(['容量 >= %g 一律取表中最后一档（%g）的单价 %.4g %s（不插值、不外推）；' ...
        '本段无上界，故「该档对应投资额」不适用'], xt(n - 1), xt(n), yt(n), info.priceUnit)}, NC);
    C(end + 1, :) = gopt_rowpad({it(k).name, '本次', '本次容量', info.p, info.priceUnit, ...
        it(k).qty, it(k).inv / 1e4, '= 容量 x 单价（与【甲】块一致）', ''}, NC);
end
end

%% ------------------------------------------------------- 厂内自发电成本
function g = gopt_gen_cost(cap, cfg, R)
%GOPT_GEN_COST  厂内自发电的成本口径（★ 唯一实现，四处共用）
%
%  为什么单独抽一个函数：自发电的成本要被四处用到——内层目标里的燃料费项、外层适应度
%  里的年化投资、Excel / 命令行报表里的度电成本、敏感性图里的成本构成。若各处各算一遍，
%  必然随时间漂移（本仓库最忌讳的「口径漂移」）。所以这里只定义一次。
%
%  —— 口径（与 cfg_greenopt.m 第 2 节、设计文件 §1 的 C3~C6 完全一致）——
%    投资侧（进「年化投资成本」）：
%       投资额      inv.gen   = C_gen(kW) x 单位投资单价(元/kW)
%                                   单位投资单价来自 gopt_unit_price：自发电没有分档表，
%                                   因此恒等于常数单价 cfg.cost.gen.capex（本轮改造后仍如此）
%       年化费用率  a.gen     = CRF(i, life) + opexRate
%       年化投资    annual    = inv.gen x a.gen                    [元/年]
%    运行侧（进「年化运行成本」，由内层 MILP 支付）：
%       燃料+变动运维 = 实发电量(MWh) x varCost(元/kWh) x 1000      [元/年]
%       ⚠ 只对**实际发出的电量**计费：弃掉的自发电不烧燃料、不付费。
%         这条正是「先弃贵的」机制的经济学来源，内层目标里也按同一口径写。
%    度电成本（仅用于报表展示，不参与寻优）：
%       lcoe = (annual + varCost) / 实发电量 / 1000                 [元/kWh]
%       ⚠ 分母用**实发电量**而不是「标幺曲线给出的可用电量」：被弃掉的那部分没有
%         产生任何价值，不该由它来摊薄成本。因此弃电越多，这个数值越高，
%         它反映的是「这套容量在本次调度下的真实度电成本」。
%
%  输入  cap 容量向量（第 5 个元素 = 自发电容量 MW；不足 5 维时按 0 处理）
%        cfg 全局配置（读 cfg.cost.gen.* / cfg.cost.discountRate / cfg.cost.mode）
%        R   内层调度结果（可选；不传则实发电量按 0 计，度电成本返回 NaN）
%  输出  g   结构体：.capex .life .opexRate .varCost .price .u .inv .a .annual
%                  .varCostYuan .E_gen .E_avail .lcoe .lcoeCapex .lcoeVar .hasR
%
%  ★ 分档单价改造（本轮）：投资侧不再直接取 cfg.cost.gen.capex，而是走
%    gopt_unit_price。自发电正常情况下没有分档表（cfg.cost.gen.tier 不存在），
%    于是它自动退化为常数单价 —— 行为与改动前逐位相同（用户要求自发电恒为
%    400 元/kW + 0.1 元/kWh）。若日后补一张 cfg.cost.gen.tier 表，这里不用改，
%    自动就会走分档。g.u 里带着口径/命中档/区间，供报表打印。

cap = cap(:);
C_gen = 0;
if numel(cap) >= 5, C_gen = max(cap(5), 0); end

% ---- 单位投资单价：走 gopt_unit_price 唯一实现（无分档表时自动退化为常数单价）----
[g.price, g.u] = gopt_unit_price(C_gen, gopt_cost_mode(cfg), cfg.cost.gen.capex, ...
                                 gopt_pget(cfg.cost.gen, 'tier', []), 'MW', '元/kW');

g.capex    = cfg.cost.gen.capex;         % 元/kW（常数单价；flat 口径值与对照值）
g.life     = cfg.cost.gen.life;          % 年
g.opexRate = cfg.cost.gen.opexRate;      % -
g.varCost  = cfg.cost.gen.varCost;       % 元/kWh
g.C_gen    = C_gen;

if C_gen <= 0
    % 容量为 0：投资与运行费用都是 0，度电成本不适用（NaN 而非 Inf，见 gopt_lcoe 的说明）
    g.inv = 0;  g.a = gopt_crf(cfg.cost.discountRate, g.life) + g.opexRate;
    g.annual = 0;  g.varCostYuan = 0;
    g.E_gen = 0;   g.E_avail = 0;
    g.lcoe = NaN;  g.lcoeCapex = NaN;  g.lcoeVar = g.varCost;
    g.hasR = false;
    return;
end

g.inv    = C_gen * 1000 * g.price;                                    % 元
g.a      = gopt_crf(cfg.cost.discountRate, g.life) + g.opexRate;      % 1/年
g.annual = g.inv * g.a;                                               % 元/年

g.hasR = (nargin >= 3) && ~isempty(R) && isfield(R, 'energyGen');
if g.hasR
    g.E_gen   = R.energyGen;                                          % MWh/年（实发）
    g.E_avail = R.energyGenAvail;                                     % MWh/年（可用）
    g.varCostYuan = g.E_gen * g.varCost * 1000;                       % 元/年
    g.lcoe      = (g.annual + g.varCostYuan) / max(g.E_gen, eps) / 1000;   % 元/kWh
    g.lcoeCapex = g.annual / max(g.E_gen, eps) / 1000;
    g.lcoeVar   = g.varCost;
    g.utilRate  = g.E_gen / max(g.E_avail, eps);                      % 自发电利用率
else
    g.E_gen = NaN;  g.E_avail = NaN;  g.varCostYuan = NaN;
    g.lcoe = NaN;   g.lcoeCapex = NaN;  g.lcoeVar = g.varCost;
    g.utilRate = NaN;
end
end

%% ------------------------------------------------------------ 年化投资成本
function [cTotal, d] = gopt_annual_capex(cap, cfg, R)
%GOPT_ANNUAL_CAPEX  年化投资成本（含年运维），单位 元/年
%   cap = [C_pv ; C_wt ; P_ess ; E_ess ; C_gen]  MW / MW / MW / MWh / MW
%         第 5 维（厂内自发电容量）缺失时按 0 处理，保证旧调用不报错。
%   年化费用率 = 资金回收系数 CRF + 运维费率
%
%   ★ 分档单价改造（本轮）：初始投资额不再一律用「容量 x 常数单价」，而是
%        投资额 = 容量 x 单位投资单价 p(容量)
%     其中 p 由 gopt_unit_price 给出（cfg.cost.mode = 'tiered' 时分档表分段线性插值，
%     'flat' 时为常数）。四项资产各自的 p、命中档、区间放在返回的 d.u 里，
%     供命令行与 Excel 直接打印，避免报表再解析字符串或另算一套。
%     自发电（第 5 维）走 gopt_gen_cost，其内部同样调用 gopt_unit_price（无分档表
%     => 常数单价）。
%
%   ★ 第三个入参 R 是内层调度结果，用于「储能寿命与循环寿命挂钩」。
%     为什么必须传：同一个 cap 的调度是唯一的，生命周期由这次调度反算；
%     漏传就会静默退回日历寿命，于是同一个容量在 PSO 里和报表里算成两套成本——
%     这正是本项目最忌讳的「口径漂移」。所以这里加了护栏：只要耦合开着却没拿到 R，
%     直接报错，绝不猜。
%     真要只看资产规模（完全不涉及寿命口径），把 cfg.ess.lifeMode 设为 'calendar'。
if nargin < 3, R = []; end
if isempty(R) && ~strcmp(gopt_life_mode(cfg), 'calendar')
    error('gopt_annual_capex:missingR', ...
        ['储能循环寿命耦合已开启（cfg.ess.lifeMode = ''%s''），但调用 gopt_annual_capex 时' ...
         '没有传入内层调度结果 R，无法反算年等效循环次数。' ...
         '请把 R 一并传入；或把 cfg.ess.lifeMode 改为 ''calendar'' 表示只按日历寿命计。'], ...
        gopt_life_mode(cfg));
end
i    = cfg.cost.discountRate;
mode = gopt_cost_mode(cfg);        % 'flat' | 'tiered'（分档单价口径的总开关）

% ---- 单位投资单价：四项资产各查一次（唯一实现 gopt_unit_price）----
% 储能功率与容量是「两张独立分档表」，这里也分两次查（tierP 按 MW 查、tierE 按 MWh 查）。
[pr.pv,   u.pv]   = gopt_unit_price(cap(1), mode, cfg.cost.pv.capex,   ...
                                    gopt_pget(cfg.cost.pv,  'tier',  []), 'MW',  '元/kW');
[pr.wt,   u.wt]   = gopt_unit_price(cap(2), mode, cfg.cost.wt.capex,   ...
                                    gopt_pget(cfg.cost.wt,  'tier',  []), 'MW',  '元/kW');
[pr.essP, u.essP] = gopt_unit_price(cap(3), mode, cfg.cost.ess.capexP, ...
                                    gopt_pget(cfg.cost.ess, 'tierP', []), 'MW',  '元/kW');
[pr.essE, u.essE] = gopt_unit_price(cap(4), mode, cfg.cost.ess.capexE, ...
                                    gopt_pget(cfg.cost.ess, 'tierE', []), 'MWh', '元/kWh');

inv.pv   = cap(1) * 1000 * pr.pv;                  % MW -> kW
inv.wt   = cap(2) * 1000 * pr.wt;
inv.essP = cap(3) * 1000 * pr.essP;
inv.essE = cap(4) * 1000 * pr.essE;
inv.ess  = inv.essP + inv.essE;

% ---- 储能寿命：由本次调度反算（循环寿命耦合），未开启时即为日历寿命 ----
L = gopt_ess_life(cap, cfg, R);
lifeEss = L.lifeUsed;

a.pv  = gopt_crf(i, cfg.cost.pv.life)  + cfg.cost.pv.opexRate;
a.wt  = gopt_crf(i, cfg.cost.wt.life)  + cfg.cost.wt.opexRate;
a.ess = gopt_crf(i, lifeEss)           + cfg.cost.ess.opexRate;

% ---- 厂内自发电（★ 本轮新增）：投资口径与上面三者完全一致 ----
% 走 gopt_gen_cost 这个唯一实现，不在这里另算一遍。
G = gopt_gen_cost(cap, cfg, R);
inv.gen = G.inv;
a.gen   = G.a;
pr.gen  = G.price;      % 自发电的单价也并进 pr / u，使 d.price 与 d.u 成为「五项资产」
u.gen   = G.u;          % 的完整口径表（自发电没有分档表，因此恒等于常数单价
                        % cfg.cost.gen.capex；两者指向同一个 info，不会漂移）

d.crfPv  = gopt_crf(i, cfg.cost.pv.life);
d.crfWt  = gopt_crf(i, cfg.cost.wt.life);
d.crfEss = gopt_crf(i, lifeEss);
d.crfGen = gopt_crf(i, cfg.cost.gen.life);
d.inv    = inv;
% ---- ★ 分档单价改造新增的三个字段（供命令行 / Excel / 自检直接读取）----
d.u        = u;        % 四项资产的单价明细：口径 / 命中档 / 区间 / 两端单价 / 实际单价
d.price    = pr;       % 四项资产本次采用的单位投资单价（元/kW 或 元/kWh）
d.costMode = mode;     % 本次生效的成本计价口径（'flat' | 'tiered'）
d.pv     = inv.pv  * a.pv;
d.wt     = inv.wt  * a.wt;
d.ess    = inv.ess * a.ess;
d.gen    = inv.gen * a.gen;
d.genD   = G;              % 自发电明细（投资/运行/度电成本/利用率）
% 一次投资额合计（未年化）：Σ 容量 x 单位投资单价。单独给一个字段是因为「分档单价」
% 下这个数不再是「年化投资 / 年化费用率」能简单反推出来的（各资产费用率不同）。
d.totalInv = inv.pv + inv.wt + inv.ess + inv.gen;
d.total  = d.pv + d.wt + d.ess + d.gen;
d.lifeEss = lifeEss;      % 供日志与 Excel 使用的储能实际寿命 [年]
d.life    = L;            % 寿命明细（是否开启耦合、年等效循环次数、受限原因……）
cTotal   = d.total;
end

%% --------------------------------------------------- 储能寿命（循环寿命耦合）
function mode = gopt_life_mode(cfg)
%GOPT_LIFE_MODE  读取储能寿命口径 cfg.ess.lifeMode（缺字段时按 'cycle_min' 处理）
%   'cycle_min' => 寿命 = min(日历寿命, 循环折算寿命)；'calendar' => 只用日历寿命。
%   单独抽成一个函数，是因为「寿命口径」被两处读：gopt_ess_life 用它算寿命，
%   gopt_annual_capex 用它判断「没传 R 会不会改变口径」并据此报错。
%   口径只定义一次，两处永远不会读岔。
mode = 'cycle_min';
if nargin >= 1 && isstruct(cfg) && isfield(cfg, 'ess') ...
        && isfield(cfg.ess, 'lifeMode') && ~isempty(cfg.ess.lifeMode)
    mode = lower(cfg.ess.lifeMode);
end
end

function L = gopt_ess_life(cap, cfg, R)
%GOPT_ESS_LIFE  储能实际寿命 = min(日历寿命, 循环寿命 / 年等效循环次数)
%
%  为什么这么算：一次充放循环就是消耗一次寿命。年放电量除以额定容量就是
%  「等效满循环次数/年」；6000 次的额定循环寿命摊到每年 N 次，N 年就耗完。
%  再与日历寿命（受日历老化、材料老化限制，与用得多不多无关）取小，
%  得到真正决定「多少年摊一次投资」的那个年数。
%
%  输入  cap 4 维容量 [C_pv; C_wt; P_ess; E_ess]
%        cfg 全局配置（读 cfg.ess.cycleLife / lifeMode / cycleBasis / lifeFloor）
%        R   内层调度结果（可选；缺省、为空或未开耦合 => 退化为纯日历寿命）
%  输出  L   明细结构体，字段：
%           .enable    是否真的启用了循环寿命耦合
%           .basis     循环次数口径（'discharge' / 'throughput' / 'charge'）
%           .cycles    年等效循环次数 [次/年]（NaN 表示未启用或无从计算）
%           .cycleLife 额定循环寿命 [次]
%           .lifeCal   日历寿命 [年]
%           .lifeCyc   循环折算寿命 [年]（Inf 表示全年不循环，寿命不受循环限制）
%           .lifeUsed  最终采用的寿命 [年]
%           .limited   被谁限制：'cycle' | 'calendar'
%           .clamped   是否触发了 lifeFloor 下限护栏
L.enable    = false;
L.basis     = 'calendar';
L.cycles    = NaN;
L.cycleLife = NaN;
L.lifeCal   = cfg.cost.ess.life;
L.lifeCyc   = NaN;
L.lifeUsed  = cfg.cost.ess.life;
L.limited   = 'calendar';
L.clamped   = false;

% ---- 1. 口径判定：未开启 / 拿不到调度结果 / 没有储能容量，一律退回日历寿命 ----
mode = gopt_life_mode(cfg);
L.mode = mode;
if strcmp(mode, 'calendar'), return; end
if nargin < 3 || isempty(R) || ~isfield(R, 'energyDis'), return; end
E_ess = cap(4);
if ~(E_ess > 0), return; end      % 储能容量为 0：循环寿命无从谈起，且 capex ESS 本身为 0

% ---- 2. 年等效循环次数 ----
basis = 'discharge';
if isfield(cfg.ess, 'cycleBasis') && ~isempty(cfg.ess.cycleBasis)
    basis = lower(cfg.ess.cycleBasis);
end
switch basis
    case 'throughput'
        nE = (R.energyCh + R.energyDis) / (2 * E_ess);
    case 'charge'
        nE = R.energyCh / E_ess;
    otherwise                                  % 'discharge'（默认）
        nE = R.energyDis / E_ess;
end

L.enable    = true;
L.basis     = basis;
L.cycles    = nE;
L.cycleLife = cfg.ess.cycleLife;

% ---- 3. 循环折算寿命 ----
% 年循环次数为 0（配了储能但全年一次都没走）时折算寿命为无穷，
% 意思是「循环不成瓶颈」，此后自然由日历寿命兜住。
if nE > 0
    L.lifeCyc = cfg.ess.cycleLife / nE;
else
    L.lifeCyc = Inf;
end

% ---- 4. 与日历寿命合成 ----
if strcmp(mode, 'cycle')
    L.lifeUsed = L.lifeCyc;  L.limited = 'cycle';
elseif L.lifeCyc <= L.lifeCal
    L.lifeUsed = L.lifeCyc;  L.limited = 'cycle';
else
    L.lifeUsed = L.lifeCal;  L.limited = 'calendar';
end

% ---- 5. 下限护栏 ----
% 为什么必须有：CRF(i,N) = i(1+i)^N / ((1+i)^N - 1)；N -> 0 时分子 -> i、分母 -> 0，
% CRF 发散。储能配得极小又深度循环就会撞上这种情况，数值上必须兜住。
fl = 1;
if isfield(cfg.ess, 'lifeFloor') && ~isempty(cfg.ess.lifeFloor), fl = cfg.ess.lifeFloor; end
fl = max(fl, 1e-3);
if ~isfinite(L.lifeUsed)
    L.lifeUsed = L.lifeCal;  L.limited = 'calendar';    % 兜底，正常到不了
elseif L.lifeUsed < fl
    L.lifeUsed = fl;
    L.clamped  = true;
end
end

%% ------------------------------------------------------- 绿电消纳指标
function m = gopt_metrics(R, cap, sc, cfg)
%GOPT_METRICS  统一计算「绿电消纳口径」的指标（命令行输出与敏感性分析共用同一实现）
%
%   为什么单独抽一个函数：命令行汇总、敏感性分析图的 (c)(d)(e) 三张子图都要用到
%   「自用率 / 上网率 / 弃电率 / 未自用率」。若各处各算一遍，容易出现口径漂移
%   （例如一处用 R.energyRen 含自发电、另一处不含），因此这里只定义一次。
%
%   —— 关键公式（与命令行打印的文字完全一致；★ 为本轮改动）——
%     ★ 绿电发电量 E_ren = 光伏容量 x Σ光伏标幺 + 风电容量 x Σ风电标幺
%                          （Σ 为年化加权求和：Σ_t w(t) * Δt * 标幺出力）
%       —— 自发电**不再计入绿电**（cfg.met.genInGreen = false，用户口径 C10）；
%          需要与历史结果对照时把该开关设为 true 即退回「含自发电」的旧口径。
%     ★ 上网电量的分源归属（cfg.met.genLcoeConv）
%          'gen'（默认）绿电上网 = min(上网电量, 绿电扣弃电发电量)；自发电只算自用，
%                       超出部分单列为「自发电上网（口径外溢）」而不并入绿电；
%          'share'      按各源扣弃电后的发电量占比分摊。
%     自用率   = （E_ren - 绿电上网 - 绿电弃电） / E_ren    （绿电被本地负荷吃掉的比例）
%     上网率   =   绿电上网 / E_ren                        （卖到电网的比例）
%     弃电率   =   绿电弃电 / E_ren                        （白白扔掉的比例）
%     未自用率 =   上网率 + 弃电率 = 1 - 自用率              （没有留在本地消纳的比例）
%   三者恒有 自用率 + 上网率 + 弃电率 = 100% —— 这是恒等式而非巧合：
%   本函数把「自用」定义为 E_ren 减去归属绿电的上网、再减去绿电弃电之后的余量，故必然配平。
%   ⚠ 口径含义：「自用」里其实包含了绿电经储能搬移产生的循环损耗
%     （即 R.energyCh - R.energyDis 量级的部分），储能损耗没有单列，而是被计入「自用」。
%     若需单独看这部分损耗，直接取 R.energyCh - R.energyDis——它由 SOC 动态按周期加总得到
%     （见 gopt_milp 约束 (2)：σ·ΣE_soc = η_ch·E_ch - E_dis / η_dis）。
%   ★ 自发电相关（单列）：
%     自发电可用电量 = 自发电容量 x Σ自发电标幺；实发 = 可用 - 弃自发电
%     自发电供负荷   = min(自发电实发, 负荷电量 - 购电量)     （自发电优先自用）
%     绿电供负荷     = （负荷电量 - 购电量） - 自发电供负荷     （两者相加恒等于「负荷-购电」）
%
%   输入  R   内层调度结果（需 .energySell/.energyCurt/.energyGen 等）
%         cap 容量 5 维 [C_pv; C_wt; P_ess; E_ess; C_gen]（MW/MW/MW/MWh/MW）
%         sc  调度场景（需 .w/.PV/.WT/.Gen/.dt）
%         cfg 全局配置
%   输出  m   指标结构体（电量 MWh/年，比率为百分数 %，成本 万元/年）

cap = cap(:);
% 防御性补齐：外部调用（敏感性扫描的匿名函数、旧脚本）可能只给 4 维，
% gopt_milp 会自己补 0，但本函数直接索引 cap(5)，不补就会报「索引超过数组元素的数量」。
% 口径与 gopt_milp 完全一致：缺第 5 维 = 自发电容量 0 = 不建自发电。
if numel(cap) == 4, cap(5, 1) = 0; end
w   = sc.w(:) * sc.dt;                        % 每时段代表的年化小时数 [h]

% 注意：必须写成 w .* (cap(k) * 标幺) 的两步形式——
% 若写成 w .* cap(k) * sc.PV(:)，MATLAB 会把它解析成 (w.*cap(k)) * sc.PV(:)，
% 即两个 N×1 向量做矩阵乘法，直接报「维度不正确」。
m.E_pv   = sum(w .* (cap(1) * sc.PV(:)));     % 光伏可用发电量
m.E_wt   = sum(w .* (cap(2) * sc.WT(:)));     % 风电可用发电量

% ---- 厂内自发电（★ 本轮新增，单列口径）----
% 为什么单列：用户明确「自发电不计入绿电」。若自发电其实是自备火电/燃气机组，
% 把它算进绿电会同时污染三个指标——绿电占比（虚高）、消纳比例（虚高）、
% 两个 LCOE 的分母（虚大 ⇒ 度电成本虚低）。所以默认单列。
% 需要与历史结果对照时，把 cfg.met.genInGreen 改成 true 即退回旧口径。
genInGreen = false;
if isfield(cfg, 'met') && isfield(cfg.met, 'genInGreen') && ~isempty(cfg.met.genInGreen)
    genInGreen = logical(cfg.met.genInGreen);
end
m.genInGreen = genInGreen;
m.E_genAvail = sum(w .* (cap(5) * sc.Gen(:)));  % 自发电可用电量（标幺 x 容量）
m.E_gen      = R.energyGen;                     % 自发电实发电量（= 可用 - 弃自发电）
m.E_genCurt  = R.energyCurtGen;                 % 弃自发电电量
m.E_curtPV   = R.energyCurtPV;
m.E_curtWT   = R.energyCurtWT;

if genInGreen
    m.E_ren  = m.E_pv + m.E_wt + m.E_genAvail;   % 旧口径：绿电 = 光伏 + 风电 + 自发电
    m.E_curt = R.energyCurt;                     % 弃电也含弃自发电
else
    m.E_ren  = m.E_pv + m.E_wt;                  % 新口径（默认）：绿电 = 光伏 + 风电
    m.E_curt = R.energyCurtPV + R.energyCurtWT;  % 弃电只算弃风弃光
end
m.E_sell = R.energySell;                      % 上网电量（聚合量，分源见下）

% ---- 上网电量的分源归属（★ 本轮新增）----
% 口径（cfg.met.genLcoeConv）：
%   'gen'（默认）上网电量**全部归绿电**，自发电只算自用；
%                超出绿电可上网余量的那部分单列为「自发电上网（口径外溢）」，
%                报表里如实给出、不隐藏（数值上通常为 0：售电价 0.10~0.20 元/kWh
%                不高于自发电边际成本 0.20 元/kWh，模型基本不会把自发电卖到电网）。
%   'share'      按各源扣弃电后的发电量占比分摊。
sellConv = 'gen';
if isfield(cfg, 'met') && isfield(cfg.met, 'genLcoeConv') && ~isempty(cfg.met.genLcoeConv)
    sellConv = lower(char(cfg.met.genLcoeConv));
end
m.sellConv = sellConv;
greenNet = max(m.E_ren - m.E_curt, 0);          % 绿电扣弃电后可上网的量
genNet   = max(m.E_gen - m.E_genCurt, 0);       % 自发电扣弃电后可上网的量
if strcmp(sellConv, 'share') && (greenNet + genNet) > 0
    m.E_sellGreen = m.E_sell * greenNet / (greenNet + genNet);
else
    % 'gen'（默认）：上网全部归绿电，但不超过绿电实际可上网的量
    m.E_sellGreen = min(m.E_sell, greenNet);
end
m.E_sellGen   = max(m.E_sell - m.E_sellGreen, 0);

% 「自用」= 绿电发电量减去归属绿电的上网、再减去绿电弃电后的余量；其中含储能循环损耗
m.E_self = max(m.E_ren - m.E_sellGreen - m.E_curt, 0);

den = max(m.E_ren, eps);                      % 防止 0 装机时除零
m.selfRate   = m.E_self / den * 100;          % 自用率   [%]
m.sellRate   = m.E_sellGreen / den * 100;     % 上网率   [%]
m.curtRate   = m.E_curt / den * 100;          % 弃电率   [%]
m.unusedRate = m.sellRate + m.curtRate;       % 未自用率 [%] = 上网率 + 弃电率

% ---- 自发电的消纳与占比（★ 本轮新增）----
% 自发电「只算自用」：先满足本地负荷，因此
%   自发电供负荷 = min(自发电实发, 负荷电量 - 购电量)
%   绿电供负荷   = (负荷电量 - 购电量) - 自发电供负荷
% 两者相加恒等于「负荷 - 购电」，即真正送到用户负荷的非网购电量，恒等式不会破。
m.E_load = sum(w .* sc.load(:));
m.E_buy  = R.energyBuy;
m.E_nonGrid = max(m.E_load - m.E_buy, 0);
m.E_genLoad = min(m.E_gen, m.E_nonGrid);
m.E_renLoad = max(m.E_nonGrid - m.E_genLoad, 0);
m.genRate   = m.E_genLoad / max(m.E_load, eps) * 100;    % 自发电占负荷电量比例 [%]
m.genUseRate= m.E_gen / max(m.E_genAvail, eps) * 100;    % 自发电利用率 [%]

% ---- 成本侧（万元/年），供敏感性图的成本构成子图使用 ----
% 传 R：储能寿命随调度而变，敏感性扫描时每个扫描点的 capex 才能与该点自己的调度自洽。
[~, capD]   = gopt_annual_capex(cap, cfg, R);
m.capexPV   = capD.pv  / 1e4;
m.capexWT   = capD.wt  / 1e4;
m.capexESS  = capD.ess / 1e4;
m.capexGen  = capD.gen / 1e4;
m.capexTot  = capD.total / 1e4;
m.costOp    = R.cost / 1e4;                   % 年化运行成本（购电 - 售电 + 自发电燃料）
m.costGenVar= R.costGenVar / 1e4;             % 其中自发电燃料/变动运维
m.costTotal = m.capexTot + m.costOp;          % 年化总成本
% 自发电度电成本（元/kWh）：走 gopt_gen_cost 的唯一实现，不在这里另算一遍
m.genD    = capD.genD;
m.genLcoe = capD.genD.lcoe;
end

%% ------------------------------------------- 专业化指标（事后核算，不参与寻优）
function P = gopt_metrics_pro(res, ds, sc, cfg)
%GOPT_METRICS_PRO  专业化指标：储能损耗 / 绿电占比 / 消纳比例 / 成本节省率 / 两个 LCOE
%
%  为什么单独抽一个函数、又为什么要复用 gopt_metrics：本仓库的约定是「口径只定义一次」。
%  凡是与绿电消纳有关的量（绿电发电量、自用/上网/弃电、各自比率）全部直接取
%  gopt_metrics 的返回值 m，绝不另算一遍；本函数只补上它没覆盖的那几项：
%    ① 储能年损耗电量（总量 + 拆成「充放转换损耗」与「自放电损耗」）
%    ② 用户绿电占用电量比例   ③ 新能源发电量消纳比例
%    ④ 用电成本综合节省率     ⑤ LCOE（发电口径 / 消纳口径）
%
%  —— 口径与公式（与命令行打印、Excel「专业指标」表共用 gopt_pro_formula_lines 的同一份文本）——
%  ① 储能年损耗电量 = 年充电量 - 年放电量（充进去、放出来，差额就是损耗）
%     周期闭合时这个差额可以精确拆成两项（是恒等式，不是近似）：
%         自放电损耗   = etaCh x 年充电量 - 年放电量 / etaDis
%         充放转换损耗 = 总损耗 - 自放电损耗
%     推导：SOC 平衡按周期加总时 Σ_t w(t)[E(t) - E(t-1)] = 0，代入 SOC 动态即得
%           sigma x Σ_t w(t)E(t-1) = etaCh x E_ch - E_dis / etaDis。
%  ② 用户绿电占用电量比例 = （负荷电量 - 购电量）/ 负荷电量
%     分子就是「真正送到用户负荷的绿电量」。由功率平衡恒等式它等于
%     绿电发电量 - 上网 - 弃电 - 储能循环损耗，即已自动扣掉储能损耗，
%     不会把「在电池里磨掉的电」算成用户用掉的绿电。
%  ③ 新能源发电量消纳比例 = （绿电发电量 - 弃电量）/ 绿电发电量 = 100 - 弃电率
%     上网与自用都算消纳（政策口径）；数值与现有「可再生能源利用率」一致，此处另列一名。
%  ④ 用电成本综合节省率 = （基准购电成本 - 年化总成本）/ 基准购电成本
%     基准 = Σ_t w(t) x 购电价(t) x 负荷(t) x 1000 x Δt，即「不建任何绿电、
%     负荷全靠电网买电」的年电费，逐时购电价加权，不含任何投资；
%     分子是年化总成本（投资 + 运行净成本），故称「综合」。
%  ⑤ LCOE（发电口径，不含税）= 分子 /（分母 x 1000）  [元/kWh]
%       默认 分子 = 光伏+风电+储能 的年化投资与运维；分母 = 扣掉弃电后的实际发电量
%     LCOE（消纳口径，不含税）= 分子 /（分母 x 1000）  [元/kWh]
%       默认 分子 = 年化总成本；分母 = 绿电供负荷电量 = 负荷电量 - 购电量
%     两个口径的分子/分母都可分别用 cfg.met.lcoe* 切换（见 cfg_greenopt.m 第 3b 节）。
%
%  输入  res  最优解结构（需 .cap / .R / .fit；可选 .Rfy / .fitFY）
%        ds   数据集（全年口径的基准购电成本与发电量都在它上面算）
%        sc   调度场景（典型日口径时用）
%        cfg  全局配置
%  输出  P    指标结构体（含 .formulaLines，供命令行与 Excel 共用）

cap = res.cap(:);
P.enable = true;

%% ---- 1. 选成本口径：成本类指标用「全年 8760 h 核准」还是「典型日模型」 ----
basis = 'year_first';
if isfield(cfg, 'met') && isfield(cfg.met, 'costBasis') && ~isempty(cfg.met.costBasis)
    basis = lower(cfg.met.costBasis);
end
haveYear = isfield(res, 'Rfy') && ~isempty(res.Rfy) && ...
           isfield(res, 'fitFY') && isfinite(res.fitFY) && res.fitFY > 0;
useYear  = strcmp(basis, 'year_first') && haveYear;

if useYear
    Rref    = res.Rfy;
    costRef = res.fitFY;
    scRef   = gopt_scen_from_ds(ds, cfg);
    P.refTag   = '全年 8760 h 核准口径';
    P.refShort = '全年 8760 h 核准口径';
else
    Rref    = res.R;
    costRef = res.fit;
    scRef   = sc;
    % 为什么还要再看 cfg.time.mode：full_year 模式下主线模型本身就是全年时序，
    % 不需要（也不会）另做一次「典型日 -> 全年」核准，成本口径其实仍是全年。
    % 若在这里照搬「未做核准、已退回」的说法，会让人误以为用的是压缩时域口径。
    if strcmpi(cfg.time.mode, 'full_year')
        P.refTag   = '全年 8760 h 口径（主线模型本身即全年时序，无需再用核准模型复核）';
        P.refShort = '全年 8760 h 口径';
    elseif strcmp(basis, 'year_first')
        P.refTag   = '典型日模型口径（成本口径设为 year_first，但本次未做全年核准，已退回）';
        P.refShort = '典型日口径（未核准）';
    else
        P.refTag   = '典型日模型口径（cfg.met.costBasis = typical_days）';
        P.refShort = '典型日口径';
    end
end
P.costBasis = basis;
P.usedYear  = useYear;

%% ---- 2. 共用口径的量：一律走 gopt_metrics ----
% gopt_metrics 内部会用 Rref 反算储能年化投资，因此它的成本字段与本函数口径一致。
m = gopt_metrics(Rref, cap, scRef, cfg);
P.m = m;
[~, capD] = gopt_annual_capex(cap, cfg, Rref);
P.capD = capD;

E_load = Rref.energyLoad;          % 用户年用电量
E_buy  = Rref.energyBuy;           % 年购电量
P.E_load = E_load;  P.E_buy = E_buy;

%% ---- 3. 储能年损耗电量（万kWh）与拆分 ----
% MWh -> 万kWh 的换算是 /10（1 MWh = 0.1 万kWh），不是 /1e4。
MWH2WAN = 1 / 10;
lossTot  = Rref.energyCh - Rref.energyDis;
lossSelf = cfg.ess.etaCh * Rref.energyCh - Rref.energyDis / cfg.ess.etaDis;
lossSelf = max(min(lossSelf, max(lossTot, 0)), 0);   % 夹到 [0, 总损耗]，防数值抖动把拆分弄反
lossConv = max(lossTot - lossSelf, 0);

P.lossTotMWh  = lossTot;   P.lossTot  = lossTot  * MWH2WAN;
P.lossConvMWh = lossConv;  P.lossConv = lossConv * MWH2WAN;
P.lossSelfMWh = lossSelf;  P.lossSelf = lossSelf * MWH2WAN;
P.lossRate    = lossTot / max(Rref.energyCh, eps) * 100;   % 损电占充电量的比例 [%]
P.energyCh    = Rref.energyCh;
P.energyDis   = Rref.energyDis;

%% ---- 4. 两个比例 + 自发电独立块（★ 本轮改动）----
% 绿电供负荷电量：由功率平衡恒等式 = 负荷 - 购电，再扣掉「自发电供负荷」。
% 为什么必须再扣：自发电已按用户口径单独核算（不计入绿电），若这里仍用
% 「负荷 - 购电」，就等于把自发电的贡献偷偷算进绿电占比，指标会虚高。
E_greenLoad = m.E_renLoad;                 % ★ 绿电供负荷（= 负荷 - 购电 - 自发电供负荷）
P.E_greenLoad = E_greenLoad;
P.greenRate   = E_greenLoad / max(E_load, eps) * 100;      % 用户绿电占用电量比例 [%]

% 消纳比例直接由 gopt_metrics 的弃电率换算，保证与既有口径完全一致
% ⚠ 零装机保护（本轮新增）：若光伏与风电都没装机（E_ren = 0），「消纳比例」在数学上
% 是 0/0，任何数值都没有意义。这里返回 NaN 并在报表里写明「不适用」，**绝不能给 100%**
% —— 那会被读成「绿电消纳得很好」，而事实是「根本没建绿电」，结论完全相反。
P.noRen = (m.E_ren <= 1e-9);
if P.noRen
    P.absorbRate = NaN;
else
    P.absorbRate = 100 - m.curtRate;
end

% ---- 自发电独立块（★ 本轮新增）----
% 这一块的所有数字都来自 gopt_gen_cost（唯一实现）与 gopt_metrics（同一口径），
% 本函数只做搬运，不重算，避免出现「报表一套、图一套」。
gD = capD.genD;
P.genCap     = cap(5);                 % 自发电装机容量 [MW]
P.genCapex   = gD.capex;               % 单位投资 [元/kW]
P.genLife    = gD.life;                % 寿命 [年]
P.genOpex    = gD.opexRate;            % 年运维费率 [-]
P.genA       = gD.a;                   % 年化费用率 = CRF(折现率, 寿命) + 运维费率
P.genVarCost = gD.varCost;             % 运行成本 [元/kWh]
P.genInvAnn  = gD.annual;              % 年化投资 [元/年]
P.genVarAnn  = gD.varCostYuan;         % 年运行成本（燃料+变动运维）[元/年]
P.genE       = m.E_gen;                % 实发电量 [MWh/年]
P.genEAvail  = m.E_genAvail;           % 可用电量 [MWh/年]
P.genCurt    = m.E_genCurt;            % 弃自发电量 [MWh/年]
P.genUseRate = m.genUseRate;           % 自发电利用率 [%]
P.genLoadE   = m.E_genLoad;            % 自发电供负荷电量 [MWh/年]
P.genRate    = m.genRate;              % 自发电占负荷电量比例 [%]
P.genSellE   = m.E_sellGen;            % 自发电上网电量（口径外溢项，通常为 0）[MWh/年]
P.genLcoe    = gD.lcoe;                % 自发电度电成本 [元/kWh]（分母 = 实发电量）
P.genLcoeCap = gD.lcoeCapex;           %   其中 投资折算部分
P.genLcoeVar = gD.lcoeVar;             %   其中 运行部分

% ---- 参照电价：与自发电度电成本放在一起比价才看得懂 ----
% 光伏/风电的全成本度电成本同样按「年化投资 ÷ 扣弃电发电量」算，口径一致。
P.refLcoePV  = gopt_lcoe(capD.pv, max(m.E_pv - m.E_curtPV, 0));
P.refLcoeWT  = gopt_lcoe(capD.wt, max(m.E_wt - m.E_curtWT, 0));

%% ---- 5. 用电成本综合节省率 ----
% 基准：全部从电网买电的年电费。全年口径用 8760 h 逐时数据，典型日口径用场景权重。
if useYear
    base = sum(ds.buy(:) .* ds.load(:)) * 1000 * cfg.time.dt;
else
    base = sum(sc.w(:) .* sc.buy(:) .* sc.load(:)) * 1000 * sc.dt;
end
P.costBase = base;
P.costRef  = costRef;
if base > 0
    P.saveRate = (base - costRef) / base * 100;
else
    P.saveRate = NaN;
end
% 两个参考电价：基准购电均价、用户实际综合度电成本（含投资，摊到年用电量）
P.basePrice = base    / max(E_load * 1000, eps);
P.avgPrice  = costRef / max(E_load * 1000, eps);

%% ---- 6. 两个 LCOE（元/kWh，不含税）----
% ★ 分子口径（本轮改动）：因为自发电已经单列成块，绿电 LCOE 的分子**不含**自发电投资
%   （含就要重复计一遍）。同时按 cfg.met.genLcoeRef 给一个「含自发电」的对照值，
%   方便与上一版（自发电还在绿电口径里）的结果直接对比。
assetNum   = capD.pv + capD.wt + capD.ess;                 % 绿电发电侧年化投资 + 运维
assetNumWG = capD.pv + capD.wt + capD.ess + capD.gen;      % 含自发电（对照用）
genVarAnn  = capD.genD.varCostYuan;                        % 自发电运行成本（计入「总成本」口径时已含）

% (a) 发电口径
modeN = 'asset';
if isfield(cfg.met, 'lcoeGenNum') && ~isempty(cfg.met.lcoeGenNum), modeN = lower(cfg.met.lcoeGenNum); end
if strcmp(modeN, 'total'), numGen = costRef; else, numGen = assetNum; end
modeD = 'net';
if isfield(cfg.met, 'lcoeGenDen') && ~isempty(cfg.met.lcoeGenDen), modeD = lower(cfg.met.lcoeGenDen); end
if strcmp(modeD, 'avail'), denGen = m.E_ren; else, denGen = max(m.E_ren - m.E_curt, 0); end
P.numGen = numGen;  P.denGen = denGen;
P.lcoeGen = gopt_lcoe(numGen, denGen);
% 对照：分子含自发电投资、分母含自发电扣弃电发电量（= 上一版的口径）
genNetE = max(m.E_gen - m.E_genCurt, 0);
P.lcoeGenWG = gopt_lcoe(assetNumWG, denGen + genNetE);

% (b) 消纳口径
modeN = 'total';
if isfield(cfg.met, 'lcoeConNum') && ~isempty(cfg.met.lcoeConNum), modeN = lower(cfg.met.lcoeConNum); end
if strcmp(modeN, 'asset'), numCon = assetNum; else, numCon = costRef; end
modeD = 'greenload';
if isfield(cfg.met, 'lcoeConDen') && ~isempty(cfg.met.lcoeConDen), modeD = lower(cfg.met.lcoeConDen); end
switch modeD
    case 'self',  denCon = m.E_self;
    case 'load',  denCon = E_load;
    otherwise,    denCon = E_greenLoad;      % 'greenload'（默认，= 绿电供负荷电量）
end
P.numCon = numCon;  P.denCon = denCon;
P.lcoeCon = gopt_lcoe(numCon, denCon);

% 记下四个口径选项的实际取值，供公式文本与 Excel 如实标注（不写死默认值）
P.lcoeGenNumMode = 'asset';
if isfield(cfg.met, 'lcoeGenNum') && ~isempty(cfg.met.lcoeGenNum), P.lcoeGenNumMode = lower(cfg.met.lcoeGenNum); end
P.lcoeGenDenMode = 'net';
if isfield(cfg.met, 'lcoeGenDen') && ~isempty(cfg.met.lcoeGenDen), P.lcoeGenDenMode = lower(cfg.met.lcoeGenDen); end
P.lcoeConNumMode = 'total';
if isfield(cfg.met, 'lcoeConNum') && ~isempty(cfg.met.lcoeConNum), P.lcoeConNumMode = lower(cfg.met.lcoeConNum); end
P.lcoeConDenMode = 'greenload';
if isfield(cfg.met, 'lcoeConDen') && ~isempty(cfg.met.lcoeConDen), P.lcoeConDenMode = lower(cfg.met.lcoeConDen); end

%% ---- 7. 储能循环寿命明细（与年化投资成本用的是同一份实现）----
P.essL = gopt_ess_life(cap, cfg, Rref);

%% ---- 8. 公式文本：命令行与 Excel 只生成一次、两处引用 ----
P.formulaLines = gopt_pro_formula_lines(P, cfg);
end

function v = gopt_lcoe(numYuan, denMWh)
%GOPT_LCOE  度电成本 = 年化费用(元/年) / 年电量(MWh) / 1000 => 元/kWh
%   分母为 0（例如完全没有新能源装机）时返回 NaN，而不是 Inf——
%   Inf 会污染后续求平均、画图与表格排序，NaN 才能被正确识别为「不适用」。
if denMWh > 0
    v = numYuan / (denMWh * 1000);
else
    v = NaN;
end
end

function scY = gopt_scen_from_ds(ds, cfg)
%GOPT_SCEN_FROM_DS  由数据集直接构造一个「全年 8760 h」轻量场景
%   为什么要它：全年核准（res.Rfy）对应的场景对象是在主流程里临时构造的局部变量，
%   没有随结果一起返回；而专业化指标需要「与 res.Rfy 同口径」的发电量（E_pv/E_wt），
%   所以这里按同样的规则重建一份——只填 gopt_metrics 用到的字段。
%   注意 scY.w 恒为 1：全年模式每个小时恰好代表 1 小时。
scY.mode = 'full_year';
scY.T    = ds.T;
scY.dt   = cfg.time.dt;
scY.w    = ones(ds.T, 1);
scY.PV   = ds.pvPu;
scY.WT   = ds.wtPu;
scY.Gen  = ds.gen;
scY.load = ds.load;
scY.buy  = ds.buy;
scY.sell = ds.sell;
end

function L = gopt_pro_formula_lines(P, cfg)
%GOPT_PRO_FORMULA_LINES  专业化指标的口径与公式说明（命令行日志与 Excel「专业指标」表共用）
%
%   为什么单独一个函数：同一段说明要同时出现在命令行日志和 Excel 里，
%   分散写两处必然随时间漂移，所以只生成一次、两处引用（与敏感性分析的
%   gopt_sens_formula_lines 是同一套做法）。
%
%   输入  P    gopt_metrics_pro 已算好的指标结构体（本函数只读不改）
%         cfg  全局配置
%   输出  L    N×2 cell：第一列短标签，第二列式子或说明。日志里拼成一行，
%               写入 Excel 时正好落在「项目 / 内容」两列上。

L = cell(0, 2);
L(end + 1, :) = {'成本口径', ['④⑤ 两项成本类指标采用：' P.refTag ...
    '；成本 = 年化投资成本 + 年化运行成本（购电成本 - 售电收益 + 自发电燃料/变动运维）']};
L(end + 1, :) = {'口径变更（本轮）', ...
    '自发电已单列：绿电发电量 = 光伏 + 风电（不再含自发电），故绿电占比 / 消纳比例 / 两个 LCOE 的数值与上一版不可直接对比'};
L(end + 1, :) = {'① 储能年损耗电量', ...
    'E_loss = 年充电量 - 年放电量（含充放转换损耗与自放电损耗）'};
L(end + 1, :) = {'', ...
    '拆分：自放电损耗 = etaCh x 年充电量 - 年放电量 / etaDis；充放转换损耗 = 总损耗 - 自放电损耗'};
L(end + 1, :) = {'', ...
    '依据：SOC 按周期闭合时 Σ_t w(t)[E(t) - E(t-1)] = 0，代入 SOC 动态即得上述恒等式'};
L(end + 1, :) = {'', sprintf('本算例：总损耗 %.2f 万kWh = 充放转换 %.2f + 自放电 %.2f；占年充电量 %.2f%%', ...
    P.lossTot, P.lossConv, P.lossSelf, P.lossRate)};
L(end + 1, :) = {'② 用户绿电占用电量比例', ...
    'R_green = 绿电供负荷电量 / 负荷电量；绿电供负荷 = （负荷电量 - 购电量）- 自发电供负荷'};
L(end + 1, :) = {'', ...
    '含义：分子 = 真正送到用户负荷的绿电量。由功率平衡恒等式它等于「绿电发电量 - 上网 - 弃电 - 储能循环损耗」，'};
L(end + 1, :) = {'', ...
    '即已自动扣除储能损耗；本轮再扣掉「自发电供负荷」——因为自发电已按用户口径不计入绿电'};
L(end + 1, :) = {'', sprintf(['本算例：负荷 %.0f MWh，购电 %.0f MWh -> 非网购 %.0f MWh；' ...
    '其中自发电供负荷 %.0f MWh -> 绿电供负荷 %.0f MWh，占比 %.2f%%'], ...
    P.E_load, P.E_buy, P.m.E_nonGrid, P.m.E_genLoad, P.E_greenLoad, P.greenRate)};
L(end + 1, :) = {'③ 新能源发电量消纳比例', ...
    'R_absorb = （绿电发电量 - 弃电量）/ 绿电发电量 = 100 - 弃电率'};
L(end + 1, :) = {'', '含义：上网与本地自用都算消纳（政策口径）；数值与「可再生能源利用率」一致'};
if P.noRen
    L(end + 1, :) = {'', ['⚠ 本方案不含光伏 / 风电装机（绿电发电量 = 0），' ...
        '该比例在数学上是 0/0，故计为「不适用」而不给数值 —— 给 100% 会被误读成' ...
        '「消纳良好」，与「根本没建绿电」完全相反']};
else
    L(end + 1, :) = {'', sprintf('本算例：绿电发电量（%s）%.0f MWh，弃电 %.0f MWh -> 消纳比例 %.2f%%', ...
        gopt_tern(P.m.genInGreen, '含自发电', '仅光伏+风电'), P.m.E_ren, P.m.E_curt, P.absorbRate)};
end
L(end + 1, :) = {'④ 用电成本综合节省率', ...
    'R_save = （基准购电成本 - 年化总成本）/ 基准购电成本'};
L(end + 1, :) = {'', ...
    '基准购电成本 = Σ_t w(t) x 购电价(t) x 负荷(t) x 1000 x Δt，即「不建任何绿电、负荷全靠电网买电」的年电费（不含投资）'};
L(end + 1, :) = {'', sprintf('本算例：基准 %.2f 万元/年，年化总成本 %.2f 万元/年 -> 节省率 %.2f%%', ...
    P.costBase / 1e4, P.costRef / 1e4, P.saveRate)};
L(end + 1, :) = {'⑤ LCOE 发电口径', ...
    'LCOE_gen = 分子 /（分母 x 1000）  [元/kWh，不含税]'};
L(end + 1, :) = {'', sprintf('本次分子 = %s；分母 = %s', ...
    gopt_tern(strcmp(P.lcoeGenNumMode, 'total'), '年化总成本', '光伏+风电+储能的年化投资与运维'), ...
    gopt_tern(strcmp(P.lcoeGenDenMode, 'avail'), '可用发电量（不扣弃电）', '扣掉弃电后的实际发电量'))};
L(end + 1, :) = {'', sprintf('本算例：分子 %.2f 万元/年，分母 %.0f MWh -> LCOE_gen = %.4f 元/kWh', ...
    P.numGen / 1e4, P.denGen, P.lcoeGen)};
L(end + 1, :) = {'', sprintf(['对照（含自发电，复刻上一版口径）：分子 %.2f 万元/年、分母 %.0f MWh' ...
    ' -> %.4f 元/kWh；两者之差即「自发电从绿电口径移出」带来的口径变化'], ...
    (P.numGen + (P.capD.gen - 0)) / 1e4, P.denGen + max(P.m.E_gen - P.m.E_genCurt, 0), P.lcoeGenWG)};
L(end + 1, :) = {'⑥ LCOE 消纳口径', ...
    'LCOE_con = 分子 /（分母 x 1000）  [元/kWh，不含税]'};
L(end + 1, :) = {'', sprintf('本次分子 = %s；分母 = %s', ...
    gopt_tern(strcmp(P.lcoeConNumMode, 'asset'), '光伏+风电+储能的年化投资与运维', '年化总成本'), ...
    gopt_tern(strcmp(P.lcoeConDenMode, 'self'), '自用绿电量（含储能损耗）', ...
    gopt_tern(strcmp(P.lcoeConDenMode, 'load'), '负荷总电量', ...
        '绿电供负荷电量 = 负荷电量 - 购电量')))};
L(end + 1, :) = {'', sprintf('本算例：分子 %.2f 万元/年，分母 %.0f MWh -> LCOE_con = %.4f 元/kWh', ...
    P.numCon / 1e4, P.denCon, P.lcoeCon)};
L(end + 1, :) = {'⑦ 参考电价', ...
    '基准购电均价 = 基准购电成本 / 年用电量；用户综合度电成本 = 年化总成本 / 年用电量'};
L(end + 1, :) = {'', sprintf('本算例：基准购电均价 %.4f 元/kWh，用户综合度电成本 %.4f 元/kWh', ...
    P.basePrice, P.avgPrice)};

% ---- 储能循环寿命（仅在开启耦合时才有信息量）----
eL = P.essL;
if eL.enable
    switch eL.basis
        case 'throughput', bTxt = '（年充电量+年放电量）/（2 x 额定容量）';
        case 'charge',     bTxt = '年充电量 / 额定容量';
        otherwise,         bTxt = '年放电量 / 额定容量';
    end
    L(end + 1, :) = {'⑧ 储能循环寿命', ...
        '年等效循环次数 = 年放电量 / 额定容量；循环折算寿命 = 循环寿命 / 年等效循环次数'};
    L(end + 1, :) = {'', sprintf('寿命口径 lifeMode = %s：实际寿命 = %s', eL.mode, ...
        gopt_tern(strcmp(eL.mode, 'cycle'), '循环折算寿命（不设日历上限）', ...
        'min(日历寿命, 循环折算寿命)'))};
    L(end + 1, :) = {'', sprintf(['本算例：额定循环寿命 %g 次，本次口径「%s」，', ...
        '年等效循环 %s 次/年 -> 循环折算寿命 %s 年；日历寿命 %g 年 -> 实际寿命 %g 年（受限于%s）'], ...
        eL.cycleLife, bTxt, num2str(eL.cycles, '%.2f'), num2str(eL.lifeCyc, '%.2f'), ...
        eL.lifeCal, eL.lifeUsed, gopt_tern(strcmp(eL.limited, 'cycle'), '循环寿命', '日历寿命'))};
    if eL.clamped
        L(end + 1, :) = {'', sprintf(['⚠ 已触发 lifeFloor 下限护栏：折算寿命低于 %g 年，', ...
            '已强制取 %g 年（否则 CRF 在 N->0 时发散）'], cfg.ess.lifeFloor, eL.lifeUsed)};
    end
    L(end + 1, :) = {'', ...
        '年化投资成本中的储能部分 = 储能投资 x [CRF(i, 实际寿命) + 运维费率]，故循环越深、寿命越短、年化成本越高'};
end

%% ---- ⑨ 厂内自发电（★ 本轮新增）----
% 这一段为什么必须写清楚：自发电的成本分两条通道入账（投资走 capex、燃料走运行成本），
% 而「度电成本」是把两条通道合起来摊到实发电量上的事后指标。三者关系不写明，
% 读结果时很容易误以为「同一笔钱收了两遍」。
L(end + 1, :) = {'⑨ 厂内自发电', ...
    'Gen 列 = 标幺出力；实际出力(t) = 自发电容量(MW) x Gen_pu(t)，容量即第 5 维优化变量'};
L(end + 1, :) = {'', sprintf(['成本两条通道：① 投资 = 容量(kW) x %.0f 元/kW x 年化费用率 %.6f' ...
    '（= CRF(折现率, %g 年) + 运维 %.1f%%）= %.2f 元/(kW·年)，计入「年化投资成本」；' ...
    '② 运行 = 实发电量 x %.2f 元/kWh，计入「年化运行成本」（由内层 MILP 支付）'], ...
    P.genCapex, P.genA, P.genLife, P.genOpex * 100, P.genCapex * P.genA, P.genVarCost)};
L(end + 1, :) = {'', ...
    '度电成本（事后指标，不参与寻优）= （年化投资 + 年运行成本）/ 实发电量；分母用实发量，故弃电越多该值越高'};
L(end + 1, :) = {'', sprintf(['本算例：容量 %.2f MW，可用 %.0f MWh/年，实发 %.0f MWh/年，' ...
    '弃自发电 %.0f MWh/年（利用率 %.1f%%）'], P.genCap, P.genEAvail, P.genE, P.genCurt, P.genUseRate)};
L(end + 1, :) = {'', sprintf(['本算例：年化投资 %.2f 万元/年 + 年运行 %.2f 万元/年 -> 度电成本 %.4f 元/kWh' ...
    '（其中 投资折算 %.4f + 运行 %.4f）'], P.genInvAnn / 1e4, P.genVarAnn / 1e4, ...
    P.genLcoe, P.genLcoeCap, P.genLcoeVar)};
L(end + 1, :) = {'', ['比价参照（全成本度电成本，同一算法）：' ...
    gopt_lcoe_cmp(P.genLcoe, P.refLcoePV, P.refLcoeWT, P.basePrice)]};
L(end + 1, :) = {'', ['但调度层比的是边际成本：光伏/风电 0 < 自发电 ' ...
    sprintf('%.2f', P.genVarCost) ' < 购电，故有盈余时先弃自发电（本算例自发电利用率见上行）']};
L(end + 1, :) = {'', sprintf(['自发电供负荷 %.0f MWh/年（占负荷电量 %.2f%%）；按约定「上网全部归绿电」，' ...
    '自发电上网（口径外溢项，通常为 0）%.0f MWh/年'], P.genLoadE, P.genRate, P.genSellE)};
end

%% ------------------------------------------------------------ 读取数据集
function ds = gopt_load_dataset(cfg)
%GOPT_LOAD_DATASET  读取 Dataset.xlsx，校验列名，并（可选）修复零负荷数据缺口
%   ds 字段：buy / sell [元/kWh]、load [MW]、pvPu [-]、wtPu [-]、gen [- 或 MW]
%   其中 ds.gen 的口径由 cfg.data.genMode 决定：
%     'pu' 标幺出力（默认）=> 实际出力 = 自发电容量 x ds.gen
%     'mw' 直接给 MW        => 实际出力 = ds.gen（第 5 维被锁成 1，见 gopt_apply_fixed）

if ~isempty(cfg.path.dataFile) && exist(cfg.path.dataFile, 'file') == 2
    f = cfg.path.dataFile;
else
    f = fullfile(cfg.path.root, 'Dataset.xlsx');
end
assert(exist(f, 'file') == 2, ...
    '找不到数据文件：%s\n请确认 Dataset.xlsx 与两个 .m 文件放在同一文件夹，或在 cfg.path.dataFile 指定绝对路径。', f);

opts = detectImportOptions(f, 'Sheet', cfg.path.sheet, 'VariableNamingRule', 'preserve');
TT   = readtable(f, opts);

need = {'Buy_Price','Sell_Price','Load','PV_pu','WT_pu','Gen'};
vn   = TT.Properties.VariableNames;
for k = 1:numel(need)
    assert(any(strcmp(vn, need{k})), 'Dataset.xlsx 缺少列 "%s"。当前列名：%s', need{k}, strjoin(vn, ', '));
end

ds.buy  = double(TT.Buy_Price(:));
ds.sell = double(TT.Sell_Price(:));
ds.load = double(TT.Load(:));
ds.pvPu = double(TT.PV_pu(:));
ds.wtPu = double(TT.WT_pu(:));
ds.gen  = double(TT.Gen(:));
ds.file = f;

ds.T = numel(ds.load);
assert(mod(ds.T, 24) == 0, '数据行数 %d 不是 24 的整数倍，无法按日组织。', ds.T);
ds.nDay = ds.T / 24;

cols = {'buy','sell','load','pvPu','wtPu','gen'};
for k = 1:numel(cols)
    v = ds.(cols{k});
    assert(all(isfinite(v) | isnan(v)), '数据列 %s 存在非法值（Inf）。', cols{k});
    m = isnan(v);
    if any(m)
        warning('数据列 %s 存在 %d 个空单元格，已按 0 处理。', cols{k}, sum(m));
        v(m) = 0;  ds.(cols{k}) = v;
    end
end

ds.dayId  = repelem((1:ds.nDay)', 24);
ds.hourId = repmat((1:24)', ds.nDay, 1);

%% 零负荷缺口修复
z = find(ds.load <= 0);
ds.repair.nRaw   = numel(z);
ds.repair.nFixed = 0;
ds.repair.gapDays = [];

if cfg.time.loadRepair && ~isempty(z)
    medProf = zeros(24, 1);
    for h = 1:24
        m = (ds.hourId == h) & (ds.load > 0);
        medProf(h) = median(ds.load(m));
    end
    ds.load(z) = medProf(ds.hourId(z));
    ds.repair.nFixed  = numel(z);
    ds.repair.gapDays = unique(ds.dayId(z))';
    if ~cfg.io.quiet
        fprintf('[数据] 检测到 %d 个零负荷小时，已按「同时刻有效日中位数」修复。\n', numel(z));
        fprintf('[数据] 受影响日：第 %d ~ %d 天（共 %d 天）；如需保留原始数据请设 cfg.time.loadRepair = false。\n', ...
            min(ds.repair.gapDays), max(ds.repair.gapDays), numel(ds.repair.gapDays));
    end
elseif ~isempty(z) && ~cfg.io.quiet
    fprintf('[数据] 检测到 %d 个零负荷小时，按 cfg.time.loadRepair = false 原样保留。\n', numel(z));
end

if ~cfg.io.quiet
    fprintf('[数据] 文件：%s\n', ds.file);
    fprintf('[数据] 时长：%d 小时（%d 天，逐小时）\n', ds.T, ds.nDay);
    fprintf('[数据] 负荷  ：均值 %.2f MW，峰值 %.2f MW，年电量 %.0f MWh\n', ...
        mean(ds.load), max(ds.load), sum(ds.load));
    fprintf('[数据] 光伏  ：标幺均值 %.4f（等效年利用 %.0f h）；风电：标幺均值 %.4f（等效年利用 %.0f h）\n', ...
        mean(ds.pvPu), sum(ds.pvPu), mean(ds.wtPu), sum(ds.wtPu));
    fprintf('[数据] 购电价：%.4f ~ %.4f 元/kWh（均值 %.4f）；售电价均值 %.4f 元/kWh\n', ...
        min(ds.buy), max(ds.buy), mean(ds.buy), mean(ds.sell));
    genMode = 'pu';
    if isfield(cfg, 'data') && isfield(cfg.data, 'genMode') && ~isempty(cfg.data.genMode)
        genMode = lower(char(cfg.data.genMode));
    end
    if all(abs(ds.gen) < 1e-12)
        fprintf('[数据] 提示  ：Gen 列全为 0，厂内自发电在本算例中不参与功率平衡。\n');
    elseif strcmp(genMode, 'pu')
        fprintf(['[数据] 自发电：标幺均值 %.4f（等效年利用 %.0f h，即每 MW 容量年产 %.0f MWh）；' ...
                 '实际出力 = 自发电容量 x 标幺\n'], ...
            mean(ds.gen), sum(ds.gen), sum(ds.gen));
        fprintf(['[数据] 提示  ：Gen 列按「标幺出力」解读（cfg.data.genMode = ''pu''）；' ...
                 '若该列其实是 MW，请把它改成 ''mw''。\n']);
    else
        fprintf('[数据] 自发电：按 MW 直接使用（cfg.data.genMode = ''mw''），年电量 %.0f MWh\n', ...
            sum(ds.gen));
    end
    % 判据：售电价高于购电价的「倒挂小时」。这些小时是「购售电互斥 0-1 变量」必须保留的
    % 直接依据——去掉 0-1 后 LP 会在这些小时同时买电与卖电套利（详见 cfg.milp.useBinary）。
    nInv = sum(ds.sell > ds.buy);
    if nInv > 0
        fprintf(['[数据] 电价倒挂：%d 个小时「售电价 > 购电价」（最大倒挂 %.4f 元/kWh）；' ...
                 '这些小时必须保留购售电互斥 0-1 约束，否则 LP 会同时买卖套利。\n'], ...
            nInv, max(ds.sell - ds.buy));
    end
end
end

%% ------------------------------------------------------- 构建时序调度场景
function sc = gopt_build_scenario(ds, cfg)
%GOPT_BUILD_SCENARIO  构建内层调度的时序场景（典型日 或 全年 8760 h）
%   sc.w 为每小时权重（代表天数），保证年化成本与年电量的无偏还原

if ~cfg.io.quiet, fprintf('\n[场景] 时间尺度模式：%s\n', cfg.time.mode); end

switch lower(cfg.time.mode)

    case 'full_year'
        sc.mode = 'full_year';
        sc.T    = ds.T;
        sc.buy  = ds.buy;   sc.sell = ds.sell;
        sc.load = ds.load;  sc.PV = ds.pvPu;  sc.WT = ds.wtPu;  sc.Gen = ds.gen;
        sc.w    = ones(ds.T, 1);
        sc.nYearDays = ds.nDay;

        sc.dayRanges = arrayfun(@(d) ((d-1)*24+1 : d*24)', (1:ds.nDay)', 'UniformOutput', false);
        if strcmpi(cfg.time.yearCyclic, 'day')
            sc.cyclicGroups = sc.dayRanges;    % 逐日闭合（与典型日模型的「日循环」口径完全一致）
            sc.cycLabel = arrayfun(@(d) sprintf('第%d天', d), (1:ds.nDay)', 'UniformOutput', false);
        elseif strcmpi(cfg.time.yearCyclic, 'month')
            md = [31 28 31 30 31 30 31 31 30 31 30 31];
            ed = cumsum(md * 24);
            st = [1, ed(1:end-1) + 1];
            sc.cyclicGroups = arrayfun(@(a, b) (a:b)', st(:), ed(:), 'UniformOutput', false);
            sc.cycLabel = arrayfun(@(m) sprintf('第%d月', m), (1:12)', 'UniformOutput', false);
        else
            sc.cyclicGroups = {(1:ds.T)'};
            sc.cycLabel = {'全年'};
        end
        sc.dayWeight  = ones(ds.nDay, 1);
        sc.typDay     = [];
        sc.plotRanges = {};

        % ---- 典型日曲线（全年模式同样输出，仅用于出图）----
        % 全年模式的内层在 8760 h 上一次性求解，本身没有「典型日」这个概念；为了让
        % 全年模式也能给出与典型日模式可比对的典型日图，这里补一次「只出图」的聚类：
        %   ① 把 365 天聚成 K 类（K = cfg.time.nTypicalDays，特征与典型日模式完全相同）；
        %   ② 每类取「离簇中心最近的真实自然日」作为代表日；
        %   ③ 出图时直接从 8760 h 的全年优化结果里截取这些代表日的 24 h 曲线。
        % 关键性质：
        %   · 不做任何额外优化求解（聚类约 1~2 s），对最优配置与成本零影响；
        %   · 曲线是真实的全年优化结果，功率平衡与 SOC 演化都能逐点对上，
        %     不像「簇内均值曲线」那样是构造出来的、没有对应的储能状态；
        %   · 代表日就是真实自然日，图上标签给出确切天数，便于对照原始数据。
        % 不满足条件时不聚类（省时间）：总绘图开关关闭，或源荷/堆叠/SOC 三图全关。
        wantDayFigs = cfg.out.makePlots && ...
            (gopt_flag(cfg, 'source') || gopt_flag(cfg, 'dispatch') || gopt_flag(cfg, 'soc'));
        if wantDayFigs
            [typProf, cinfo] = gopt_day_typ(ds, cfg);

            % ---- 关键：full_year 下按「代表日」重排，而不是用 gopt_day_typ 的日期键 ----
            % 本模式画的是 repDay（真实代表日）的 24 h，日志与图内标题标的也都是 repDay。
            % 若仍按 dMed / dMean / dFirst 排序，排序键与显示量就不是同一个量，会出现
            % 「典型日1 = 第240天、典型日2 = 第90天」这种看着乱序的编号（日期本身没问题，
            % 只是顺序没跟着显示量走）。故这里统一改按 repDay 升序，保证
            %   「典型日编号顺序 == 图上画出来的日期顺序」。
            % 该重排只影响编号与绘图顺序，簇成员 / 权重 / 任何优化结果都不受影响。
            [~, ordRep] = sort([typProf.repDay], 'ascend');
            typProf = typProf(ordRep);

            Kd = numel(typProf);
            sc.typDay = typProf;
            % plotRanges{k} = 第 k 个代表日在 8760 h 中的 24 个时刻（绘图统一走这个索引）
            sc.plotRanges = arrayfun(@(k) sc.dayRanges{typProf(k).repDay}, (1:Kd)', ...
                'UniformOutput', false);
            if ~cfg.io.quiet
                fprintf('[场景] 典型日出图：%d 个「真实代表日」（k-means 聚类，仅出图用，不参与优化）\n', Kd);
                fprintf('[场景] 代表日排序：按代表日（= 图上画的那天）升序\n');
                fprintf('[场景] 典型日一览（共 %d 类，合计代表 %d 天）：\n', Kd, sum([typProf.weight]));
                for k = 1:Kd
                    % 一行一个典型日：编号 + 代表日（含公历日期）+ 本类天数
                    % 代表日口径：full_year 模式画的就是 repDay（真实代表日），日志与图标题保持一致
                    gopt_daylog(k, typProf(k), 'full_year', cfg);
                end
            end
        end

        if ~cfg.io.quiet
            fprintf('[场景] 全年 %d h；SOC 循环周期：%s（共 %d 个周期）\n', ...
                sc.T, cfg.time.yearCyclic, numel(sc.cyclicGroups));
        end

    case 'typical_days'
        sc.mode  = 'typical_days';
        K        = min(cfg.time.nTypicalDays, ds.nDay);
        nDay     = ds.nDay;

        % ---- 逐日聚类：得到按日期升序排列的典型日元数据 ----
        % 聚类细节（96 维日特征、簇标号按天数重排、按日期键排序）全部收在 gopt_day_typ，
        % 与 full_year 模式的「出图用聚类」共用同一实现，保证两种模式的典型日口径一致。
        [typProf, cinfo] = gopt_day_typ(ds, cfg, K);
        sortKey = cinfo.sortKey;
        K       = numel(typProf);       % 函数内若裁剪过空簇，以实际个数为准

        % ---- 拼装调度场景 ----
        sc.T    = 24 * K;
        sc.buy  = zeros(sc.T, 1);  sc.sell = zeros(sc.T, 1);
        sc.load = zeros(sc.T, 1);  sc.PV   = zeros(sc.T, 1);
        sc.WT   = zeros(sc.T, 1);  sc.Gen  = zeros(sc.T, 1);
        sc.w    = zeros(sc.T, 1);
        sc.dayRanges    = cell(K, 1);
        sc.cyclicGroups = cell(K, 1);
        sc.dayWeight    = zeros(K, 1);

        for k = 1:K
            r = (24 * (k - 1) + 1) : (24 * k);
            sc.dayRanges{k}    = r(:);
            sc.cyclicGroups{k} = r(:);      % 每个典型日内部做 SOC 日循环
            sc.buy(r)  = typProf(k).buy;
            sc.sell(r) = typProf(k).sell;
            sc.load(r) = typProf(k).load;
            sc.PV(r)   = typProf(k).pv;
            sc.WT(r)   = typProf(k).wt;
            sc.Gen(r)  = typProf(k).gen;
            sc.w(r)    = typProf(k).weight;
            sc.dayWeight(k) = typProf(k).weight;
        end
        sc.typDay    = typProf;
        sc.cycLabel  = arrayfun(@(k) sprintf('典型日%d', k), (1:K)', 'UniformOutput', false);
        sc.nYearDays = nDay;

        if ~cfg.io.quiet
            fprintf('[场景] 抽取 %d 个典型日（%s 法），合计代表 %d 天 / %d h\n', ...
                K, cfg.time.repMethod, sum(sc.dayWeight), sc.T);
            fprintf('[场景] 内层 MILP 规模：%d h（全年 8760 h 的 %.1f%%）\n', sc.T, 100 * sc.T / 8760);
            fprintf('[场景] 各典型日代表天数：%s\n', mat2str(sc.dayWeight'));
            fprintf('[场景] 典型日顺序：按 cfg.time.typDaySort = ''%s'' 升序\n', sortKey);
            fprintf('[场景] 典型日一览（共 %d 类，合计代表 %d 天）：\n', K, sum(sc.dayWeight));
            for k = 1:K
                % 代表日口径：典型日模式画的是「簇内均值曲线」，没有唯一对应的自然日，
                % 故用簇内成员自然日的中位数 dMed 作为日期标识（与图内标题一致）。
                gopt_daylog(k, typProf(k), 'typical_days', cfg);
            end
        end

    otherwise
        error('未知的 cfg.time.mode：%s（应为 typical_days 或 full_year）', cfg.time.mode);
end

sc.sell = sc.sell(:);
sc.dt   = cfg.time.dt;
end

%% ---------------------------------------------------- 以「日」为样本做聚类
function [typProf, info] = gopt_day_typ(ds, cfg, Kwant)
%GOPT_DAY_TYP  以「日」为样本对全年做 k-means 聚类，返回按日期升序排列的典型日元数据
%
%   两种时间尺度模式共用本函数：
%     · typical_days：返回值里的 .load/.pv/.wt/... 就是内层 MILP 的调度场景；
%     · full_year   ：只借它选出「真实代表日」.repDay，用于从 8760 h 的全年优化结果里
%                     截取那几天的 24 h 曲线出图（聚类不参与优化，不影响任何结果）。
%
%   聚类特征（96 维）：每日 24 h 的 负荷 / 光伏标幺 / 风电标幺 / 购电价，
%   各自做全样本 z-score 后横向拼接——消除量纲，并突出「日内形态」而非绝对水平。
%
%   关于「簇 ≠ 一段时间」：该特征只描述日形态、不含日期信息，因此除季节特征极强的簇
%   （如纯冬季簇）外，多数簇的成员自然日在全年分散。排序键因此默认取「中位自然日」
%   而非「最早自然日」——后者在各簇都从年初就有成员时几乎退化为随机序。
%
%   ⚠️ 排序键与「显示量」必须一致：本函数按 time.typDaySort 排序（默认中位日），
%   而 full_year 模式日志与图内标题显示的是 repDay。两者不是同一个量，直接用默认键
%   会让 full_year 的编号看起来乱序 —— 因此 gopt_build_scenario 在 full_year 分支里
%   会再按 repDay 重排一次；本函数的排序键实际只决定 typical_days 模式的编号顺序。
%
%   输入
%     ds    : 数据字典（需 .load/.pvPu/.wtPu/.buy/.sell/.gen/.nDay）
%     cfg   : 全局配置（用 time.nTypicalDays / time.repMethod / time.typDaySort / pso.seed）
%     Kwant : 期望的典型日个数；省略或为空时取 cfg.time.nTypicalDays
%
%   输出
%     typProf : 1xK 结构体数组（已按日期键升序重排）
%       .load/.pv/.wt/.buy/.sell/.gen : 24x1 代表曲线
%             repMethod='mean'   -> 簇内成员均值（原典型日模型口径）
%             repMethod='medoid' -> 该簇真实代表日那一天的曲线
%       .weight  : 该簇代表天数（成员数）
%       .members : 簇内成员自然日（行向量）
%       .rep     : 'medoid' 法 = 代表日索引（标量）；'mean' 法 = 成员自然日向量
%       .repDay  : 「真实代表日」——离簇中心最近的自然日，恒为标量。
%                  'medoid' 法与 .rep 相同；'mean' 法下 .rep 是向量、不能当日期用，
%                  故单独给出，专供 full_year 出图从 8760 h 结果里截取。
%       .dFirst/.dLast/.dMed/.dMean : 成员自然日的统计量（排序键与图上日期标签）
%     info : 结构体
%       .K 实际典型日个数 | .repMethod 代表曲线取法 | .sortKey 实际使用的排序键

nDay = ds.nDay;
if nargin < 3 || isempty(Kwant)
    Kwant = cfg.time.nTypicalDays;
end
K = max(1, min(round(Kwant), nDay));

% ---- 组特征矩阵：以「日」为样本，24 h 负荷/光伏/风电/电价拼成 96 维 ----
Dl = reshape(ds.load, 24, []).';
Dp = reshape(ds.pvPu, 24, []).';
Dw = reshape(ds.wtPu, 24, []).';
Db = reshape(ds.buy,  24, []).';
Ds = reshape(ds.sell, 24, []).';
Dg = reshape(ds.gen,  24, []).';

zs = @(M) (M - mean(M(:))) ./ (std(M(:)) + 1e-12);
X  = [zs(Dl), zs(Dp), zs(Dw), zs(Db)];

% ---- k-means 聚类（Statistics and Machine Learning Toolbox）----
% 若本机未安装该工具箱，kmeans 会直接报错，此时退回「按日电量排序等分」的简化分组
%（注意：该退路只看日电量、不含日内形态，典型日不再代表源荷曲线，届时请装好工具箱）。
rng(cfg.pso.seed, 'twister');
try
    [idx, C] = kmeans(X, K, 'Start', 'plus', 'Replicates', 5, ...
                      'Distance', 'sqeuclidean', 'Display', 'off');
catch ME
    if ~cfg.io.quiet
        fprintf(2, '[场景] kmeans 不可用（%s），改用「按日电量排序等分」的简化分组。\n', ME.message);
    end
    [~, ord] = sort(sum(Dl, 2));
    idx = zeros(nDay, 1);
    edges = round(linspace(0, nDay, K + 1));
    for k = 1:K
        idx(ord(edges(k)+1 : edges(k+1))) = k;
    end
    C = zeros(K, size(X, 2));
    for k = 1:K
        C(k, :) = mean(X(idx == k, :), 1);
    end
end

% ---- 簇标号重排：天数多的簇排前面（只为编号稳定可读，不影响聚类结果）----
[~, ordK] = sort(accumarray(idx, 1, [K, 1]), 'descend');
map = zeros(K, 1);
for i = 1:K, map(ordK(i)) = i; end
idx = map(idx);

repMethod = 'mean';
if isfield(cfg.time, 'repMethod') && ~isempty(cfg.time.repMethod)
    repMethod = lower(char(cfg.time.repMethod));
end

typProf = struct('load', {}, 'pv', {}, 'wt', {}, 'buy', {}, 'sell', {}, 'gen', {}, ...
                 'weight', {}, 'rep', {}, 'repDay', {}, 'members', {}, ...
                 'dFirst', {}, 'dLast', {}, 'dMed', {}, 'dMean', {});

for k = 1:K
    mem = find(idx == k);
    if isempty(mem)
        warning('第 %d 个典型日无成员，已跳过。', k);
        mem = 1;
    end
    % 「真实代表日」恒取离簇中心最近的自然日：full_year 出图必须落在某个真实日期上
    dist   = sum((X(mem, :) - C(k, :)) .^ 2, 2);
    [~, j] = min(dist);
    repDay = mem(j);
    if strcmpi(repMethod, 'medoid')
        rep = repDay;
    else
        rep = mem;                     % 'mean' 用簇内均值
    end
    % 注意：sell / gen 必须同样按「本簇成员」取均值，不能对全年取均值
    typProf(k).load = mean(Dl(rep, :), 1)';
    typProf(k).pv   = mean(Dp(rep, :), 1)';
    typProf(k).wt   = mean(Dw(rep, :), 1)';
    typProf(k).buy  = mean(Db(rep, :), 1)';
    typProf(k).sell = mean(Ds(rep, :), 1)';
    typProf(k).gen  = mean(Dg(rep, :), 1)';
    typProf(k).rep    = rep;
    typProf(k).repDay = repDay;
    typProf(k).weight = numel(mem);
    % 记录该簇的日期信息（用于「按日期排序」与图上日期标签）
    typProf(k).members = mem(:)';
    typProf(k).dFirst  = min(mem);
    typProf(k).dLast   = max(mem);
    typProf(k).dMed    = median(mem);
    typProf(k).dMean   = mean(mem);
end

% ---- 典型日排序：按 cfg.time.typDaySort 指定的日期键升序 ----
% 该重排只改变典型日的「编号 / 绘图顺序」，不改变簇成员与权重，
% 因此对 MILP 的解与各项成本、电量指标没有任何影响。
% 注意：full_year 模式在 gopt_build_scenario 里会**再按 repDay 重排一次**
% （因为该模式显示的是 repDay，排序键必须与显示量一致），本处的键只决定
% typical_days 模式的编号顺序。
sortKey = 'median';
if isfield(cfg.time, 'typDaySort') && ~isempty(cfg.time.typDaySort)
    sortKey = lower(char(cfg.time.typDaySort));
end
keyVal = zeros(K, 1);
for k = 1:K
    switch sortKey
        case 'median', keyVal(k) = typProf(k).dMed;
        case 'mean',   keyVal(k) = typProf(k).dMean;
        case 'first',  keyVal(k) = typProf(k).dFirst;
        case 'repday', keyVal(k) = typProf(k).repDay;   % 与 full_year 的显示量一致
        otherwise,     keyVal(k) = k;      % 'none'：保持 k-means 原始簇序
    end
end
[~, ordDate] = sort(keyVal, 'ascend');
typProf = typProf(ordDate);

info = struct('K', K, 'repMethod', repMethod, 'sortKey', sortKey);
end

%% ------------------------------------------------------- 选取典型周场景
function [scw, wkLabel] = gopt_typical_week(ds, cfg)
%GOPT_TYPICAL_WEEK  选取「典型周」（最接近年平均日特征的连续 7 天）并构建 168 h 场景
nDay = ds.nDay;
nW   = floor(nDay / 7);

Dl = reshape(ds.load, 24, []).';
Dp = reshape(ds.pvPu, 24, []).';
Dw = reshape(ds.wtPu, 24, []).';
Db = reshape(ds.buy,  24, []).';

md = cfg.time.weekMode;
if isnumeric(md) && ~isempty(md)
    w   = max(1, min(round(md), nW));
    why = '指定周';
else
    m  = [mean(Dl(:)), mean(Dp(:)), mean(Dw(:)), mean(Db(:))];
    sd = [std(Dl(:)), std(Dp(:)), std(Dw(:)), std(Db(:))] + 1e-12;
    score = inf(nW, 1);
    for k = 1:nW
        d1 = (k - 1) * 7 + 1;  d2 = d1 + 6;
        f  = [mean(Dl(d1:d2, :), 'all'), mean(Dp(d1:d2, :), 'all'), ...
              mean(Dw(d1:d2, :), 'all'), mean(Db(d1:d2, :), 'all')];
        score(k) = sum(((f - m) ./ sd) .^ 2);
    end
    [~, w] = min(score);
    why = '自动选取（全年最接近平均日特征的一周）';
end

d1  = (w - 1) * 7 + 1;
d2  = d1 + 6;
idx = ((d1 - 1) * 24 + 1) : (d2 * 24);

scw = struct();
scw.mode = 'typical_week';
scw.T    = numel(idx);
scw.buy  = ds.buy(idx);
scw.sell = ds.sell(idx);
scw.load = ds.load(idx);
scw.PV   = ds.pvPu(idx);
scw.WT   = ds.wtPu(idx);
scw.Gen  = ds.gen(idx);
scw.w    = ones(scw.T, 1);
scw.dt   = cfg.time.dt;
scw.cyclicGroups = { (1:scw.T)' };      % 单周 SOC 循环
scw.cycLabel     = {'典型周'};
scw.dayRanges    = arrayfun(@(d) ((d-1)*24+1 : d*24)', (1:7)', 'UniformOutput', false);
scw.dayWeight    = ones(7, 1);
scw.weekIndex    = w;
scw.dayStart     = d1;
scw.typDay       = [];

wkLabel = sprintf('典型周（第 %d 周 = 第 %d~%d 天，%s）', w, d1, d2, why);
if ~cfg.io.quiet
    m  = [mean(Dl(:)), mean(Dp(:)), mean(Dw(:)), mean(Db(:))];
    fw = [mean(scw.load), mean(scw.PV), mean(scw.WT), mean(scw.buy)];
    fprintf('[场景] %s\n', wkLabel);
    fprintf('[场景] 典型周日均负荷 %.2f MW（全年 %.2f）| 光伏标幺 %.4f（全年 %.4f）| 风电标幺 %.4f（全年 %.4f）\n', ...
        fw(1), m(1), fw(2), m(2), fw(3), m(3));
end
end

%% =====================================================================
%% ======================  内层：最优调度 MILP  =========================
%% =====================================================================
function R = gopt_milp(cap, sc, cfg)
%GOPT_MILP  内层：给定容量配置下的最优调度（MILP，intlinprog）
%
%  输入  cap = [C_pv ; C_wt ; P_ess ; E_ess ; C_gen]   单位 MW / MW / MW / MWh / MW
%        第 5 维 C_gen = 厂内自发电额定容量（缺失时按 0 处理，兼容旧的 4 维调用）
%        sc  调度场景（sc.T 个时段，sc.w 为每个时段代表的年化天数）
%        cfg 参数
%
%==========================================================================
%  【一】决策变量（共 8T 个连续变量 + 最多 2T 个 0-1 变量）
%==========================================================================
%   连续变量（下标 iB/iS/iC/iD/iE/iQ1/iQ2/iQ3 对应下面的列块）
%     P_buy(t)    并网购电功率      [MW]  >= 0    买电进来
%     P_sell(t)   并网售电功率      [MW]  >= 0    卖电出去
%     P_ch(t)     储能充电功率      [MW]  >= 0    电进电池
%     P_dis(t)    储能放电功率      [MW]  >= 0    电出电池
%     E_soc(t)    储能荷电量        [MWh] >= 0    第 t 时段结束时的电池存量
%     P_curt,PV(t) 弃光伏功率       [MW]  >= 0    ★ 分源弃电（本轮由 1 个变量拆成 3 个）
%     P_curt,WT(t) 弃风电功率       [MW]  >= 0    ★
%     P_curt,Gn(t) 弃自发电功率     [MW]  >= 0    ★
%   0-1 变量
%     u(t) in {0,1}  购售电互斥指示：u=1 => 只允许购电；u=0 => 只允许售电
%     v(t) in {0,1}  充放电互斥指示：v=1 => 只允许充电；v=0 => 只允许放电
%
%   ★ 为什么把弃电拆成三个变量：原先把「弃电」当成一个总量，模型只知道「弃了多少」，
%     不知道「弃的是谁」，于是无法表达「优先弃哪一路」。拆开之后每一路各有自己的
%     上限（不能弃掉本来就没发的电），而目标函数里只有自发电带燃料成本，
%     于是「先弃边际成本高的」这一经济学结论会**自动**从优化里涌现出来，
%     不需要在代码里写任何人为的优先级规则。这是口径更干净、也更好解释的做法。
%
%==========================================================================
%  【二】目标函数：年化运行成本最小（元/年）
%==========================================================================
%   min  F = Σ_t  w(t) * 1000 * Δt * [ Buy(t) * P_buy(t) - Sell(t) * P_sell(t) ]
%             └────────────── 购电成本 ──────────────┘   └───── 售电收益（抵减）─────┘
%          + Σ_t  w(t) * 1000 * Δt * c_gen * ( C_gen * Gen_pu(t) - P_curt,Gn(t) )
%             └──────────────── 厂内自发电燃料+变动运维成本（★ 本轮新增）────────────────┘
%
%   逐项含义：
%     w(t)   该时段代表的全年天数（全年模式恒为 1；典型日模式 = 所属簇的天数），
%            它是「典型日压缩」能被无偏还原为年化量的关键权重。
%     Buy(t) / Sell(t)  该时刻购 / 售电价 [元/kWh]。
%     1000   单位换算：元/kWh -> 元/MWh。
%     Δt     时间步长 = 1 h，因此 功率[MW] x Δt[h] = 电量[MWh]。
%     c_gen  自发电运行成本 [元/kWh]（cfg.cost.gen.varCost，本算例 0.2）。
%     C_gen * Gen_pu(t) - P_curt,Gn(t) = 自发电**实际发出**的功率
%            —— 只对这部分付燃料费，弃掉的不付。
%
%   注意：**投资成本不在这里**。投资成本只与容量 cap 有关、与调度无关
%         （自发电的投资同样如此，它由 gopt_gen_cost 在外层一次性算清），
%         所以内层只需最小化运行成本；外层适应度再把两者相加：
%             适应度(cap) = 年化投资成本(cap) + F*(cap)
%         这样「容量选择」与「调度优化」解耦，PSO 每评估一个 cap 只需一次 MILP，
%         不产生「调度影响寿命、寿命影响投资、投资又影响调度」的循环依赖。
%
%==========================================================================
%  【三】约束条件
%==========================================================================
%  (1) 功率平衡（每小时 1 条等式，共 T 条）
%        C_pv*PV(t) + C_wt*WT(t) + C_gen*Gen_pu(t) + P_dis(t) + P_buy(t)
%          = Load(t) + P_ch(t) + P_sell(t) + P_curt,PV(t) + P_curt,WT(t) + P_curt,Gn(t)
%      └ 左侧 = 供给：光伏 + 风电 + 厂内自发电 + 储能放电 + 购电
%      └ 右侧 = 去向：负荷 + 储能充电 + 售电 + 分源弃电
%      └ 即「每一刻供给必须恰好等于去向」，分源弃电是被允许的浪费出口。
%
%  (2) 储能荷电状态（SOC）动态（每小时 1 条等式，共 T 条）
%        E_soc(t) = (1 - σ) * E_soc(t-1) + η_ch * P_ch(t) * Δt - P_dis(t) * Δt / η_dis
%      └ σ     自放电率 [1/h]        ；第一项 (1-σ)*E_soc(t-1) 是残留电量
%      └ η_ch  充电效率（充满要"多买"电） ；η_dis 放电效率（放出要"打折"）
%      └ 「前一小时 t-1」由 sc.cyclicGroups 定义：在同一个循环周期内往前一格；
%        周期首元素的前一个小时取该周期的**末元素**，
%        于是「周期首末 SOC 相等」这个闭合条件被自动满足，无需再加等式。
%
%  (3) SOC 上下限（变量上下界，2T 条）
%        SOCmin * E_ess <= E_soc(t) <= SOCmax * E_ess
%      └ E_ess 为储能容量 [MWh]；该界防止过充过放、留出寿命裕量。
%
%  (4) 充放电功率上限（变量上下界，2T 条）
%        0 <= P_ch(t) <= P_ess ,  0 <= P_dis(t) <= P_ess
%      └ P_ess 为储能功率 [MW]（变流器容量），充放都不能超过它。
%
%  (5) 并网限值 + 购售电互斥（big-M，2T 条不等式）
%        0 <= P_buy(t)  <= bBuy  * u(t)
%        0 <= P_sell(t) <= bSell * (1 - u(t))
%      └ 目的：同一小时不能"又买又卖"。因为购电价(均值 0.6 元/kWh)远高于
%        售电价(0.2 元/kWh)，若不加这条约束，模型确实不会傻到同时买卖（亏钱），
%        但在电价倒挂的时刻 LP 可能给出退化解，约束可彻底消除这种歧义。
%      └ ⚠ 该约束**不可关闭**：本数据集有 89 个小时「售电价 > 购电价」
%        （最大倒挂 0.0298 元/kWh），去掉 0-1 之后纯 LP 会在这些小时同时买电与
%        售电套利，凭空造出上亿元/年的假收益（真实总成本仅 7644 万元/年）。
%      └ bBuy  = min(并网购电上限, 最大负荷 + P_ess)   —— 放大到"够用即可"
%        bSell = min(并网售电上限, 最大可再生+自发电出力 + P_ess)
%        取 min 是为了让 big-M 尽量小，改善 MILP 的数值条件（分支定界更紧）。
%
%  (6) 分源弃电上限（变量上下界，3T 条）★ 本轮由 1 个变量拆成 3 个
%        0 <= P_curt,PV(t) <= C_pv * PV(t)
%        0 <= P_curt,WT(t) <= C_wt * WT(t)
%        0 <= P_curt,Gn(t) <= C_gen * Gen_pu(t)
%      └ 每一路只能弃掉「本来能发的」电，不能凭空多弃。
%      └ cfg.const.allowCurtail = false  => 三者上限全部为 0（完全不允许弃电）。
%      └ cfg.const.genCurtMode = 'no_curtail' => 自发电那一路上限为 0
%        （自发电必发不可弃，弃电只能来自光伏/风电）。
%
%  (7) 充放电互斥（可选 big-M，2T 条；cfg.milp.cdBinary = true 时启用）
%        0 <= P_ch(t)  <= P_ess * v(t)
%        0 <= P_dis(t) <= P_ess * (1 - v(t))
%      └ 由于 η_ch x η_dis < 1，"同时充放"一定亏电又亏效率，最优解本身不会这么做；
%        该约束只是排除 LP 退化顶点。默认关闭以加速搜索（全年可省 T 个整数变量），
%        输出前由 cfg.out.strictDispatch 在最优配置上严格重解一次。
%
%  (8) 年加权能量中性（仅 cfg.ess.cycleMode = 'neutral' 的典型日模式）
%        Σ_g (w_g / Σw) * (E_end,g - E_start,g) = 0
%      └ 允许跨日搬运电量时，保证全年各周期 SOC 净变化为 0（不凭空造电）。
%      └ 权重先归一化，避免该行系数量级（最大 ~54）与其它约束（~1）差太多而
%        劣化数值条件。
%
%==========================================================================
%  求解：intlinprog（含 0-1 变量）或 linprog（无 0-1 变量时退化为纯 LP）
%==========================================================================

OBJS = 1e6;   % 目标缩放系数（把 ~1e8 元压到 ~1e2，提升数值稳定性）

cap = double(cap(:));
% 兼容旧调用：只给 4 维时，第 5 维（自发电容量）按 0 处理（= 不建自发电）。
% 保留这个兼容口子是为了让 selftest、敏感性扫描等旧代码在改造期间也能跑通，
% 但主流程一律传 5 维（见 gopt_eval_fit / gopt_annual_capex）。
if numel(cap) == 4, cap(5, 1) = 0; end
assert(numel(cap) == 5, ...
    'cap 必须是 5 维向量 [C_pv; C_wt; P_ess; E_ess; C_gen]（给 4 维时自动补 C_gen = 0）。');
assert(all(cap >= -1e-12), '容量不能为负。');
cap = max(cap, 0);

C_pv = cap(1);  C_wt = cap(2);  P_ess = cap(3);  E_ess = cap(4);  C_gen = cap(5);
T = sc.T;  dt = sc.dt;

%% ---- 1. 可用出力（约束 (1) 的已知量部分）----
pvAv  = C_pv * sc.PV(:);     % 光伏可用出力 [MW] = 装机容量 x 标幺出力
wtAv  = C_wt * sc.WT(:);     % 风电可用出力 [MW]
genAv = C_gen * sc.Gen(:);   % 厂内自发电可用出力 [MW]（★ 本轮新增）
                             %   Gen 列是「标幺出力」，容量是优化变量，
                             %   两者相乘才是 MW。旧版直接把 Gen 当 MW 用，
                             %   等价于隐式假设自发电容量恒为 1 MW。
reAv  = pvAv + wtAv + genAv; % 可再生 + 自发电可用出力合计（用于并网 big-M 与合计口径统计）
load  = sc.load(:);          % 负荷 [MW]

%% ---- 2. 变量索引（把 8T 个连续变量按列块排布，便于稀疏组装）----
%   ★ 弃电由 1 个变量拆成 3 个：iQ1 = 弃光伏、iQ2 = 弃风电、iQ3 = 弃自发电。
iB  = (1:T)';        iS  = T   + (1:T)';     % P_buy,  P_sell
iC  = 2*T + (1:T)';  iD  = 3*T + (1:T)';     % P_ch,   P_dis
iE  = 4*T + (1:T)';                          % E_soc
iQ1 = 5*T + (1:T)';  iQ2 = 6*T + (1:T)';     % P_curt,PV / P_curt,WT
iQ3 = 7*T + (1:T)';                          % P_curt,Gn
nVar = 8*T;

% ---- 储能循环模式 ----
%   'day'     每个循环周期首末 SOC 闭合（典型日 = 日循环，最保守）
%   'neutral' 每个周期的起始 SOC 为自由变量，另加一条「年加权能量中性」等式。
%             相当于允许跨日搬运电量，取消「每天必须满充满放一次」的人为限制。
cycleMode = 'day';
if isfield(cfg.ess, 'cycleMode'), cycleMode = lower(cfg.ess.cycleMode); end
nG = numel(sc.cyclicGroups);
useNeutral = strcmp(cycleMode, 'neutral') && ~cfg.ess.fixInitialSoc && ...
             (nG == numel(sc.dayWeight));
iE0 = [];
if useNeutral
    iE0  = nVar + (1:nG)';           % 各循环周期的起始 SOC（自由变量）
    nVar = nVar + nG;
end

intcon = [];
if cfg.milp.useBinary
    iU = nVar + (1:T)';  nVar = nVar + T;  intcon = [intcon; iU];   % 购售电互斥
end
if cfg.milp.cdBinary
    iV = nVar + (1:T)';  nVar = nVar + T;  intcon = [intcon; iV];   % 充放电互斥
end

%% ---- 3. 目标函数 ---------------------------------------------------------
%   min  Σ_t w(t)*1000*Δt*[ Buy(t)*P_buy(t) - Sell(t)*P_sell(t) ]
%      + Σ_t w(t)*1000*Δt*c_gen*( C_gen*Gen_pu(t) - P_curt,Gn(t) )
%   系数 f(iB) = + w * Buy  * 1000 * Δt   （购电 = 花钱，正成本）
%   系数 f(iS) = - w * Sell * 1000 * Δt   （售电 = 挣钱，负成本，抵减总成本）
%   系数 f(iQ3)= - w * c_gen * 1000 * Δt  （★ 弃自发电 = 少烧燃料，抵减成本）
%
%   关于自发电那一项为什么只写「-c_gen * P_curt,Gn」：
%     真实成本 = c_gen * (C_gen*Gen_pu - P_curt,Gn) = c_gen*C_gen*Gen_pu - c_gen*P_curt,Gn
%     前一项 c_gen*C_gen*Gen_pu 在给定 cap 与给定标幺曲线下是**常数**，
%     对 argmin 毫无影响，故不进目标函数；但它是真实支出，必须计入 R.cost
%     （在下面的成本口径里按实际发电量一次算清）。这样写的好处是：
%       (1) 目标函数里只留真正随决策变化的项，数值条件更好；
%       (2) 优化器会主动「多弃一点自发电来省钱」，即自动「先弃贵的」，
%           不需要任何人为优先级 —— 这正是用户要的「不使用高成本电量、
%           保留低成本电量」。
cGen = 0;   % 元/kWh 自发电运行成本（燃料 + 变动运维）
if isfield(cfg, 'cost') && isfield(cfg.cost, 'gen') ...
        && isfield(cfg.cost.gen, 'varCost') && ~isempty(cfg.cost.gen.varCost)
    cGen = cfg.cost.gen.varCost;
end

f = zeros(nVar, 1);
f(iB)  =  sc.w(:) .* sc.buy(:)  * (1000 * dt);
f(iS)  = -sc.w(:) .* sc.sell(:) * (1000 * dt);
f(iQ3) = -sc.w(:) .* cGen       * (1000 * dt);
f = f / OBJS;   % 整体缩放，不影响最优解，只改善求解器数值条件

%% ---- 4. 变量边界（对应约束 (3)(4)(6)）----
%  big-M 取「够用就好」的值：bBuy / bSell 越小，分支定界越紧、求解越快越稳。
bBuy  = min(cfg.const.gridImportMax, max(load) + P_ess);
bSell = min(cfg.const.gridExportMax, max(reAv) + P_ess);

% ---- 弃电口径 ----
%   allowCurtail : 全局开关（cfg.const.allowCurtail），false => 三路弃电全部为 0
%   genCurtMode  : 自发电弃电口径（cfg.const.genCurtMode）
%                  'economic'   自发电可弃（默认）=> 优化器按边际成本自动排序
%                  'no_curtail' 自发电不可弃    => 自发电那一路上限为 0
allowCurt    = logical(cfg.const.allowCurtail);
genCurtMode  = 'economic';
if isfield(cfg.const, 'genCurtMode') && ~isempty(cfg.const.genCurtMode)
    genCurtMode = lower(char(cfg.const.genCurtMode));
end
allowGenCurt = allowCurt && strcmp(genCurtMode, 'economic');

lb = zeros(nVar, 1);  ub = zeros(nVar, 1);
lb(iB) = 0;  ub(iB) = bBuy;                       % 购电：0 ~ bBuy   （约束 (5) 还会与 u 联动）
lb(iS) = 0;  ub(iS) = bSell;                      % 售电：0 ~ bSell
lb(iC) = 0;  ub(iC) = P_ess;                      % 充电功率 <= 储能功率  【约束 (4)】
lb(iD) = 0;  ub(iD) = P_ess;                      % 放电功率 <= 储能功率  【约束 (4)】
lb(iE) = cfg.ess.socMin * E_ess;                  % SOC 下限            【约束 (3)】
ub(iE) = cfg.ess.socMax * E_ess;                  % SOC 上限            【约束 (3)】
% ---- 分源弃电上限【约束 (6)】★ 本轮新增：三路各自绑定自身的可用出力 ----
lb(iQ1) = 0;  ub(iQ1) = allowCurt * pvAv;         % 弃光伏  <= 光伏可用出力
lb(iQ2) = 0;  ub(iQ2) = allowCurt * wtAv;         % 弃风电  <= 风电可用出力
lb(iQ3) = 0;  ub(iQ3) = allowGenCurt * genAv;     % 弃自发电<= 自发电可用出力
if cfg.milp.useBinary, lb(iU) = 0;  ub(iU) = 1; end               % u(t) 0-1
if cfg.milp.cdBinary,  lb(iV) = 0;  ub(iV) = 1; end               % v(t) 0-1
if useNeutral
    lb(iE0) = cfg.ess.socMin * E_ess;   ub(iE0) = cfg.ess.socMax * E_ess;
end

%% ---- 5. 等式约束（对应约束 (1) 功率平衡、(2) SOC 动态）----
%  prevIdx(t) 记录「t 的前一个小时」：同一循环周期内前移一格；
%  周期首元素的前一小时指向周期末元素 => 自动形成 SOC 周期闭合。
prevIdx = zeros(T, 1);
for g = 1:numel(sc.cyclicGroups)
    grp = sc.cyclicGroups{g}(:);
    if useNeutral
        prevIdx(grp(1))     = -g;              % 负号标记：前一"小时"用起始 SOC 辅助变量 iE0(g)
        prevIdx(grp(2:end)) = grp(1:end-1);
    else
        prevIdx(grp) = [grp(end); grp(1:end-1)];
    end
end

nFix = 0;
if isfield(cfg.ess, 'fixInitialSoc') && cfg.ess.fixInitialSoc
    nFix = numel(sc.cyclicGroups);             % 强制每个周期起始 SOC = socInit
end
nNeutral = double(useNeutral);

nEq = 2*T + nFix + nNeutral;
% 三元组容量 = 功率平衡 7 项/T + SOC 动态 4 项/T + 初始SOC 1 项/周期 + 中性 2 项/周期
ri = zeros(7*T + 4*T + nFix + 2*nG, 1);        % 行号 / 列号 / 值（三元组，随后组装为稀疏矩阵）
ci = zeros(size(ri));  vi = zeros(size(ri));
beq = zeros(nEq, 1);
k = 0;

% (1) 功率平衡：C_pv*PV + C_wt*WT + C_gen*Gen_pu + P_dis + P_buy
%              - Load - P_ch - P_sell - P_curt,PV - P_curt,WT - P_curt,Gn = 0
%     移项后写成 Aeq*x = beq 的标准形式：
%       +P_buy - P_sell - P_ch + P_dis - P_curt,PV - P_curt,WT - P_curt,Gn
%         = Load - PV可用 - WT可用 - 自发电可用
for t = 1:T
    k = k + 1;  ri(k) = t;  ci(k) = iB(t);   vi(k) =  1;    % + 购电
    k = k + 1;  ri(k) = t;  ci(k) = iS(t);   vi(k) = -1;    % - 售电
    k = k + 1;  ri(k) = t;  ci(k) = iC(t);   vi(k) = -1;    % - 充电
    k = k + 1;  ri(k) = t;  ci(k) = iD(t);   vi(k) =  1;    % + 放电
    k = k + 1;  ri(k) = t;  ci(k) = iQ1(t);  vi(k) = -1;    % - 弃光伏  ★
    k = k + 1;  ri(k) = t;  ci(k) = iQ2(t);  vi(k) = -1;    % - 弃风电  ★
    k = k + 1;  ri(k) = t;  ci(k) = iQ3(t);  vi(k) = -1;    % - 弃自发电★
    beq(t) = load(t) - pvAv(t) - wtAv(t) - genAv(t);        % 右端 = 净负荷
end

% (2) SOC 动态：E(t) - (1-σ)E(t-1) - η_ch*P_ch*Δt + (Δt/η_dis)*P_dis = 0
sig = cfg.ess.selfDis;
for t = 1:T
    r = T + t;  p = prevIdx(t);
    k = k + 1;  ri(k) = r;  ci(k) = iE(t);  vi(k) =  1;
    if p > 0
        k = k + 1;  ri(k) = r;  ci(k) = iE(p);    vi(k) = -(1 - sig);   % 上个时段残留电量
    else
        k = k + 1;  ri(k) = r;  ci(k) = iE0(-p);  vi(k) = -(1 - sig);   % neutral 模式下的周期起始 SOC
    end
    k = k + 1;  ri(k) = r;  ci(k) = iC(t);  vi(k) = -cfg.ess.etaCh * dt;        % 充电存入（效率打折）
    k = k + 1;  ri(k) = r;  ci(k) = iD(t);  vi(k) =  dt / cfg.ess.etaDis;       % 放电取出（要多取）
    beq(r) = 0;
end

% (2b) 可选：强制每个循环周期起始 SOC = socInit（cfg.ess.fixInitialSoc = true 时）
if nFix > 0
    for g = 1:numel(sc.cyclicGroups)
        r = 2*T + g;  h = sc.cyclicGroups{g}(1);
        k = k + 1;  ri(k) = r;  ci(k) = iE(h);  vi(k) = 1;
        beq(r) = cfg.ess.socInit * E_ess;
    end
end

% (8) 年加权能量中性：Σ_g (w_g/Σw)(E_end,g - E_start,g) = 0
%     权重先归一化，避免该行系数（最大 ~54）与其它约束（~1）量级相差过大而劣化数值条件。
if useNeutral
    r = 2*T + nFix + 1;
    wSum = sum(sc.dayWeight);
    for g = 1:nG
        grp = sc.cyclicGroups{g}(:);
        wgt = sc.dayWeight(g) / wSum;
        k = k + 1;  ri(k) = r;  ci(k) = iE(grp(end));  vi(k) =  wgt;
        k = k + 1;  ri(k) = r;  ci(k) = iE0(g);        vi(k) = -wgt;
    end
    beq(r) = 0;
end

Aeq = sparse(ri(1:k), ci(1:k), vi(1:k), nEq, nVar);

%% ---- 6. 不等式约束（对应约束 (5) 购售电互斥、(7) 充放电互斥）----
% 每一行含两个非零元（功率变量 + 0-1 变量），因此「行号」与「非零元序号」必须分开计数。
nB = 0;  nZ = 0;
if cfg.milp.useBinary, nB = nB + 2*T;  nZ = nZ + 4*T; end
if cfg.milp.cdBinary,  nB = nB + 2*T;  nZ = nZ + 4*T; end

si = zeros(nZ, 1);  sj = zeros(nZ, 1);  sv = zeros(nZ, 1);
b  = zeros(nB, 1);
row = 0;  e = 0;

if cfg.milp.useBinary
    for t = 1:T
        row = row + 1;                       % P_buy(t) - bBuy*u(t) <= 0  =>  u=0 时不许购电
        e = e + 1;  si(e) = row;  sj(e) = iB(t);  sv(e) =  1;
        e = e + 1;  si(e) = row;  sj(e) = iU(t);  sv(e) = -bBuy;
        b(row) = 0;
        row = row + 1;                       % P_sell(t) + bSell*u(t) <= bSell => u=1 时不许售电
        e = e + 1;  si(e) = row;  sj(e) = iS(t);  sv(e) =  1;
        e = e + 1;  si(e) = row;  sj(e) = iU(t);  sv(e) =  bSell;
        b(row) = bSell;
    end
end

if cfg.milp.cdBinary
    for t = 1:T
        row = row + 1;                       % P_ch(t) - P_ess*v(t) <= 0  =>  v=0 时不许充电
        e = e + 1;  si(e) = row;  sj(e) = iC(t);  sv(e) =  1;
        e = e + 1;  si(e) = row;  sj(e) = iV(t);  sv(e) = -P_ess;
        b(row) = 0;
        row = row + 1;                       % P_dis(t) + P_ess*v(t) <= P_ess => v=1 时不许放电
        e = e + 1;  si(e) = row;  sj(e) = iD(t);  sv(e) =  1;
        e = e + 1;  si(e) = row;  sj(e) = iV(t);  sv(e) =  P_ess;
        b(row) = P_ess;
    end
end

assert(e == nZ && row == nB, '不等式矩阵组装规模不一致。');
if nB > 0, A = sparse(si, sj, sv, nB, nVar); else, A = sparse(0, nVar); end

%% ---- 7. 求解（有 0-1 变量用 intlinprog，否则退化为 linprog）----
if isempty(intcon)
    opts = optimoptions('linprog', 'Display', cfg.milp.display, 'MaxTime', cfg.milp.timeLimit);
    [x, fval, exitflag, outSolver] = linprog(f, A, b, Aeq, beq, lb, ub, opts);
else
    opts = optimoptions('intlinprog', 'Display', cfg.milp.display, ...
        'MaxTime', cfg.milp.timeLimit, 'RelativeGapTolerance', cfg.milp.relGap);
    [x, fval, exitflag, outSolver] = intlinprog(f, intcon, A, b, Aeq, beq, lb, ub, opts);
end

R = struct();
R.cap      = cap;
R.exitflag = exitflag;
R.ok       = (exitflag > 0) && ~isempty(x);
R.solver   = outSolver;

if ~R.ok
    R.cost    = inf;
    R.message = sprintf('求解器未得到可行解 (exitflag=%d)', exitflag);
    R.P_buy = []; R.P_sell = []; R.P_ch = []; R.P_dis = []; R.E_soc = [];
    R.P_curt = []; R.P_curtPV = []; R.P_curtWT = []; R.P_curtGen = [];
    R.P_pv = []; R.P_wt = []; R.P_gen = []; R.P_genAvail = []; R.socPct = [];
    R.maxResid = inf; R.nSimChDis = 0; R.nSimBuySell = 0;
    R.simChDisMWh = 0; R.simBuySellMWh = 0; R.simChDisPct = 0; R.simBuySellPct = 0;
    R.costBuy = inf; R.revenueSell = 0; R.costGenVar = 0;
    R.energyBuy = 0; R.energySell = 0; R.energyCurt = 0; R.energyLoad = 0;
    R.energyCurtPV = 0; R.energyCurtWT = 0; R.energyCurtGen = 0;
    R.energyGen = 0; R.energyGenAvail = 0; R.energyRenAvail = 0;
    R.energyRen = 0; R.energyCh = 0; R.energyDis = 0;
    R.utilRen = 0; R.utilRenOnly = 0; R.utilGen = 0;
    R.fvalScaled = inf;
    R.cGen = cGen;  R.genCurtMode = genCurtMode;
    R.E0 = [];  R.cycleMode = 'day';
    return;
end

%% ---- 8. 结果整理（把解向量拆回各物理量）----
tol = 1e-6;
R.P_buy  = max(x(iB), 0);  R.P_buy(R.P_buy   < tol) = 0;
R.P_sell = max(x(iS), 0);  R.P_sell(R.P_sell < tol) = 0;
R.P_ch   = max(x(iC), 0);  R.P_ch(R.P_ch     < tol) = 0;
R.P_dis  = max(x(iD), 0);  R.P_dis(R.P_dis   < tol) = 0;
R.E_soc  = max(x(iE), 0);
% ---- 分源弃电（★ 本轮新增）：三路各自取出，并保留合计字段以兼容旧代码 ----
R.P_curtPV  = max(x(iQ1), 0);  R.P_curtPV(R.P_curtPV   < tol) = 0;
R.P_curtWT  = max(x(iQ2), 0);  R.P_curtWT(R.P_curtWT   < tol) = 0;
R.P_curtGen = max(x(iQ3), 0);  R.P_curtGen(R.P_curtGen < tol) = 0;
R.P_curt    = R.P_curtPV + R.P_curtWT + R.P_curtGen;   % 合计（旧字段名，绘图/导出仍可用）
R.P_pv   = pvAv;
R.P_wt   = wtAv;
R.P_genAvail = genAv;                                   % 自发电可用出力 [MW]
R.P_gen  = max(genAv - R.P_curtGen, 0);                 % 自发电实际出力 [MW]
if E_ess > 0, R.socPct = R.E_soc / E_ess * 100; else, R.socPct = zeros(T, 1); end
if useNeutral, R.E0 = x(iE0); else, R.E0 = []; end
R.cycleMode = cycleMode;
R.cGen      = cGen;
R.genCurtMode = genCurtMode;

%% ---- 成本口径（元/年）：购电成本 - 售电收益 + 自发电燃料/变动运维 ----
w = sc.w(:);
R.costBuy     = sum(w .* sc.buy(:)  * 1000 * dt .* R.P_buy);
R.revenueSell = sum(w .* sc.sell(:) * 1000 * dt .* R.P_sell);
% ★ 自发电运行成本：只对**实际发出的电量**计费（弃掉的不烧燃料、不付费）
R.costGenVar  = sum(w .* cGen * 1000 * dt .* R.P_gen);
R.cost        = R.costBuy - R.revenueSell + R.costGenVar;

%% ---- 电量统计（MWh/年，含典型日加权还原）----
R.energyBuy  = sum(w .* R.P_buy  * dt);     % 全年购电量
R.energySell = sum(w .* R.P_sell * dt);     % 全年售电量
R.energyCurtPV  = sum(w .* R.P_curtPV  * dt);
R.energyCurtWT  = sum(w .* R.P_curtWT  * dt);
R.energyCurtGen = sum(w .* R.P_curtGen * dt);
R.energyCurt = R.energyCurtPV + R.energyCurtWT + R.energyCurtGen;   % 全年弃风弃光弃自发合计
R.energyLoad = sum(w .* load     * dt);     % 全年负荷电量
R.energyGen      = sum(w .* R.P_gen      * dt);   % 自发电实发电量（★）
R.energyGenAvail = sum(w .* R.P_genAvail * dt);   % 自发电可用电量（★）
R.energyRenAvail = sum(w .* (pvAv + wtAv) * dt);  % 光伏 + 风电可用电量（绿电口径）
R.energyRen  = sum(w .* reAv     * dt);     % 可再生 + 自发电可用电量合计（保留旧口径）
R.energyCh   = sum(w .* R.P_ch   * dt);     % 全年储能充电量
R.energyDis  = sum(w .* R.P_dis  * dt);     % 全年储能放电量
% ★ 利用率：分母为 0 时一律返回 NaN 而不是 100%。
%   为什么必须这样：若某一路电源没装机，它的「可用电量」为 0，公式 1 - 0/0 会被
%   算成 100%，读起来像「消纳得完美无缺」，与事实（根本没建）完全相反。
if R.energyRen > 1e-9
    R.utilRen     = 1 - R.energyCurt / R.energyRen;                     % 合计利用率（光伏+风电+自发电）
else
    R.utilRen     = NaN;
end
if R.energyRenAvail > 1e-9
    R.utilRenOnly = 1 - (R.energyCurtPV + R.energyCurtWT) / R.energyRenAvail;   % 绿电利用率
else
    R.utilRenOnly = NaN;
end
if R.energyGenAvail > 1e-9
    R.utilGen     = 1 - R.energyCurtGen / R.energyGenAvail;             % 自发电利用率
else
    R.utilGen     = NaN;
end

%% ---- 约束校验（自检用）----
resid = (pvAv + wtAv + genAv + R.P_dis + R.P_buy) ...
      - (load + R.P_ch + R.P_sell + R.P_curt);
R.maxResid    = max(abs(resid));
R.nSimChDis   = sum((R.P_ch > tol) & (R.P_dis > tol));
R.nSimBuySell = sum((R.P_buy > tol) & (R.P_sell > tol));
R.simChDisMWh   = sum(sc.w(:) .* min(R.P_ch,  R.P_dis) * dt);
R.simBuySellMWh = sum(sc.w(:) .* min(R.P_buy, R.P_sell) * dt);
R.simChDisPct   = R.simChDisMWh   / max(R.energyCh,   eps) * 100;
R.simBuySellPct = R.simBuySellMWh / max(R.energySell, eps) * 100;
R.fvalScaled  = fval;
end

%% -------------------------------------------------- 单点适应度（带缓存）
function [fit, cap, capex] = gopt_eval_fit(s, cfg, sc, lb, ub, cache)
%   外层适应度 = 年化投资成本(cap) + 内层最优年化运行成本 F*(cap)
%   同一点重复出现时直接用缓存，避免重复求解 MILP。
%   ★ 5 维映射：s = [C_pv, C_wt, P_ess, T_ess, C_gen] -> cap（第 4 维由功率 x 时长派生，
%     第 5 维是自发电容量，直接就是 MW，不需要派生）。
s = s(:)';
s = min(max(s, lb(:)'), ub(:)');
cap = [s(1); s(2); s(3); s(3) * s(4); s(5)];        % 储能容量 = 储能功率 x 储能时长

if isempty(cache)
    [fit, capex] = gopt_eval_raw(cap, cfg, sc);
    return;
end
key = sprintf('%.10g_', cap);
if isKey(cache, key)
    v = cache(key);
    fit = v(1);  capex = v(2);
else
    [fit, capex] = gopt_eval_raw(cap, cfg, sc);
    cache(key) = [fit, capex];
end
end

function [fit, capex] = gopt_eval_raw(cap, cfg, sc)
R = gopt_milp(cap, sc, cfg);
if R.ok
    % R 必须传给 gopt_annual_capex：储能寿命要由「这次调度用了多少次循环」反算。
    % 漏传会退回日历寿命，于是适应度里的投资成本与最终报表算成两套口径。
    % 自发电的年化投资同样在 gopt_annual_capex 内部（经 gopt_gen_cost）算清，
    % 而它的运行成本已经由内层 gopt_milp 计入 R.cost —— 两块不重不漏。
    capex = gopt_annual_capex(cap, cfg, R);
    fit   = capex + R.cost;
else
    capex = inf;
    fit   = 1e12;                     % 不可行解的罚函数
end
end

%% ------------------------------------------------------------ 外层 PSO
function out = gopt_pso(cfg, sc, ds)
%GOPT_PSO  外层驱动：5 维配置搜索 = 边界诊断外扩 + 两阶段 + 局部精修
%
%  搜索变量 s = [C_pv, C_wt, P_ess, T_ess, C_gen]（★ 第 5 维为本轮新增的自发电容量）
%           cap = [C_pv; C_wt; P_ess; P_ess*T_ess; C_gen]
%  适应度   fit = 年化投资成本(cap, R) + 内层最优年化运行成本 F*(cap)
%
%  本函数只负责「调度」：把两阶段的搜索框、边界外扩、局部精修串起来；
%  真正的 PSO 迭代在 gopt_pso_core 里，便于阶段 A / 阶段 B 复用同一套内核。
%
%  ── 本轮针对「易陷局部最优」的四组改造（参数见 cfg_greenopt.m 第 5 节）──
%   (1) 边界诊断 + 自动外扩：最优解贴上界往往意味着「上界把真解挡住」而不是
%       「真解就在界上」（上一版实测：光伏 = 50 MW = ub、风电 = 2 MW = lb，双向贴界）。
%       检出贴界就把该维上界推远并重启一轮；expandFree=false 的维度是工程硬界，永不外扩。
%   (2) 初始化升级：拉丁超立方 / 对立学习 / 混沌映射，取代纯随机撒点。
%   (3) 多种群小生境 + 逃逸重启：子群独立演化、周期交换最优；停滞时先对 gbest 加
%       扰动并重撒粒子，连续几轮仍无改进才真早停（旧版一停滞就直接跳出）。
%   (4) 两阶段搜索：阶段 A 用典型日口径大规模粗搜，阶段 B 回到目标口径精搜。
%       **双层嵌套结构不变**，只是让内层 MILP 换两种时间尺度各跑一遍。
%
%  输入  cfg 目标口径配置；sc 目标口径场景；ds 数据集（两阶段构造典型日场景用，缺省则单阶段）
%  输出  out 见 gopt_pack_out，另含 .boundLog / .stageInfo / .hitBound / .twoStage

nD = 5;
[varName, ~] = gopt_varnames();
lbP = cfg.pso.lb(:);   ubP = cfg.pso.ub(:);     % 物理界（自动外扩不得超过它）
assert(numel(lbP) == nD && numel(ubP) == nD, ...
    ['cfg.pso.lb / ub 必须是 5 维：' ...
     '[光伏容量; 风电容量; 储能功率; 储能时长; 自发电容量]。']);
assert(all(ubP >= lbP), '搜索范围非法：存在 ub < lb 的维度。');

effFree = (ubP - lbP) > 1e-12;
say = @(varargin) gopt_say(cfg, varargin{:});

% 储能功率固定为 0 时，储能时长维度无意义 -> 折叠
if ~effFree(3) && lbP(3) <= 1e-12 && effFree(4)
    effFree(4) = false;
    ubP(4) = lbP(4);
    fprintf('[PSO] 储能功率固定为 0，储能时长维度自动折叠（储能容量恒为 0）。\n');
end

% ---- 边界诊断参数 ----
expandFree = [true; true; true; false; false];
if isfield(cfg.pso, 'expandFree') && ~isempty(cfg.pso.expandFree)
    expandFree = logical(cfg.pso.expandFree(:));
    assert(numel(expandFree) == nD, 'cfg.pso.expandFree 必须是 5 维逻辑向量。');
end
doBound      = gopt_pget(cfg.pso, 'boundCheck', true);
boundFrac    = gopt_pget(cfg.pso, 'boundFrac', 0.02);
expandFactor = gopt_pget(cfg.pso, 'expandFactor', 1.5);
expandMax    = gopt_pget(cfg.pso, 'expandMax', 2);
nPop         = gopt_pget(cfg.pso, 'nPop', 10);
maxIt        = gopt_pget(cfg.pso, 'maxIter', 8);

% ---- 跨阶段记账 ----
logB      = {};
% 空结构体数组（1x0）而不是放一条「未开始」占位：占位会在 Excel 的「最优配置」表里
% 留下一行「（未开始）：评估 0 次，成本 NaN」，看着像程序出错。
stageInfo = gopt_stage_rec('', 0, 0, NaN, '');
stageInfo(1) = [];
nEval     = 0;
histAll   = [];      % 第一列取「至今最优」（故曲线单调不升），第二列取当轮种群均值
bestSoFar = inf;
tAll      = tic;

%% ---- 0. 固定配置快速通道 ----
if ~any(effFree)
    s   = lbP(:)';
    cap = [s(1); s(2); s(3); s(3) * s(4); s(5)];
    cfgF = cfg;  cfgF.milp.relGap = min(cfg.milp.relGap, 1e-7);
    R = gopt_milp(cap, sc, cfgF);
    if ~R.ok
        error('固定配置下内层调度无可行解：%s', R.message);
    end
    % 投资成本必须用「收紧 gap 后的这次调度」重算：储能寿命由本次调度的年放电量反算，
    % 两次求解的放电量可以差一点点，混用就会出现「汇总表与 Excel 差几块钱」的口径漂移。
    capex = gopt_annual_capex(cap, cfg, R);
    fit   = capex + R.cost;
    fprintf('\n[PSO] 检测到全部维度 lb = ub，跳过搜索，直接求内层最优调度。\n');
    fprintf(['[PSO] 固定配置 [PV %.4g | WT %.4g | Pess %.4g | Tess %.4g h | Gen %.4g MW]' ...
             ' -> 储能容量 %.4g MWh\n'], s(1), s(2), s(3), s(4), s(5), cap(4));
    out = gopt_pack_out(s, cap, fit, R, capex, 1, toc(tAll), [fit, fit], true, 0);
    out.boundLog  = {};
    out.stageInfo = gopt_stage_rec('固定配置（仅内层调度）', 1, toc(tAll), fit, '全维固定');
    out.hitBound  = false(nD, 1);
    out.twoStage  = false;
    return;
end

if any(~effFree)
    msg = '';
    for k = find(~effFree)'
        msg = [msg, sprintf('%s=%.4g  ', varName{k}, lbP(k))];   %#ok<AGROW>
    end
    fprintf('\n[PSO] 固定维度（lb = ub）：%s\n', strtrim(msg));
end

%% ---- 1. 阶段 A（可选）：典型日口径粗搜 ----
% 为什么值得多跑一遍便宜的模型：目标口径（默认全年 8760 h）单次内层 MILP 是分钟量级，
% 5 维空间里一百多次评估根本不够把「哪片区域可能最优」摸清；典型日口径把时域压缩成
% K x 24 h，单次评估快到可以忽略，于是能用几千次评估先把范围收窄，再回到目标口径精搜。
twoStage = gopt_pget(cfg.pso, 'twoStage', true) && nargin >= 3 && ~isempty(ds) && ~isempty(sc);
kA    = gopt_pget(cfg.pso, 'stageA', struct());
SA    = [];
lbBox = lbP;  ubBox = ubP;
bestX = lbP(:)';  bestFit = inf;  bestCap = [];  bestCapex = inf;

if twoStage
    cfgA = cfg;
    cfgA.time.mode         = 'typical_days';
    cfgA.time.nTypicalDays = gopt_pget(kA, 'K', 12);
    cfgA.io.quiet          = true;
    % 阶段 A 只负责「指路」，不做局部精修：精修放在阶段 B 的结果上做才有意义
    % （在典型日口径上把它修到极致，到了全年口径也未必是最优点，纯属浪费预算）。
    cfgA.pso.localRefine   = false;
    fprintf(['\n[PSO] 阶段 A（粗搜）：内层改用典型日口径（K = %d，%d h），' ...
             '先摸清「哪片区域可能最优」\n'], cfgA.time.nTypicalDays, 24 * cfgA.time.nTypicalDays);
    scA = gopt_build_scenario(ds, cfgA);
    [SA, logA] = gopt_stage_expand(cfgA, scA, lbBox, ubBox, lbP, ubP, effFree, ...
        gopt_pget(kA, 'nPop', 40), gopt_pget(kA, 'maxIter', 60), 'A', ...
        doBound && gopt_pget(kA, 'expand', true), expandFactor, expandMax, expandFree, boundFrac);
    logB  = [logB; logA(:)];
    nEval = nEval + SA.nEval;
    [histAll, bestSoFar] = gopt_hist_push(histAll, SA.hist, bestSoFar);
    stageInfo(end + 1) = gopt_stage_rec(sprintf('阶段A 典型日粗搜(K=%d)', cfgA.time.nTypicalDays), ...
        SA.nEval, SA.wall, SA.bestFit, sprintf('内层 %d h；搜索框 %d 轮', scA.T, SA.rounds));
    say('[PSO] 阶段 A 完成：%.2f 万元/年 @ [PV %.2f WT %.2f Pess %.2f Tess %.2f Gen %.2f]\n', ...
        SA.bestFit / 1e4, SA.bestX);
    % ---- 阶段 B 的起始框：以阶段 A 的解为中心收缩 ----
    xA   = SA.bestX(:);
    sh   = gopt_pget(kA, 'shrink', 0.5);
    half = sh * (ubP - lbP) / 2;
    lbBox = max(lbP, xA - half);
    ubBox = min(ubP, xA + half);
    % 收缩后必须仍留一个非退化区间：区间为零会让 PSO 一开始就贴界，外扩机制也救不回来
    tiny = 1e-3 * max(ubP - lbP, 1e-6);
    chg  = (ubBox - lbBox) < tiny;
    lbBox(chg) = max(lbP(chg), xA(chg) - tiny(chg) / 2);
    ubBox(chg) = min(ubP(chg), lbBox(chg) + tiny(chg));
    lbBox(~effFree) = lbP(~effFree);   ubBox(~effFree) = ubP(~effFree);
    say('[PSO] 阶段 B 起始框（以 A 解为中心、收缩到原区间宽度的 %.0f%%）：%s\n', sh * 100, ...
        strjoin(arrayfun(@(k) sprintf('%s[%.4g,%.4g]', varName{k}, lbBox(k), ubBox(k)), ...
        (1:nD)', 'UniformOutput', false)', ' '));
end

%% ---- 2. 阶段 B（目标口径精搜）----
fprintf('\n[PSO] %s：内层为目标口径 %s（%d h）\n', ...
    gopt_tern(twoStage, '阶段 B（精搜）', '单阶段搜索'), sc.mode, sc.T);
[SB, logB2] = gopt_stage_expand(cfg, sc, lbBox, ubBox, lbP, ubP, effFree, ...
    nPop, maxIt, gopt_tern(twoStage, 'B', 'S'), doBound, expandFactor, expandMax, expandFree, boundFrac);
logB  = [logB; logB2(:)];
nEval = nEval + SB.nEval;
[histAll, bestSoFar] = gopt_hist_push(histAll, SB.hist, bestSoFar);
stageInfo(end + 1) = gopt_stage_rec(sprintf('阶段B 目标口径 %s', sc.mode), ...
    SB.nEval, SB.wall, SB.bestFit, sprintf('内层 %d h；搜索框 %d 轮', sc.T, SB.rounds));
bestX = SB.bestX;  bestFit = SB.bestFit;  bestCap = SB.bestCap;  bestCapex = SB.bestCapex;
lb = SB.lbFinal;  ub = SB.ubFinal;

%% ---- 3. 局部精修完毕后的 Nelder-Mead 收尾（可选）----
% 为什么还要一步：PSO + Hooke-Jeeves 属于「方向型」搜索，步长对折到接近容差时仍可能
% 卡在步长网格上；单纯形法不依赖方向，能在最后再挤出一点精度。评估次数硬约束为
% 6 x 维度，避免它把预算吃掉。
refineN = SB.refineN;
if ~isempty(SA), refineN = refineN + SA.refineN; end
if gopt_pget(cfg.pso, 'refineNM', true) && any(effFree)
    fN0 = bestFit;
    [sN, fN, cxN, nNM] = gopt_nm_search(bestX, cfg, sc, lb, ub, 6 * nD);
    nEval = nEval + nNM;
    if isfinite(fN) && fN < bestFit - 1e-6
        bestX = sN;  bestFit = fN;  bestCapex = cxN;
        bestCap = [bestX(1); bestX(2); bestX(3); bestX(3) * bestX(4); bestX(5)];
    end
    say('[PSO] Nelder-Mead 收尾：%.2f -> %.2f 万元/年（%d 次评估）\n', ...
        fN0 / 1e4, bestFit / 1e4, nNM);
end

%% ---- 4. 最优点的完整调度结果（收紧求解间隙，保证最终代价精确）----
% 搜索阶段 relGap 放宽（默认 1e-4）以提速；最终必须收紧到 1e-7 复算一次，
% 否则「报表里的成本」与「搜索时的适应度」会差几十块钱，容易被误读成模型不一致。
wallAll  = toc(tAll);
cfgFinal = cfg;
cfgFinal.milp.relGap = min(cfg.milp.relGap, 1e-7);
R = gopt_milp(bestCap, sc, cfgFinal);
if ~R.ok
    error('最终配置下内层调度求解失败：%s', R.message);
end
bestCapex = gopt_annual_capex(bestCap, cfg, R);   % 用最终（更紧 gap）调度反算寿命
bestFit   = bestCapex + R.cost;
say(['[PSO] 结束：共评估 %d 次，用时 %.1f s；最优点按 relGap=%.1e 复算，' ...
     '精确总成本 %.2f 万元/年\n'], nEval, wallAll, cfgFinal.milp.relGap, bestFit / 1e4);

%% ---- 5. 最终解是否仍贴界（写进日志与 Excel，供判断「容量被界卡住」）----
% 这里刻意把「贴上界」与「取下限」分开报，因为两者的含义完全不同：
%   · 贴上界：结论可能由上界决定（真解在界外），需要外扩或放宽工程上界 —— 要警示；
%   · 取下限（= 0）：含义是「这个资产不该建」，这是正常的经济结论，不是搜索失败。
%   把两者混在一起会让人误以为模型没搜到最优。
hitB  = false(nD, 1);   % 任一维贴界（供 Excel 的记录用）
hitUp = false(nD, 1);   % 贴上界（真正需要关注的那一类）
nHit0 = numel(logB);
for k = 1:nD
    if ~effFree(k), continue; end
    sp = ub(k) - lb(k);
    if bestX(k) >= ub(k) - boundFrac * sp
        hitB(k) = true;  hitUp(k) = true;
        logB{end + 1} = sprintf('最终解：%s = %.4g 贴上界 %.4g（%s）', varName{k}, bestX(k), ub(k), ...
            gopt_tern(ub(k) < ubP(k) - 1e-12, '已外扩过，仍贴界', '已是物理界，无法再扩'));
    elseif bestX(k) <= lb(k) + boundFrac * sp
        hitB(k) = true;
        if k == 4
            % 储能时长是「派生维」，它取不取下限取决于储能功率是否为 0，
            % 不该按「不该建该资产」来解读，否则读者会以为「不要储能时长了」。
            logB{end + 1} = sprintf(['最终解：%s = %.4g 取下限 %.4g' ...
                '（储能功率为 0 时时长无意义，属派生结果，不是独立结论）'], ...
                varName{k}, bestX(k), lb(k));
        else
            logB{end + 1} = sprintf(['最终解：%s = %.4g 取下限 %.4g' ...
                '（容量为零 = 该资产不该建，一般属正常经济结论，不是搜索没搜到）'], ...
                varName{k}, bestX(k), lb(k));
        end
    end
end
if any(hitUp)
    fprintf('[PSO] ⚠ 最终解有 %d 个维度贴上界（结论可能由上界决定，详见 boundLog）：\n', sum(hitUp));
    for i = (nHit0 + 1):numel(logB)
        fprintf('       %s\n', logB{i});
    end
elseif any(hitB)
    fprintf('[PSO] 边界诊断：有 %d 个维度取下限（容量为零），其余维度都在区间内部。\n', sum(hitB));
    for i = (nHit0 + 1):numel(logB)
        fprintf('       %s\n', logB{i});
    end
else
    fprintf('[PSO] 边界诊断：最终解未贴任何搜索边界（各维度都落在区间内部）。\n');
end

stageInfo(end + 1) = gopt_stage_rec('局部精修 + Nelder-Mead', refineN, 0, bestFit, ...
    '精修评估次数见 nEval 字段');

out = gopt_pack_out(bestX, bestCap, bestFit, R, bestCapex, nEval, wallAll, histAll, false, refineN);
out.boundLog  = logB;
out.stageInfo = stageInfo;
out.hitBound  = hitB;
out.hitUpper  = hitUp;
out.twoStage  = twoStage;
end

%% ------------------------------------------------------------ PSO 单阶段内核
function S = gopt_pso_core(cfg, sc, lb, ub, effFree, nPop, maxIter, tag)
%GOPT_PSO_CORE  一个完整 PSO 阶段的迭代内核（不含边界外扩，外扩由 gopt_stage_expand 驱动）
%   输入  lb / ub  本轮搜索框（可小于物理界）；effFree 自由维掩码；
%         nPop / maxIter 本阶段预算；tag 日志前缀与随机流标签
%   输出  S 结构体：.bestX .bestFit .bestCap .bestCapex .hist .nEval .wall
%                   .nReset .nEscape .lb .ub

nD = 5;
[varName, varUnit] = gopt_varnames();     % 两处都要用：日志里既打名字也打单位
span = ub - lb;
isFix = ~effFree;
say = @(varargin) gopt_say(cfg, varargin{:});
if gopt_pget(cfg.pso, 'cacheEval', true)
    cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
else
    cache = [];
end

%% ---- 1. 初始化种群（升级版：LHS / 对立学习 / 混沌 可切换 + 保留确定性种子点）----
% 为什么升级：纯随机撒点在 5 维空间里经常“半边空着”（聚类成团、某些维度没铺开），
% 直接后果就是种群一开始就落在某个局部区域里，后面再难跳出来。拉丁超立方保证每一维
% 都被等分覆盖，对立学习再补一半镜像点，等价于用同样的评估预算把空间铺得更开。
rng(cfg.pso.seed, 'twister');
initMode = gopt_pget(cfg.pso, 'initMode', 'lhs_obl');
X = gopt_init_swarm(initMode, nPop, nD, lb, ub);

if gopt_pget(cfg.pso, 'keepSeeds', true)
    ds2 = gopt_pget(cfg.pso, 'durationSeed', cfg.ess.durationSeed);
    seedPts = [ ...
        lb';                                                                          % 全部取下限
        0,                   0,                   0,                   ds2, 0;          % 纯购电、无自发电
        ub(1),               ub(2),               0,                   ds2, ub(5);      % 满风光、满自发电、无储能
        0,                   0,                   ub(3),               ds2, 0;          % 满储能
        0.5*ub(1),           0.5*ub(2),           0.5*ub(3),           ds2, 0.5*ub(5);  % 中间点
        ub(1),               lb(2),               0,                   ds2, lb(5);      % 仅光伏
        lb(1),               ub(2),               0,                   ds2, lb(5);      % 仅风电
        ub(1),               ub(2),               ub(3),               ub(4), ub(5)];   % 全部取上限
    seedPts = min(max(seedPts, repmat(lb', size(seedPts, 1), 1)), repmat(ub', size(seedPts, 1), 1));
    nb = min(size(seedPts, 1), nPop);
    X(1:nb, :) = seedPts(1:nb, :);
end
if any(isFix), X(:, isFix) = repmat(lb(isFix)', nPop, 1); end

V    = zeros(nPop, nD);
vMax = (gopt_pget(cfg.pso, 'vMaxRate', 1.1) * span)';

% ---- 多种群分组（小生境）----
% 把种群拆成若干子群各自演化，约定每子群至少 3 个粒子；子群之间按 exchangeIt 周期
% 交换「群体最优」。好处是某个子群提前收敛到局部谷底时，其它子群还在别处找，
% 全局最优不会跟着一起被锁死。
nSw = round(gopt_pget(cfg.pso, 'multiSwarm', 1));
nSw = max(1, min(nSw, max(1, floor(nPop / 3))));
swId = mod((1:nPop)' - 1, nSw) + 1;

% ---- 自适应参数与各种机制的开关 ----
adaptive    = gopt_pget(cfg.pso, 'adaptive', true);
wMax        = gopt_pget(cfg.pso, 'wMax', 0.9);
wMin        = gopt_pget(cfg.pso, 'wMin', 0.4);
c1_0        = gopt_pget(cfg.pso, 'c1', 1.5);
c2_0        = gopt_pget(cfg.pso, 'c2', 1.5);
c1E         = gopt_pget(cfg.pso, 'c1End', 0.5);
c2E         = gopt_pget(cfg.pso, 'c2End', 2.5);
chi         = gopt_pget(cfg.pso, 'constriction', 0);
stallIter   = gopt_pget(cfg.pso, 'stallIter', 10);
tolCost     = gopt_pget(cfg.pso, 'tolCost', 1e-4);
exchangeIt  = max(1, round(gopt_pget(cfg.pso, 'exchangeIt', 8)));
resetFrac   = gopt_pget(cfg.pso, 'resetFrac', 0.1);
escapeTries = gopt_pget(cfg.pso, 'escapeTries', 2);
escapeAmp   = gopt_pget(cfg.pso, 'escapeAmp', 0.15);
useParallel = gopt_pget(cfg.pso, 'useParallel', false);
wShape      = gopt_pget(cfg.pso, 'wShape', 'concave');

say('\n[PSO|%s] 开始搜索：%d 粒子 x %d 代；子群 %d 个；初始化 %s；内层为 %d h 的 MILP 调度\n', ...
    tag, nPop, maxIter, nSw, initMode, sc.T);
say('[PSO|%s] 搜索框（储能容量 = 储能功率 x 储能时长）：\n', tag);
for k = 1:nD
    if isFix(k), ftxt = '  (固定)'; else, ftxt = ''; end
    say('        %-9s %10.4g ~ %-10.4g  %s%s\n', varName{k}, lb(k), ub(k), varUnit{k}, ftxt);
end
say('        储能容量   %10.4g ~ %-10.4g  MWh（由功率 x 时长推导）\n', lb(3)*lb(4), ub(3)*ub(4));
say('        自适应 w/c1/c2 = %d；逃逸重启 %d 次；每代重置最差 %.0f%%；子群交换周期 %d 代\n', ...
    double(adaptive), escapeTries, resetFrac * 100, exchangeIt);

nEval = 0;
hist     = zeros(maxIter + 1, 2);
bestX = lb(:)';  bestCap = [];  bestFit = inf;  bestCapex = inf;
nStall = 0;  nEscape = 0;  nReset = 0;  prevBest = inf;
pbest = zeros(nPop, nD);  pbestFit = inf(nPop, 1);  pbestCapex = inf(nPop, 1);
swBestX     = repmat(X(1, :), nSw, 1);
swBestFit   = inf(nSw, 1);
swBestCapex = inf(nSw, 1);

t0 = tic;
for it = 1:(maxIter + 1)

    % ---- 2.1 评估整个种群 ----
    %   capx 记录每个粒子的「年化投资成本」。必须从评估里带回来、不能事后用 cap 重算：
    %   投资成本里的储能寿命由本次调度（R）反算，重算时手上没有 R，就会悄悄退回
    %   日历寿命，于是适应度和报表变成两套口径（详见 gopt_annual_capex 的注释）。
    fit  = zeros(nPop, 1);
    caps = zeros(nPop, nD);
    capx = zeros(nPop, 1);
    if useParallel && isempty(cache)
        parf = zeros(nPop, 1);  parc = zeros(nPop, nD);  parcx = zeros(nPop, 1);
        parfor i = 1:nPop
            [parf(i), parc(i, :), parcx(i)] = gopt_eval_fit(X(i, :), cfg, sc, lb, ub, []);
        end
        fit = parf;  caps = parc;  capx = parcx;
    else
        for i = 1:nPop
            [fit(i), caps(i, :), capx(i)] = gopt_eval_fit(X(i, :), cfg, sc, lb, ub, cache);
        end
    end
    nEval = nEval + nPop;

    % ---- 2.2 个体最优 ----
    if it == 1
        pbest = X;  pbestFit = fit;  pbestCapex = capx;
    else
        imp = fit < pbestFit;
        pbest(imp, :) = X(imp, :);
        pbestFit(imp) = fit(imp);
        pbestCapex(imp) = capx(imp);
    end

    % ---- 2.3 子群最优（每个子群维护自己的 gbest，形成小生境）----
    for w = 1:nSw
        m  = (swId == w);
        idx = find(m);
        [mw, iw] = min(pbestFit(idx));
        if mw < swBestFit(w)
            swBestFit(w)   = mw;
            swBestX(w, :)  = pbest(idx(iw), :);
            swBestCapex(w) = pbestCapex(idx(iw));
        end
    end

    % ---- 2.4 全局最优 = 各子群最优里的最好 ----
    [gbFit, gi] = min(swBestFit);
    if gbFit < bestFit
        bestFit   = gbFit;
        bestX     = swBestX(gi, :);
        bestCapex = swBestCapex(gi);      % 与适应度同源的投资成本（含循环寿命与自发电口径）
        bestCap   = [bestX(1); bestX(2); bestX(3); bestX(3) * bestX(4); bestX(5)];
    end

    hist(it, 1) = bestFit;
    pf = pbestFit(isfinite(pbestFit));
    if isempty(pf), pf = bestFit; end
    hist(it, 2) = mean(pf);

    say(['[PSO|%s] 代 %3d/%3d | 总成本 %10.2f 万元/年 = 投资 %10.2f + 运行 %10.2f | ' ...
         '[PV %7.2f  WT %7.2f  Pess %7.2f  Tess %6.2f h  Gen %7.2f MW]\n'], ...
        tag, it - 1, maxIter, bestFit / 1e4, bestCapex / 1e4, (bestFit - bestCapex) / 1e4, bestX);

    if it > maxIter, break; end

    % ---- 2.5 停滞判定与逃逸重启 ----
    % 旧版一停滞就直接 break 早停，等于把「暂时没进展」当成「已经到最优」，是早熟收敛的
    % 直接原因。这里改成：先做若干次逃逸（对 gbest 加高斯扰动 + 重撒粒子），
    % 逃逸次数用尽后仍无改进才真早停。逃逸不延长预算（仍受 maxIter 约束）。
    escaped = false;
    if bestFit < prevBest * (1 - tolCost), nStall = 0;
    else,                                  nStall = nStall + 1;
    end
    prevBest = min(prevBest, bestFit);
    if nStall >= stallIter
        if nEscape < escapeTries
            nEscape = nEscape + 1;
            fprintf(['[PSO|%s]   停滞 %d 代 -> 第 %d/%d 次逃逸扰动（幅度 %.3g x 区间宽）\n'], ...
                tag, nStall, nEscape, escapeTries, escapeAmp);
            Xp = repmat(bestX, nPop, 1) + (escapeAmp * span') .* randn(nPop, nD);
            Xp = min(max(Xp, repmat(lb', nPop, 1)), repmat(ub', nPop, 1));
            if any(isFix), Xp(:, isFix) = repmat(lb(isFix)', nPop, 1); end
            X = Xp;  V = zeros(nPop, nD);
            pbestFit(:) = inf;      % 重新认领个体最优；bestFit / bestX 不回退（已评估过的真解）
            nStall  = 0;
            escaped = true;
        else
            fprintf('[PSO|%s] 连续 %d 代无显著改进且逃逸次数用尽，提前收敛。\n', tag, nStall);
            hist = hist(1:it, :);
            break;
        end
    end

    % ---- 2.6 速度 / 位置更新（w、c1、c2 随代数自适应）----
    frac = (it - 1) / max(maxIter, 1);
    if adaptive
        if strcmpi(wShape, 'concave')
            w = wMin + (wMax - wMin) * (1 - frac)^2;   % 凹函数递减：前中期保探索，后期收敛更彻底
        else
            w = wMax - (wMax - wMin) * frac;
        end
        c1 = c1_0 + (c1E - c1_0) * frac;               % 个体学习减弱
        c2 = c2_0 + (c2E - c2_0) * frac;               % 群体学习增强
    else
        w  = wMax - (wMax - wMin) * frac;
        c1 = c1_0;  c2 = c2_0;
    end
    for i = 1:nPop
        r1 = rand(1, nD);  r2 = rand(1, nD);
        swB = swBestX(swId(i), :);       % 粒子跟随「自己子群」的 gbest（小生境）
        V(i, :) = w * V(i, :) ...
                + c1 * r1 .* (pbest(i, :) - X(i, :)) ...
                + c2 * r2 .* (swB - X(i, :));
        if chi > 0, V(i, :) = chi * V(i, :); end      % 可选收缩因子
        V(i, :) = min(max(V(i, :), -vMax), vMax);
        X(i, :) = min(max(X(i, :) + V(i, :), lb'), ub');
        if any(isFix), X(i, isFix) = lb(isFix)'; end
    end

    % ---- 2.7 重置最差粒子（抑制早熟；逃逸那一代跳过，免得把刚撒开的扰动又抹掉）----
    nr = round(resetFrac * nPop);
    if nr > 0 && ~escaped
        [~, ord] = sort(pbestFit, 'descend');
        idxR = ord(1:min(nr, nPop));
        X(idxR, :) = gopt_init_swarm(initMode, numel(idxR), nD, lb, ub);
        V(idxR, :) = 0;
        pbestFit(idxR) = inf;      % 下次评估时重新认领
        if any(isFix), X(idxR, isFix) = repmat(lb(isFix)', numel(idxR), 1); end
        nReset = nReset + numel(idxR);
    end

    % ---- 2.8 子群间信息迁移：把「最差的几个子群」的 gbest 换成全局最优 ----
    % 只替换一半（向下取整）而不是全部：全替换会让所有子群同时被吸到同一点，多样性归零。
    if nSw > 1 && mod(it, exchangeIt) == 0 && isfinite(bestFit)
        [~, ws] = sort(swBestFit, 'descend');
        for q = 1:max(1, floor(nSw / 2))
            sw = ws(q);
            swBestX(sw, :)  = bestX;
            swBestFit(sw)   = bestFit;
            swBestCapex(sw) = bestCapex;
        end
    end
end

%% ---- 3. 局部精修（Hooke-Jeeves 式加速步长 + 随机方向；可选 Nelder-Mead 收尾）----
% 相对旧版的改进：
%   (1) 除坐标方向外，再补几条随机方向 —— 旧版只在坐标轴上探，遇到「斜谷」
%       （两个维度同时变化才能下降）就会一直对折步长直到放弃；
%   (2) 成功移动后做一次「模式移动」（沿净位移再走一倍），这是 Hooke-Jeeves 的加速步，
%       能把沿着谷底的长距离爬升压缩成少数几步；
%   (3) 方向顺序随机化（仍受 rng(seed) 约束，结果可复现）；
%   (4) 全部评估仍走带缓存的 gopt_eval_fit，重复点不重新求解 MILP。
refineN = 0;
if gopt_pget(cfg.pso, 'localRefine', true) && any(effFree)
    method = gopt_pget(cfg.pso, 'refineMethod', 'hj');
    fitR0  = bestFit;
    step   = cfg.pso.refineStep0 * span;
    tolS   = max(cfg.pso.refineTolRel * span, 1e-9);
    maxRef = gopt_pget(cfg.pso, 'refineMaxEval', 200);
    s = bestX(:)';
    nRound = 0;
    fprintf('\n[PSO|%s] 局部精修（%s）：步长 %.3g x 区间宽 -> %.3g x 区间宽，评估上限 %d 次\n', ...
        tag, method, cfg.pso.refineStep0, cfg.pso.refineTolRel, maxRef);
    while any(step(effFree) > tolS(effFree)) && nRound < 400 && refineN < maxRef
        nRound = nRound + 1;
        improved = false;
        sPrev = s;
        % ---- 方向集合：坐标方向 + （hj 模式）若干随机方向 ----
        dirs = zeros(0, nD);
        for kk = 1:nD
            if ~effFree(kk), continue; end
            d = zeros(1, nD);  d(kk) = 1;  dirs(end + 1, :) = d;   %#ok<AGROW>
        end
        if strcmpi(method, 'hj')
            for q = 1:3
                dr = randn(1, nD);  dr(~effFree) = 0;
                if norm(dr) > 0, dirs(end + 1, :) = dr / norm(dr); end   %#ok<AGROW>
            end
        end
        dirs = dirs(randperm(size(dirs, 1)), :);
        for q = 1:size(dirs, 1)
            d = dirs(q, :);
            for sgn = [1, -1]
                % 括号里的 (step(:)') 不能省：step 是 5x1 列向量、d 是 1x5 行向量，
                % 直接写 step .* d 会被 MATLAB 的隐式扩展当成外积，变成 5x5 矩阵，
                % 后面传进 gopt_eval_fit 就会报「数组大小不兼容」。
                st = s + sgn * (step(:)' .* d);
                st = min(max(st, lb(:)'), ub(:)');
                if max(abs(st - s)) < 1e-12, continue; end
                [f2, c2, cx2] = gopt_eval_fit(st, cfg, sc, lb, ub, cache);
                refineN = refineN + 1;  nEval = nEval + 1;
                if f2 < bestFit - 1e-6
                    s = st;  bestFit = f2;  bestCap = c2;  bestCapex = cx2;
                    improved = true;
                end
                if refineN >= maxRef, break; end
            end
            if refineN >= maxRef, break; end
        end
        % ---- 模式移动：沿本轮的净位移再走一倍（Hooke-Jeeves 的加速步）----
        if improved && strcmpi(method, 'hj')
            st = s + (s - sPrev);
            st = min(max(st, lb(:)'), ub(:)');
            if max(abs(st - s)) > 1e-12
                [f3, c3, cx3] = gopt_eval_fit(st, cfg, sc, lb, ub, cache);
                refineN = refineN + 1;  nEval = nEval + 1;
                if f3 < bestFit - 1e-6
                    s = st;  bestFit = f3;  bestCap = c3;  bestCapex = cx3;
                end
            end
        end
        if ~improved, step = step / 2; end
    end
    bestX = s;
    say(['[PSO|%s] 精修结束：%d 轮 / %d 次评估，总成本 %.2f -> %.2f 万元/年（改善 %.2f 万元）\n'], ...
        tag, nRound, refineN, fitR0 / 1e4, bestFit / 1e4, (fitR0 - bestFit) / 1e4);
end
wall = toc(t0);

%% ---- 4. 打包本阶段结果（最终点的严格复算与 Nelder-Mead 收尾放在驱动层）----
S = struct();
S.bestX     = bestX;
S.bestFit   = bestFit;
S.bestCap   = bestCap;
S.bestCapex = bestCapex;
S.hist      = hist;
S.nEval     = nEval;
S.wall      = wall;
S.nReset    = nReset;
S.nEscape   = nEscape;
S.refineN   = refineN;
S.lb        = lb;
S.ub        = ub;
say('[PSO|%s] 本阶段结束：共评估 %d 次，用时 %.1f s，阶段最优 %.2f 万元/年\n', ...
    tag, nEval, wall, bestFit / 1e4);
end

%% ------------------------------------------------- PSO 辅助函数（边界/初始化/收尾）
function [varName, varUnit] = gopt_varnames()
%GOPT_VARNAMES  5 维优化变量的名字与单位（口径只定义一次，避免多处硬编码漂移）
varName = {'PV(MW)', 'WT(MW)', 'Pess(MW)', 'Tess(h)', 'Gen(MW)'};
varUnit = {'MW', 'MW', 'MW', 'h', 'MW'};
end

function r = gopt_stage_rec(name, nEval, wall, fit, note)
%GOPT_STAGE_REC  阶段/环节记账（写进日志与 Excel「PSO收敛」表）
r = struct('name', name, 'nEval', nEval, 'wall', wall, 'fit', fit, 'note', note);
end

function [histAll, bestSoFar] = gopt_hist_push(histAll, h, bestSoFar)
%GOPT_HIST_PUSH  把一轮（或一阶段）的收敛历史接到总历史上
%   第一列统一成「至今最优」：跨阶段、跨外扩轮次时曲线保持单调不升，
%   不会因为「新一阶段的起点比上一阶段终点差」而出现向上的假跳变（那会让人误读成发散）。
%   第二列保留该轮自己的种群均值，仍能反映多样性。
if isempty(h), return; end
h(:, 1)  = min(cummin(h(:, 1)), bestSoFar);
bestSoFar = h(end, 1);
histAll   = [histAll; h];
end

function v = gopt_pget(ps, name, def)
%GOPT_PGET  读 cfg.pso 里的可选参数（字段缺失或为空时取默认值，保证旧 cfg 仍能跑）
v = def;
if nargin >= 1 && isstruct(ps) && isfield(ps, name) && ~isempty(ps.(name))
    v = ps.(name);
end
end

function [S, logB] = gopt_stage_expand(cfgS, scS, lb, ub, lbP, ubP, effFree, ...
        nPop, maxIter, tag, doExp, expandFactor, expandMax, expandFree, boundFrac)
%GOPT_STAGE_EXPAND  在一个搜索框内跑完 PSO 阶段；若最优解贴上界，则推远上界后重启一轮
%
%  为什么需要它：搜索上界常常是「人为给的」，真解可能就在界外。上一版实测最优解
%  光伏 = 50 MW = ub、风电 = 2 MW = lb，双向贴界 —— 此时无论如何迭代都只是在边界上
%  打转，这就是「陷入局部最优」最常见的成因。
%
%  外扩规则：
%    · 只对 effFree（自由维）且 expandFree（允许外扩）的维度生效；
%    · 上界不超过物理界 ubP，下界不低于 lbP；
%    · 自发电容量与储能时长是工程硬界（expandFree = false），永不外扩 ——
%      自发电尤其不能放开：它的度电成本远低于购电，解天然会往上界跑，
%      放开外扩会一路加容量到毫无工程意义。
%    · 已经贴在物理界上时不再外扩，只在日志里如实记录，供人判断该上界是否合理。
[varName, ~] = gopt_varnames();
logB   = {};
rounds = 0;
S = struct('bestX', lb(:)', 'bestFit', inf, 'bestCap', [], 'bestCapex', inf, ...
           'hist', [], 'nEval', 0, 'wall', 0, 'nReset', 0, 'nEscape', 0, 'refineN', 0, ...
           'rounds', 0, 'hitHi', false(5, 1), 'hitLo', false(5, 1), ...
           'lbFinal', lb, 'ubFinal', ub);
while true
    Sr = gopt_pso_core(cfgS, scS, lb, ub, effFree, nPop, maxIter, tag);
    S.nEval = S.nEval + Sr.nEval;   % 多轮时累计（预算口径：总评估次数才是耗时来源）
    S.wall  = S.wall  + Sr.wall;
    if ~isfinite(Sr.bestFit) || Sr.bestFit < S.bestFit
        S.bestX = Sr.bestX;  S.bestFit = Sr.bestFit;
        S.bestCap = Sr.bestCap;  S.bestCapex = Sr.bestCapex;
    end
    S.hist   = [S.hist; Sr.hist];
    S.nReset = S.nReset + Sr.nReset;
    S.nEscape= S.nEscape + Sr.nEscape;
    S.refineN= S.refineN + Sr.refineN;
    rounds   = rounds + 1;
    if ~doExp || rounds > expandMax, break; end
    span  = ub - lb;
    hitHi = effFree(:) & expandFree(:) & (S.bestX(:) >= ub(:) - boundFrac * span(:));
    hitLo = effFree(:) & expandFree(:) & (S.bestX(:) <= lb(:) + boundFrac * span(:));
    grew  = false;
    for k = find(hitHi)'
        if ub(k) < ubP(k) - 1e-12
            ubNew = min(ubP(k), max(ub(k) * expandFactor, ub(k) + 0.1 * (ubP(k) - ub(k))));
            logB{end + 1} = sprintf('阶段%s 第 %d 轮：%s 贴上界 %.4g -> 上界外扩到 %.4g%s', ...
                tag, rounds, varName{k}, ub(k), ubNew, ...
                gopt_tern(ubNew >= ubP(k) - 1e-12, '（已达物理界）', ''));   %#ok<AGROW>
            fprintf('[PSO|%s] 边界诊断：%s\n', tag, logB{end});
            ub(k) = ubNew;  grew = true;
        else
            logB{end + 1} = sprintf('阶段%s 第 %d 轮：%s 贴在物理上界 %.4g（工程硬界，不外扩）', ...
                tag, rounds, varName{k}, ub(k));                             %#ok<AGROW>
            fprintf('[PSO|%s] 边界诊断：%s\n', tag, logB{end});
        end
    end
    for k = find(hitLo)'
        if lb(k) > lbP(k) + 1e-12
            lbNew = max(lbP(k), lb(k) - expandFactor * (ub(k) - lb(k)));
            logB{end + 1} = sprintf('阶段%s 第 %d 轮：%s 贴下界 %.4g -> 下界外扩到 %.4g', ...
                tag, rounds, varName{k}, lb(k), lbNew);                      %#ok<AGROW>
            fprintf('[PSO|%s] 边界诊断：%s\n', tag, logB{end});
            lb(k) = lbNew;  grew = true;
        end
    end
    if ~grew, break; end
    fprintf('[PSO|%s] 搜索框已外扩，在新框内重启第 %d 轮搜索。\n', tag, rounds + 1);
end
S.rounds   = rounds;
S.hitHi    = S.bestX(:) >= ub(:) - boundFrac * (ub(:) - lb(:));
S.hitLo    = S.bestX(:) <= lb(:) + boundFrac * (ub(:) - lb(:));
S.lbFinal  = lb;
S.ubFinal  = ub;
S.logB     = logB;
end

function X = gopt_init_swarm(mode, nPop, nD, lb, ub)
%GOPT_INIT_SWARM  种群初始化（可切换采样方式）
%   'lhs'     拉丁超立方：每一维都按 nPop 等分层、层内随机，保证维度方向被均匀覆盖
%   'lhs_obl' 默认：拉丁超立方 + 对立学习（镜像点 lb+ub-x）。同样的评估预算下，
%             对立点对「最优解偏向某一侧」的问题特别有效，能把搜索空间铺得更开
%   'chaos'   混沌映射（Logistic），适合维度间存在奇异吸引子形态的情形
%   'random'  纯随机（旧版行为）
lb = lb(:)';  ub = ub(:)';  span = ub - lb;
switch lower(char(mode))
    case 'lhs'
        U = gopt_lhs(nPop, nD);
    case 'lhs_obl'
        nh = ceil(nPop / 2);
        Uh = gopt_lhs(nh, nD);
        U  = [Uh; 1 - Uh];
        U  = U(1:nPop, :);
    case 'chaos'
        U = gopt_chaos(nPop, nD);
    otherwise
        U = rand(nPop, nD);
end
X = repmat(lb, nPop, 1) + U .* repmat(span, nPop, 1);
end

function U = gopt_lhs(n, d)
%GOPT_LHS  拉丁超立方采样：每一维都是 n 个等分层的随机排列
U = zeros(n, d);
for k = 1:d
    U(:, k) = ((randperm(n)' - 1) + rand(n, 1)) / n;
end
end

function U = gopt_chaos(n, d)
%GOPT_CHAOS  Logistic 混沌序列（x <- 4x(1-x)），最后按秩变换铺回 [0,1]
%   为什么还要秩变换：混沌序列本身分布不均匀（两端稀疏、中部密集），直接当均匀采样用
%   会让某些区间根本没点；秩变换后每一维都严格均匀，且仍保留序列的遍历性。
U = zeros(n, d);
for k = 1:d
    x = 0.13 + 0.7 * rand();
    for i = 1:n
        x = 4 * x * (1 - x);
        U(i, k) = x;
    end
    [~, ord]  = sort(U(:, k));
    U(ord, k) = ((1:n)' - 0.5) / n;
end
end

function [sBest, fBest, capexBest, nEval] = gopt_nm_search(s0, cfg, sc, lb, ub, maxFe)
%GOPT_NM_SEARCH  用 Nelder-Mead（fminsearch）做收尾精修
%   · 变量先归一化到 [0,1]：各维量纲相差百倍（MW vs h）时不归一化会让单纯形严重退化；
%   · 越界点由 gopt_eval_fit 内部裁剪回框内，等价于在「盒子」上做无约束极小化；
%   · 评估次数上限 maxFe（调用方给 6 x 维度），避免收尾吃掉搜索预算；
%   · 返回「过程中见过的最好点」而不是 fminsearch 的终值 —— 单纯形在收敛末期会反弹，
%     终值有时比中途见过的点更差。
nEval = 0;
sBest = s0(:)';  fBest = inf;  capexBest = inf;
if gopt_pget(cfg.pso, 'cacheEval', true)
    cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
else
    cache = [];
end

    function f = obj(z)
        % 归一化坐标 z 可能被单纯形推到 [0,1] 之外，必须先裁剪回搜索框再评估，
        % 且**存下来的也必须是裁剪后的点**：gopt_eval_fit 内部虽然会裁剪，但它只影响
        % 评估用的 cap，不会改变传进去的 s。若这里存的是未裁剪的 s，最终 bestCap 里
        % 就会出现负容量，gopt_milp 会直接报「容量不能为负」。
        s = lb(:)' + z .* (ub(:)' - lb(:)');
        s = min(max(s, lb(:)'), ub(:)');
        [f, ~, cx] = gopt_eval_fit(s, cfg, sc, lb, ub, cache);
        nEval = nEval + 1;
        if f < fBest
            sBest = s;  fBest = f;  capexBest = cx;
        end
    end

x0 = (sBest - lb(:)') ./ max(ub(:)' - lb(:)', 1e-12);
try
    o = optimset('MaxFunEvals', max(maxFe, 10), 'MaxIter', max(maxFe, 10), ...
        'Display', 'off', 'TolFun', 1e-3, 'TolX', 1e-3);
    fminsearch(@obj, x0, o);
catch
    % 万一环境里没有 fminsearch（正常不该发生），不要让整轮搜索失败：
    % 保持 fBest = inf，调用方只会在「严格更优」时才接受，等于自动跳过这一步。
end
if ~isfinite(fBest), sBest = s0(:)'; end
end

%% ---------------------------------------------------------- 结果打包
function out = gopt_pack_out(s, cap, fit, R, capexTotal, nEval, wall, hist, fixedMode, refineN)
out = struct();
out.s         = s(:)';
out.cap       = cap(:);
out.fit       = fit;
out.costOp    = R.cost;
out.costCapex = capexTotal;
out.R         = R;
out.nEval     = nEval;
out.wall      = wall;
out.hist      = hist;
out.fixedMode = fixedMode;
out.refineN   = refineN;
% ---- 本轮新增：搜索过程的诊断信息（供日志与 Excel「PSO收敛」表使用）----
out.boundLog  = {};          % 边界诊断与外扩记录（字符串 cell）
out.stageInfo = [];          % 各阶段/环节的评估次数与耗时
out.hitBound  = false(5, 1); % 最终解在哪些维度贴界（含取下限）
out.hitUpper  = false(5, 1); % 最终解在哪些维度贴上界（结论可能由上界决定）
out.twoStage  = false;       % 是否走了两阶段搜索
end

%% ============================================================ 绘图（SCI）
function gopt_plots(res, sc, scw, Rw, cfg, STACK)
%GOPT_PLOTS  出图（SCI 论文格式 + Okabe-Ito 色盲友好配色）
%   输出（cfg.path.outDir）：
%     fig_pso_convergence          外层搜索收敛曲线
%     fig_cost_breakdown           成本构成（单位 万元/年，柱顶标注数值）
%     fig_typical_week             典型周：出力堆叠图 / 储能充放电 / SOC 与电价
%     --- 典型日曲线：两种时间尺度模式都会输出 ---
%     fig_typical_days_source      典型日源荷曲线          （typical_days 模式）
%     fig_typical_days_dispatch    典型日出力堆叠图        （typical_days 模式）
%     fig_typical_days_soc         典型日 SOC              （typical_days 模式）
%     fig_fy_source                典型日源荷曲线          （full_year 模式）
%     fig_fy_dispatch              典型日出力堆叠图        （full_year 模式）
%     fig_fy_soc                   典型日 SOC              （full_year 模式）
%   两套文件名前缀不同、互不覆盖：typical_days 画的是「典型日场景」（簇内代表曲线），
%   full_year 画的是「真实代表日」（sc.plotRanges 指向的那一天在 8760 h 结果里的 24 h），
%   因此可以把两种口径的同一张图并排对照，判断时域压缩带来的差异。
%
%   图种开关：cfg.out.plotFigures.<pso|source|dispatch|soc|week|cost> = true/false，
%             逐张控制是否生成（字段缺失视为 true，向后兼容）。source/dispatch/soc
%             三项对两种时间尺度模式同时生效。
%   选日：cfg.out.plotDays 按典型日编号（编号已按 cfg.time.typDaySort 的日期键升序），
%         cfg.out.plotWhichDays 按自然日区间 [[起 止]; ...]（判据为簇内成员占比）；
%         两者串联取交集。两种模式含义完全一致。
%
%   「出力堆叠图」口径（STACK 结构体控制）：
%     零轴上方（自下而上）：储能放电 / 风电 / 光伏 / 自发电 / 购电
%     零轴下方（自上而下）：储能充电 / 售电 / 弃风弃光
%     叠加黑色负荷曲线；正上方堆叠总高 - 负下方深度 = 负荷（能量守恒直观可见）
%     各色块透明度由 STACK.alpha 控制（默认 0.78），便于观察重叠边界。
%     纵轴留白比例由 cfg.out.padFrac 控制，四张图（源荷 / 出力堆叠 / SOC 之外的
%     典型周两格）一律走 gopt_ylim_pad 显式设 ylim —— 详见该函数的注释。
%
%   fig_pro_metrics：专业化指标对比（默认关闭，cfg.out.plotFigures.proMetrics），
%     只把 res.pro 里的数字画成柱子，数值与命令行 9c / Excel「专业指标」表同源。

if nargin < 6 || isempty(STACK)
    STACK = struct('alpha', 0.78, 'barWidth', 1.00, 'showLoad', true, 'showNet', false);
end

if ~exist(cfg.path.outDir, 'dir'), mkdir(cfg.path.outDir); end

P = gopt_palette();
S = gopt_labels(cfg.out.figLang);
lw = cfg.out.lineWidth;
ms = 3.0;
nFig = 0;    % 实际生成的图数（用于末尾提示）

%% ---------- 1. PSO 收敛 ----------
% 每张图由 cfg.out.plotFigures.<名> 独立开关控制；字段缺失时默认生成（向后兼容）。
if gopt_flag(cfg, 'pso')
    f = gopt_newfig(8.8, 6.2);
    ax = axes(f); hold(ax, 'on');
    h = res.hist;
    x = (0:size(h, 1) - 1)';
    plot(ax, x, h(:, 1) / 1e4, '-o', 'Color', P.blue, 'LineWidth', lw, ...
        'MarkerSize', ms, 'MarkerFaceColor', P.blue, 'MarkerEdgeColor', 'none');
    if size(h, 2) >= 2
        plot(ax, x, h(:, 2) / 1e4, '-s', 'Color', P.verm, 'LineWidth', lw*0.85, ...
            'MarkerSize', ms, 'MarkerFaceColor', P.verm, 'MarkerEdgeColor', 'none');
    end
    xlabel(ax, S.iter);  ylabel(ax, S.costY);
    legend(ax, {S.gbest, S.gmean}, 'Location', 'northeast', 'Box', 'off');
    gopt_style(ax, S, cfg);
    gopt_save(f, 'fig_pso_convergence', cfg);
    nFig = nFig + 1;
end

%% ---------- 2~4. 典型日（两种时间尺度模式都会出图）----------
%   typical_days：调度场景本身就是 24K h 的典型日，直接画；
%   full_year   ：调度场景是 8760 h，这里画的是 sc.plotRanges 指定的「真实代表日」那 24 h，
%                 曲线全部取自全年优化结果（功率平衡与 SOC 演化可逐点核对）。
%   两种模式的文件名前缀不同（fig_typical_days_* / fig_fy_*），因此可以并存、互不覆盖，
%   方便把「典型日口径」与「全年口径」的同一张图摆在一起对照。
if ~isempty(sc.typDay)
    K = numel(sc.typDay);
    daySel = 1:K;
    if strcmpi(sc.mode, 'full_year')
        pfxDay = 'fig_fy_';
    else
        pfxDay = 'fig_typical_days_';
    end

    % 筛选器 1：按「典型日编号」（cfg.out.plotDays，如 1:4）
    %   编号已按 cfg.time.typDaySort 指定的日期键升序重排，两种模式含义一致
    if ~isempty(cfg.out.plotDays)
        daySel = daySel(ismember(daySel, cfg.out.plotDays(:)'));
    end

    % 筛选器 2：按「自然日区间」（cfg.out.plotWhichDays，每行一个 [起 止]）
    %   判据：该典型日内落在任一区间内的成员天数占比 >= cfg.out.plotWhichMinFrac。
    %   用占比而不是「命中任意一天」——因为聚类本身不含时间约束，多数簇跨全年，
    %   只要命中一天就保留的规则会让筛选形同虚设。
    wd = cfg.out.plotWhichDays;
    if ~isempty(wd)
        assert(size(wd, 2) == 2, ...
            'cfg.out.plotWhichDays 必须是 N x 2 矩阵（每行 [起始日 结束日]）。');
        fracMin = 0.20;
        if isfield(cfg.out, 'plotWhichMinFrac') && ~isempty(cfg.out.plotWhichMinFrac)
            fracMin = cfg.out.plotWhichMinFrac;
        end
        if ~isfield(sc.typDay, 'members') || isempty(sc.typDay(1).members)
            warning('sc.typDay 缺少 members 字段，cfg.out.plotWhichDays 已忽略。');
        else
            keep = false(numel(daySel), 1);
            if ~cfg.io.quiet
                fprintf('[绘图] 按自然日区间筛选典型日（阈值 %.0f%%）：\n', fracMin * 100);
            end
            for i = 1:numel(daySel)
                mem = sc.typDay(daySel(i)).members(:);
                inR = false(size(mem));
                for rr = 1:size(wd, 1)
                    inR = inR | (mem >= wd(rr, 1) & mem <= wd(rr, 2));
                end
                frac = sum(inR) / max(numel(mem), 1);
                keep(i) = frac >= fracMin;
                if ~cfg.io.quiet
                    fprintf('       典型日%-2d : 命中 %3d / %3d 天 = %5.1f%%  ->  %s\n', ...
                        daySel(i), sum(inR), numel(mem), frac * 100, ...
                        gopt_tern(keep(i), '保留', '剔除'));
                end
            end
            daySel = daySel(keep);
        end
    end

    Ks = numel(daySel);
    if Ks == 0
        warning(['典型日筛选结果为 0 天（cfg.out.plotDays / plotWhichDays 过窄），' ...
            '已跳过全部典型日绘图。']);
    end
    nc = max(ceil(sqrt(max(Ks, 1))), 1);
    nr = max(ceil(Ks / nc), 1);
    hr = 1:24;
    W  = 17.5;
    % 行高与留白：子图标题已简化为单行（见 gopt_daylabels），故每行预留高度相应收紧
    % （旧版为两行标题留 2.75/2.55/2.25 cm）；顶部仍留一行放横向图例。
    H  = max(2.45 * nr + 3.9, 7.0);     % 出力堆叠图（行高最大：图例 + 零轴）
    labs = gopt_daylabels(sc, daySel, cfg.out.figLang);

    % --- 2. 源荷曲线 ---
    if gopt_flag(cfg, 'source') && Ks > 0
        f = gopt_newfig(W, max(2.30 * nr + 3.7, 7.0));
        tl = tiledlayout(f, nr, nc, 'TileSpacing', 'compact', 'Padding', 'compact');
        ax1 = [];  hsLg = [];  nmLg = {};
        for j = 1:Ks
            k = daySel(j);
            ax = nexttile(tl); hold(ax, 'on');
            r = gopt_plot_range(sc, k);
            ld = sc.load(r); pv = res.cap(1) * sc.PV(r); wt = res.cap(2) * sc.WT(r);
            genMW = res.cap(5) * sc.Gen(r);     % ★ 自发电：标幺 x 容量，才是 MW
            % 源侧用半透明面积、荷侧用实线，方便看出「源 vs 荷」的相对大小
            h1 = gopt_fillband(ax, hr, pv, P.orange, STACK.alpha);
            h2 = gopt_fillband(ax, hr, wt, P.sky,    STACK.alpha);
            h3 = plot(ax, hr, ld, '-',  'Color', P.black,  'LineWidth', lw);
            h4 = plot(ax, hr, ld - pv - wt - genMW, '--', 'Color', P.blue, 'LineWidth', lw*0.9);
            % 显式设纵轴：填充带顶（光伏/风电峰值）与负荷曲线的极值经常正好落在自动
            % 纵轴的整数刻度上，贴边后被框线压住（原因见 gopt_ylim_pad）。
            % 本面板没有堆叠柱，[0 0] 只作占位，真正决定范围的是 extra 里的四条数据。
            gopt_ylim_pad(ax, [0 0], [pv; wt; ld; ld - pv - wt - genMW], STACK, cfg);
            xlim(ax, [0.5 24.5]);
            title(ax, labs{j}, 'FontSize', cfg.out.figFontSize);
            gopt_style(ax, S, cfg);
            if j == 1
                ax1 = ax;  hsLg = [h1, h2, h3, h4];  nmLg = {S.pv, S.wt, S.load, S.net};
            end
        end
        if ~isempty(ax1)
            lg = legend(ax1, hsLg, nmLg, 'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
            lg.ItemTokenSize = [12 8];
            try, lg.Orientation = 'horizontal'; end
            try, lg.Layout.Tile = 'north';      end
        end
        xlabel(tl, S.t, 'FontName', S.font, 'FontSize', cfg.out.figTitleSize);
        ylabel(tl, S.p, 'FontName', S.font, 'FontSize', cfg.out.figTitleSize);
        title(tl, sprintf('%s  (PV = %.2f MW, Wind = %.2f MW)', ...
            gopt_t(cfg.out.figLang, 'srctitle'), res.cap(1), res.cap(2)), ...
            'FontName', S.font, 'FontSize', cfg.out.figTitleSize, 'FontWeight', 'bold');
        gopt_save(f, [pfxDay 'source'], cfg);
        nFig = nFig + 1;
    end

    % --- 3. 出力堆叠图（常规新能源电站口径）---
    if gopt_flag(cfg, 'dispatch') && Ks > 0
        f = gopt_newfig(W, H);
        tl = tiledlayout(f, nr, nc, 'TileSpacing', 'compact', 'Padding', 'compact');
        ax1 = [];  hsLg = [];  nmLg = {};
        for j = 1:Ks
            k = daySel(j);
            ax = nexttile(tl); hold(ax, 'on');
            r = gopt_plot_range(sc, k);
            % 注意：这里必须传**整条**自发电曲线（标幺 × 容量），不能先按 r 切片 ——
            % gopt_stack_pack 内部还会用同一条 r 索引它（Gen(idx)），先切片会变成二次索引。
            [Yp, Yn, Cp, Cn, Lp, Ln] = gopt_stack_pack(res.R, r, res.cap(5) * sc.Gen, P, S);
            [hb, ext] = gopt_draw_stack(ax, hr, Yp, Yn, Cp, Cn, STACK);
            hl = [];  yExtra = [];          % yExtra 收集「除堆叠柱外还要纳入纵轴包络的曲线」
            if STACK.showLoad
                hl = plot(ax, hr, sc.load(r), '-', 'Color', P.black, 'LineWidth', lw);
                yExtra = sc.load(r);
            end
            if STACK.showNet
                netL = sc.load(r) - res.cap(1)*sc.PV(r) - res.cap(2)*sc.WT(r) - res.cap(5)*sc.Gen(r);
                yExtra = [yExtra; netL];
                plot(ax, hr, netL, '--', 'Color', P.grey, 'LineWidth', lw*0.9);
            end
            yline(ax, 0, '-', 'Color', [0.20 0.20 0.20], 'LineWidth', cfg.out.axisLineWidth);
            % 显式设纵轴：不能靠自动，否则柱顶/柱底会与坐标框线重合（见 gopt_ylim_pad）
            gopt_ylim_pad(ax, ext, yExtra, STACK, cfg);
            xlim(ax, [0.5 24.5]);
            title(ax, labs{j}, 'FontSize', cfg.out.figFontSize);
            gopt_style(ax, S, cfg);
            if j == 1
                ax1 = ax;  hsLg = hb;  nmLg = [Lp(:)', Ln(:)'];
                if STACK.showLoad, hsLg = [hsLg, hl];  nmLg = [nmLg, {S.load}]; end
            end
        end
        if ~isempty(ax1) && ~isempty(hsLg)
            lg = legend(ax1, hsLg, nmLg, 'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
            lg.ItemTokenSize = [12 8];
            try, lg.Orientation = 'horizontal'; end
            try, lg.Layout.Tile = 'north';      end
        end
        xlabel(tl, S.t, 'FontName', S.font, 'FontSize', cfg.out.figTitleSize);
        ylabel(tl, S.p, 'FontName', S.font, 'FontSize', cfg.out.figTitleSize);
        title(tl, sprintf('%s  (PV = %.2f MW, Wind = %.2f MW, ESS = %.2f MW / %.2f MWh, Gen = %.2f MW)', ...
            gopt_t(cfg.out.figLang, 'stacktitle'), res.cap(1), res.cap(2), res.cap(3), res.cap(4), res.cap(5)), ...
            'FontName', S.font, 'FontSize', cfg.out.figTitleSize, 'FontWeight', 'bold');
        gopt_save(f, [pfxDay 'dispatch'], cfg);
        nFig = nFig + 1;
    end

    % --- 4. SOC ---
    if gopt_flag(cfg, 'soc') && Ks > 0
        f = gopt_newfig(W, max(2.05 * nr + 2.6, 6.0));
        tl = tiledlayout(f, nr, nc, 'TileSpacing', 'compact', 'Padding', 'compact');
        for j = 1:Ks
            k = daySel(j);
            ax = nexttile(tl); hold(ax, 'on');
            r = gopt_plot_range(sc, k);
            if res.cap(4) > 0
                plot(ax, hr, res.R.socPct(r), '-', 'Color', P.blue, 'LineWidth', lw);
                yline(ax, cfg.ess.socMax * 100, '--', 'Color', P.grey, 'LineWidth', 0.7);
                yline(ax, cfg.ess.socMin * 100, '--', 'Color', P.grey, 'LineWidth', 0.7);
            else
                text(ax, 12, 50, 'ESS = 0', 'HorizontalAlignment', 'center', ...
                    'FontName', S.font, 'FontSize', cfg.out.figFontSize);
            end
            ylim(ax, [0 100]);  xlim(ax, [0.5 24.5]);
            title(ax, labs{j}, 'FontSize', cfg.out.figFontSize);
            gopt_style(ax, S, cfg);
        end
        xlabel(tl, S.t, 'FontName', S.font, 'FontSize', cfg.out.figTitleSize);
        ylabel(tl, S.socY, 'FontName', S.font, 'FontSize', cfg.out.figTitleSize);
        title(tl, gopt_t(cfg.out.figLang, 'soctitle'), ...
            'FontName', S.font, 'FontSize', cfg.out.figTitleSize, 'FontWeight', 'bold');
        gopt_save(f, [pfxDay 'soc'], cfg);
        nFig = nFig + 1;
    end
else
    fprintf(['[绘图] 未生成典型日曲线：cfg.out.makePlots 为 false，' ...
        '或 plotFigures 的 source/dispatch/soc 三项全关。\n']);
end

%% ---------- 5. 典型周 ----------
if gopt_flag(cfg, 'week') && ~isempty(scw) && ~isempty(Rw) && Rw.ok
    tt = (1:scw.T)';
    f = gopt_newfig(17.5, 15.0);
    tl = tiledlayout(f, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    % (a) 出力堆叠图（常规新能源电站口径）
    ax = nexttile(tl); hold(ax, 'on');
    [Yp, Yn, Cp, Cn, Lp, Ln] = gopt_stack_pack(Rw, 1:scw.T, Rw.cap(5) * scw.Gen, P, S);
    [hb, ext] = gopt_draw_stack(ax, tt, Yp, Yn, Cp, Cn, STACK);
    hl = [];  yExtra = [];
    if STACK.showLoad
        hl = plot(ax, tt, scw.load, '-', 'Color', P.black, 'LineWidth', lw);
        yExtra = scw.load;
    end
    yline(ax, 0, '-', 'Color', [0.20 0.20 0.20], 'LineWidth', cfg.out.axisLineWidth);
    % 显式设纵轴：这一格原先漏了，柱顶（购电）会与坐标框上边线完全重合。
    % 原因与修法同 gopt_ylim_pad；余量取 cfg.out.padFrac。
    gopt_ylim_pad(ax, ext, yExtra, STACK, cfg);
    xlim(ax, [0.5 scw.T + 0.5]);
    ylabel(ax, S.p);
    nmLg = [Lp(:)', Ln(:)'];
    hsLg = hb;
    if STACK.showLoad, hsLg = [hsLg, hl];  nmLg = [nmLg, {S.load}]; end
    lg = legend(ax, hsLg, nmLg, 'Location', 'northoutside', ...
        'Orientation', 'horizontal', 'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
    lg.ItemTokenSize = [12 8];
    gopt_style(ax, S, cfg);
    for d = 1:6
        xline(ax, d * 24, ':', 'Color', [0.85 0.85 0.85], 'HandleVisibility', 'off');
    end

    % (b) 储能充放电（负值为充电）
    ax = nexttile(tl); hold(ax, 'on');
    bp = bar(ax, tt, Rw.P_dis, 1.0, 'FaceColor', P.purple2, 'EdgeColor', 'none');
    bn = bar(ax, tt, -Rw.P_ch, 1.0, 'FaceColor', P.purple,  'EdgeColor', 'none');
    try, bp.FaceAlpha = STACK.alpha; bn.FaceAlpha = STACK.alpha; end
    yline(ax, 0, '-', 'Color', [0.20 0.20 0.20], 'LineWidth', cfg.out.axisLineWidth*0.8);
    % 同一类问题：bar 的自动纵轴刚好顶到极值，柱顶 / 柱底与边框线重合
    gopt_ylim_pad(ax, [min(-Rw.P_ch), max(Rw.P_dis)], [], STACK, cfg);
    xlim(ax, [0.5 scw.T + 0.5]);
    ylabel(ax, S.p);
    lg = legend(ax, {S.dis, S.ch}, 'Location', 'northoutside', ...
        'Orientation', 'horizontal', 'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
    lg.ItemTokenSize = [12 8];
    gopt_style(ax, S, cfg);
    for d = 1:6
        xline(ax, d * 24, ':', 'Color', [0.85 0.85 0.85], 'HandleVisibility', 'off');
    end

    % (c) SOC 与电价
    ax = nexttile(tl); hold(ax, 'on');
    yyaxis(ax, 'left');
    plot(ax, tt, Rw.socPct, '-', 'Color', P.blue, 'LineWidth', lw);
    ylabel(ax, S.socY);  ylim(ax, [0 100]);
    yyaxis(ax, 'right');
    plot(ax, tt, scw.buy,  '-',  'Color', P.verm,  'LineWidth', lw*0.9);
    plot(ax, tt, scw.sell, '--', 'Color', P.green, 'LineWidth', lw*0.9);
    % 右轴（电价）同样不能用自动纵轴：购电价峰值会贴住上边框。电价非负，
    % 按 gopt_ylim_pad 的下界规则钉在 0，余量只加在顶部。
    % 注意：此处激活的是右轴，ylim 作用于右侧量程，左侧 SOC 的 [0 100] 不受影响。
    gopt_ylim_pad(ax, [0 0], [scw.buy; scw.sell], STACK, cfg);
    ylabel(ax, S.priceY);
    xlabel(ax, S.t);  xlim(ax, [0.5 scw.T + 0.5]);
    gopt_style(ax, S, cfg);
    for d = 1:6
        xline(ax, d * 24, ':', 'Color', [0.85 0.85 0.85], 'HandleVisibility', 'off');
    end
    % yyaxis 会重置部分属性，这里补回图例
    legend(ax, {S.soc, S.buyPrice, S.sellPrice}, 'Location', 'northoutside', ...
        'Orientation', 'horizontal', 'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);

    % 总标题：写清这是「第几周、第几天到第几天」，与命令行 wkLabel 同口径
    wkNo = scw.weekIndex;  dy1 = scw.dayStart;  dy2 = scw.dayStart + 6;
    if strcmpi(cfg.out.figLang, 'en')
        wkTitle = sprintf('%s (Week %d: Day %d-%d)', ...
            gopt_t(cfg.out.figLang, 'weektitle'), wkNo, dy1, dy2);
    else
        wkTitle = sprintf('%s（第 %d 周：第 %d~%d 天）', ...
            gopt_t(cfg.out.figLang, 'weektitle'), wkNo, dy1, dy2);
    end
    title(tl, wkTitle, ...
        'FontName', S.font, 'FontSize', cfg.out.figTitleSize, 'FontWeight', 'bold');
    gopt_save(f, 'fig_typical_week', cfg);
    nFig = nFig + 1;
end

%% ---------- 6. 成本构成（柱顶标注数值，单位 万元/年）----------
if gopt_flag(cfg, 'cost')
    f = gopt_newfig(8.8, 6.2);
    ax = axes(f);
    [~, capD] = gopt_annual_capex(res.cap, cfg, res.R);
    % ★ 本轮新增两根柱：自发电投资（资产侧）与自发电运行（燃料侧）。
    %   两者分开画而不是合并成一根，是因为它们的性质完全不同：投资与容量成正比、
    %   与调度无关；运行与「这一年实际发了多少电」成正比，弃电越多这根柱越矮。
    vals = [capD.pv, capD.wt, capD.ess, capD.gen, res.R.costGenVar, ...
            res.R.costBuy, -res.R.revenueSell] / 1e4;
    bh = bar(ax, vals, 0.62);
    bh.FaceColor = 'flat';
    bh.CData(1, :) = P.orange;
    bh.CData(2, :) = P.sky;
    bh.CData(3, :) = P.purple;
    bh.CData(4, :) = P.grey;
    bh.CData(5, :) = P.grey3;
    bh.CData(6, :) = P.verm;
    bh.CData(7, :) = P.green;
    set(ax, 'XTick', 1:numel(vals), 'XTickLabel', gopt_catlabels(cfg.out.figLang));
    ylabel(ax, S.costY);
    xtickangle(ax, 20);

    % ---- 柱顶数值标注 ----
    % 正柱标在柱顶上方、负柱（售电收益）标在柱底下侧，标签一律带符号，单位与 y 轴同为 万元/年。
    %
    % ★ 可读性处理（本图的排版是 7 根柱塞进 8.8 cm 宽，柱间距只有约 1 cm）：
    %   ① 小数位按量级精简（gopt_numlabel）：≥100 取整、10~100 留 1 位、<10 留 2 位。
    %      改造前一律 '%.2f'，像「670.52」这种 6 字符标签的实测占宽超过柱间距，
    %      相邻标签首尾相碰（670.52 / 643.11 / 556.19 挤成一团）。精简后宽度约减半。
    %   ② 字号用 cfg.out.barLabelFontSize（默认 7 pt，比正文 8 pt 小一档）。
    %   ③ 兜底判定：把所有标签的真实渲染宽度量出来，若相邻两个标签的宽度之和仍超过
    %      一个柱间距（= 1 个数据单位），就把偶数号标签抬高半行错位摆放（正柱向上、
    %      负柱向下），保证任何数据下都不重叠。正常情况下不会触发，只在柱数变多 /
    %      画布变窄 / 数值位数变多时才兜住。
    %
    % 纵向留白按数据量级自适应：gap 是标签与柱端的间距，room 是标签外侧再留的空白，
    % 两者都取 span 的小比例，避免小柱子被压扁（不要用 2~3 倍 span 的粗放留白）。
    span = max(abs(vals));
    if ~(span > 0), span = 1; end
    gap  = 0.030 * span;
    room = 0.120 * span;
    ylo  = min([vals(:); 0]);  yhi = max([vals(:); 0]);
    ylim(ax, [ylo - gap - room, yhi + gap + room]);
    hLb  = gobjects(numel(vals), 1);
    for i = 1:numel(vals)
        if vals(i) >= 0
            va = 'bottom';  yy = vals(i) + 0.25 * gap;
        else
            va = 'top';     yy = vals(i) - 0.25 * gap;
        end
        hLb(i) = text(ax, i, yy, gopt_numlabel(vals(i)), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', va, ...
            'FontName', S.font, 'FontSize', gopt_bar_labelfs(cfg), ...
            'Color', [0.15 0.15 0.15]);
    end
    if gopt_bar_overlap(hLb)
        fprintf(['[绘图] 成本构成图：柱顶标签宽度超出柱间距，已自动错位摆放' ...
                 '（偶数号标签抬高半行）避免重叠。\n']);
        for i = 2:2:numel(hLb)
            e = get(hLb(i), 'Extent');                 % [左 下 宽 高]，数据坐标
            p = get(hLb(i), 'Position');
            dy = 0.9 * e(4);
            if vals(i) < 0, dy = -dy; end
            set(hLb(i), 'Position', [p(1), p(2) + dy, p(3)]);
        end
    end

    gopt_style(ax, S, cfg);
    gopt_save(f, 'fig_cost_breakdown', cfg);
    nFig = nFig + 1;
end

%% ---------- 6b. 专业化指标对比（默认关闭，cfg.out.plotFigures.proMetrics）----------
% 这张图不含任何新计算，只是把 res.pro 的数字画出来供汇报排版；因此即使关闭，
% 命令行与 Excel 里的专业化指标照样输出（数值与出图无关）。
if gopt_flag(cfg, 'proMetrics') && isfield(res, 'pro') && ~isempty(res.pro)
    gopt_plot_pro_metrics(res, cfg);
    nFig = nFig + 1;
end

if nFig > 0
    fprintf('[绘图] SCI 格式图片已保存到：%s（共 %d 张）\n', cfg.path.outDir, nFig);
else
    fprintf('[绘图] cfg.out.plotFigures 全部关闭，未生成任何图片。\n');
end
end

function tf = gopt_flag(cfg, name)
%GOPT_FLAG  读取 cfg.out.plotFigures.<name> 图种开关
%   字段或整个 plotFigures 结构缺失时返回 true，保证旧 cfg 仍能出全图（向后兼容）。
tf = true;
if isfield(cfg.out, 'plotFigures') && isstruct(cfg.out.plotFigures) ...
        && isfield(cfg.out.plotFigures, name)
    tf = logical(cfg.out.plotFigures.(name));
end
end

%% ------------------------------------------------------ 绘图辅助函数
function r = gopt_plot_range(sc, k)
%GOPT_PLOT_RANGE  取第 k 个「典型日图位」对应的小时索引（24 个 1..T 的下标）
%   typical_days：场景本身就只有 24K h，第 k 个典型日占第 (24(k-1)+1):(24k) 行，
%                 即 sc.dayRanges{k}。
%   full_year   ：场景是 8760 h，第 k 个图位对应「真实代表日」那一天在全年中的位置，
%                 由 gopt_build_scenario 预先算出放在 sc.plotRanges{k}。
%   统一走本函数，绘图代码就不必关心当前是哪种时间尺度模式。
if isfield(sc, 'plotRanges') && numel(sc.plotRanges) >= k && ~isempty(sc.plotRanges{k})
    r = sc.plotRanges{k};
else
    r = sc.dayRanges{k};
end
end

function [Yp, Yn, Cp, Cn, Lp, Ln] = gopt_stack_pack(R, idx, Gen, P, S)
%GOPT_STACK_PACK  把一个调度片段打包成「出力堆叠图」所需的正 / 负出力矩阵
%   正出力（零轴上方，自下而上堆叠）：储能放电 / 风电 / 光伏 / 自发电 / 购电
%   负出力（零轴下方，自上而下堆叠）：储能充电 / 售电 / 弃光伏 / 弃风电 / 弃自发电
%   ★ 本轮改动：
%     · 形参 Gen 传进来的是**已乘上容量的自发电出力 [MW]**（调用方算好），
%       因为 Gen 列本身是标幺、不再等于 MW；
%     · 弃电由 1 条拆成 3 条（按源），这样图上能直接看到「被弃的是谁」——
%       按经济性排序的结论（自发电先被弃、光伏最后被弃）在一张图上就自证了。
%   自动剔除在所给时段内恒为 0 的序列（例如自发电容量为 0 时不占图例）
rawP = {R.P_dis(idx), R.P_wt(idx), R.P_pv(idx), Gen(idx), R.P_buy(idx)};
colP = {P.purple2,    P.sky,      P.orange,     P.grey,   P.verm};
labP = {S.dis,        S.wt,       S.pv,        S.gen,    S.buy};

rawN = {-R.P_ch(idx), -R.P_sell(idx), -R.P_curtPV(idx), -R.P_curtWT(idx), -R.P_curtGen(idx)};
colN = {P.purple,      P.green,       P.grey2,          P.grey3,           P.grey4};
labN = {S.ch,          S.sell,        S.curtPV,         S.curtWT,          S.curtGen};

kp = cellfun(@(v) any(abs(v) > 1e-9), rawP);
kn = cellfun(@(v) any(abs(v) > 1e-9), rawN);

Yp = cell2mat(rawP(kp));  Cp = colP(kp);  Lp = labP(kp);
Yn = cell2mat(rawN(kn));  Cn = colN(kn);  Ln = labN(kn);
end

function [h, ext] = gopt_draw_stack(ax, x, Yp, Yn, Cp, Cn, STACK)
%GOPT_DRAW_STACK  画堆叠柱：正出力向上堆叠、负出力向下堆叠，各色块半透明
%   分两次 bar 调用，便于分别控制正 / 负两侧的堆叠顺序与透明度。
%   第二个返回值 ext 是「真实堆叠极值」[ymin ymax]，交给 gopt_ylim_pad 设纵轴用——
%   不能用自动纵轴（原因见 gopt_stack_ext 的注释）。
h = [];
hold(ax, 'on');
if ~isempty(Yp)
    bp = bar(ax, x, Yp, STACK.barWidth, 'stacked', 'EdgeColor', 'none');
    for k = 1:numel(bp), gopt_setbar(bp(k), Cp{k}, STACK.alpha); end
    h = [h, bp(:)'];
end
if ~isempty(Yn)
    bn = bar(ax, x, Yn, STACK.barWidth, 'stacked', 'EdgeColor', 'none');
    for k = 1:numel(bn), gopt_setbar(bn(k), Cn{k}, STACK.alpha); end
    h = [h, bn(:)'];
end
if ~isempty(h), h = h(isgraphics(h)); end
ext = gopt_stack_ext(Yp, Yn);
end

function ext = gopt_stack_ext(Yp, Yn)
%GOPT_STACK_EXT  堆叠柱的真实纵轴极值 [ymin ymax]
%   为什么必须自己算而不用自动纵轴：MATLAB 对 bar(...,'stacked') 的自动上限恰好取在
%   最高柱的堆叠总高处，一点余量都不留。实测本数据集（PV 30 / Wind 10 / ESS 15MW-30MWh）
%   典型日 1/2/4/5 的「上溢出」正好等于 0.000——柱顶与坐标框上边线完全重合，
%   再被 Layer='top' 的框线压住，看上去就像柱子被裁掉了、跑到框外去了。
%   根因与 dpi 无关，也不是数据越界；只能靠显式设 ylim 解决。
ymax = 0;  ymin = 0;
if ~isempty(Yp), ymax = max(sum(Yp, 2)); end
if ~isempty(Yn), ymin = min(sum(Yn, 2)); end
ext = [ymin, ymax];
end

function gopt_ylim_pad(ax, ext, extra, STACK, cfg)
%GOPT_YLIM_PAD  用「真实数据包络 + 比例余量」显式设置纵轴范围
%   为什么不能靠自动纵轴（本仓库已踩过的坑，勿回退）：
%     · bar(...,'stacked') 的自动上限恰好取在最高柱的堆叠总高，零余量；
%     · fill / 曲线的自动纵轴取到最近的整数刻度，极值落在刻度上时同样贴边；
%     · gopt_style 设了 Layer='top'，框线压在数据之上，贴边的数据被框线盖住，
%       看起来就像「被切掉」；而 gopt_save 导出前统一关了轴裁剪，真越界的数据
%       会直接画到坐标框之外、盖到相邻子图上。
%   输入  ext   堆叠柱极值 [ymin ymax]（来自 gopt_stack_ext；无堆叠柱的面板传 [0 0]）
%         extra 需一并纳入包络的其余数据（负荷 / 净负荷 / 源侧出力 / 电价等；可传 []）
%         STACK 结构体（可为空；仅作 yPadFrac 的开发期临时覆盖，见 gopt_padfrac）
%         cfg   参数结构体，取 cfg.out.padFrac 作余量比例（缺省 0.08）
%   下界规则：数据全非负 -> 下界钉在 0，余量只加在顶部（纯功率/价格图不该凭空多出
%             一段负半轴）；含负值 -> 上下各留同样余量，零轴不会被挤到一边。
v = [ext(:); 0];
if nargin >= 3 && ~isempty(extra), v = [v; extra(:)]; end
v = v(isfinite(v));
if isempty(v), return; end
lo = min(v);  hi = max(v);
span = hi - lo;
if ~(span > 0), span = max(abs(hi), 1); end      % 全零数据也要有个非零跨度，避免退化
pad = gopt_padfrac(STACK, cfg) * span;
if lo >= 0
    ylim(ax, [0, hi + pad]);
else
    ylim(ax, [lo - pad, hi + pad]);
end
end

function p = gopt_padfrac(STACK, cfg)
%GOPT_PADFRAC  取纵轴余量比例：优先级 cfg.out.padFrac > STACK.yPadFrac > 0.08
%   「口径只定义一次」：cfg_greenopt.m 的 cfg.out.padFrac 是唯一入口，
%   STACK.yPadFrac 只是开发期的临时覆盖；两者都取不到时才退回默认 0.08。
p = 0.08;
if nargin >= 2 && isstruct(cfg) && isfield(cfg, 'out') && isstruct(cfg.out) ...
        && isfield(cfg.out, 'padFrac') && ~isempty(cfg.out.padFrac)
    p = cfg.out.padFrac;
elseif nargin >= 1 && isstruct(STACK) && isfield(STACK, 'yPadFrac') && ~isempty(STACK.yPadFrac)
    p = STACK.yPadFrac;
end
end

function gopt_setbar(b, c, alpha)
%GOPT_SETBAR  设置柱体颜色与透明度（FaceAlpha 在旧版本上不存在时自动跳过）
b.FaceColor = c;
try, b.FaceAlpha = alpha; end
try, b.EdgeAlpha = 0;     end
end

function v = gopt_fillband(ax, x, y, c, alpha)
%GOPT_FILLBAND  半透明填充「源侧」出力带（用于源荷曲线图）
X = [x(:); flipud(x(:))];
Yv = [y(:); zeros(numel(y), 1)];
v = fill(ax, X, Yv, c, 'FaceAlpha', alpha, 'EdgeColor', 'none');
end

function P = gopt_palette()
%GOPT_PALETTE  Okabe-Ito 色盲友好调色板（Nature Methods 推荐，8 色全色盲可辨）
P.black   = [0.000 0.000 0.000];
P.orange  = [0.902 0.624 0.000];   % 光伏
P.sky     = [0.337 0.706 0.914];   % 风电
P.green   = [0.000 0.620 0.451];   % 售电
P.yellow  = [0.941 0.894 0.259];
P.blue    = [0.000 0.447 0.698];
P.verm    = [0.835 0.369 0.000];   % 购电
P.purple  = [0.600 0.310 0.640];   % 储能充电（浅紫）
P.purple2 = [0.400 0.160 0.480];   % 储能放电（深紫）
P.grey    = [0.450 0.450 0.450];   % 厂内自发电
P.grey2   = [0.780 0.780 0.780];   % 弃光伏
P.grey3   = [0.620 0.620 0.620];   % 弃风电（★ 本轮新增：弃电按源拆开）
P.grey4   = [0.880 0.880 0.880];   % 弃自发电（★ 本轮新增，最浅：最常被弃）
end

function S = gopt_labels(lang)
%GOPT_LABELS  图内文字标签（'zh' 中文 / 'en' 英文），供全部绘图函数共用
%   注：坐标轴标签一律保持「英文/符号 + 中文说明」的 SCI 习惯，例如 '功率 (MW)'。
switch lower(lang)
    case 'zh'
        S.font = 'Microsoft YaHei';
        S.load='负荷'; S.pv='光伏'; S.wt='风电'; S.net='净负荷'; S.gen='自发电';
        S.buy='购电'; S.sell='售电'; S.ch='储能充电'; S.dis='储能放电';
        S.curt='弃风弃光'; S.ren='光伏+风电'; S.soc='SOC';
        S.curtPV='弃光伏'; S.curtWT='弃风电'; S.curtGen='弃自发电';
        S.buyPrice='购电价'; S.sellPrice='售电价';
        S.t='时刻 (h)'; S.p='功率 (MW)'; S.socY='SOC (%)'; S.priceY='电价 (元/kWh)';
        S.iter='迭代代数'; S.costY='年化总成本 (万元/年)';
        S.gbest='群体最优'; S.gmean='种群均值';
        % ---- 敏感性分析图专用 ----
        S.esP='储能额定功率 P (MW)'; S.esE='储能容量 E (MWh)';
        S.fixDur='时长固定'; S.fixPow='功率固定';
        S.pvCap='光伏装机 (MW)'; S.wtCap='风电装机 (MW)'; S.genCap='自发电容量 (MW)';
        S.sensCostY='年化总成本 (万元/年)'; S.unusedY='未自用率 (%)';
        S.rateY='比例 (%)'; S.capexY='年化成本 (万元/年)';
        S.selfRate='绿电自用率'; S.sellRate='上网率'; S.curtRate='弃电率';
        S.capexPv='光伏年化'; S.capexWt='风电年化'; S.capexEss='储能年化'; S.opCost='运行成本';
        S.minPt='最低点';
        S.tSensP='储能功率敏感性'; S.tSensE='储能容量敏感性';
        S.tSensPV='光伏装机敏感性'; S.tSensWT='风电装机敏感性';
        S.tSensUtil='消纳指标随储能容量变化'; S.tSensCost='成本构成随储能容量变化';
        S.tSensGen='自发电容量敏感性'; S.tSensGenShare='自发电占比与度电成本';
        S.genShareY='自发电占负荷比例 (%)'; S.genLcoeY='自发电度电成本 (元/kWh)';
        % ---- 专业化指标图 ----
        S.lcoeY='度电成本 (元/kWh)';
        S.lcoeGen='LCOE 发电口径'; S.lcoeCon='LCOE 消纳口径';
        S.mGreen='用户绿电占比'; S.mAbsorb='新能源消纳比例'; S.mSave='成本节省率';
    otherwise
        S.font = 'Times New Roman';
        S.load='Load'; S.pv='PV'; S.wt='Wind'; S.net='Net load'; S.gen='Gen';
        S.buy='Grid purchase'; S.sell='Grid sale'; S.ch='ESS charging'; S.dis='ESS discharging';
        S.curt='Curtailment'; S.ren='PV+Wind'; S.soc='SOC';
        S.curtPV='Curtail PV'; S.curtWT='Curtail wind'; S.curtGen='Curtail gen';
        S.buyPrice='Purchase price'; S.sellPrice='Sale price';
        S.t='Time (h)'; S.p='Power (MW)'; S.socY='SOC (%)'; S.priceY='Price (CNY/kWh)';
        S.iter='Iteration'; S.costY='Annualized cost (10^4 CNY/yr)';
        S.gbest='Global best'; S.gmean='Swarm mean';
        % ---- sensitivity figure ----
        S.esP='Rated ESS power P (MW)'; S.esE='ESS capacity E (MWh)';
        S.fixDur='duration fixed at'; S.fixPow='power fixed at';
        S.pvCap='PV capacity (MW)'; S.wtCap='Wind capacity (MW)'; S.genCap='Gen capacity (MW)';
        S.sensCostY='Annualized total cost (10^4 CNY/yr)'; S.unusedY='Non-self-used share (%)';
        S.rateY='Share (%)'; S.capexY='Annualized cost (10^4 CNY/yr)';
        S.selfRate='Self-used share'; S.sellRate='Grid-sale share'; S.curtRate='Curtailment share';
        S.capexPv='PV capex'; S.capexWt='Wind capex'; S.capexEss='ESS capex'; S.opCost='Operation cost';
        S.minPt='minimum';
        S.tSensP='ESS power sensitivity'; S.tSensE='ESS capacity sensitivity';
        S.tSensPV='PV capacity sensitivity'; S.tSensWT='Wind capacity sensitivity';
        S.tSensUtil='Utilization indices vs ESS capacity';
        S.tSensCost='Cost breakdown vs ESS capacity';
        S.tSensGen='Gen capacity sensitivity';
        S.tSensGenShare='Gen share of load and its LCOE';
        S.genShareY='Gen share of load (%)'; S.genLcoeY='Gen LCOE (CNY/kWh)';
        % ---- professional-metrics figure ----
        S.lcoeY='LCOE (CNY/kWh)';
        S.lcoeGen='Generation basis'; S.lcoeCon='Consumption basis';
        S.mGreen='Green share of load'; S.mAbsorb='Renewable absorption'; S.mSave='Cost saving rate';
end
end

function v = gopt_t(lang, key)
switch key
    case 'srctitle'
        if strcmpi(lang, 'zh'), v = '典型日源荷曲线'; else, v = 'Typical-day source-load profiles'; end
    case 'stacktitle'
        if strcmpi(lang, 'zh'), v = '典型日出力堆叠图'; else, v = 'Stacked generation dispatch on typical days'; end
    case 'soctitle'
        if strcmpi(lang, 'zh'), v = '典型日储能 SOC'; else, v = 'Battery SOC on typical days'; end
    case 'weektitle'
        if strcmpi(lang, 'zh'), v = '典型周调度结果'; else, v = 'Optimal dispatch over the typical week'; end
    case 'senstitle'
        if strcmpi(lang, 'zh'), v = '敏感性分析'; else, v = 'Sensitivity analysis'; end
    case 'protitle'
        if strcmpi(lang, 'zh'), v = '专业化指标'; else, v = 'Professional metrics'; end
    case 'prolcoe'
        if strcmpi(lang, 'zh'), v = '绿电度电成本 LCOE（不含税）'; else, v = 'LCOE of green power (excl. tax)'; end
    case 'prorate'
        if strcmpi(lang, 'zh'), v = '关键比例指标'; else, v = 'Key ratio indicators'; end
    otherwise
        v = '';
end
end

function c = gopt_catlabels(lang)
%GOPT_CATLABELS  成本构成图的横轴类别（顺序必须与 gopt_plots 第 6 段的 vals 完全一致）
if strcmpi(lang, 'zh')
    c = {'光伏投资', '风电投资', '储能投资', '自发电投资', '自发电运行', '购电成本', '售电收益'};
else
    c = {'PV capex', 'Wind capex', 'ESS capex', 'Gen capex', 'Gen fuel', 'Grid purchase', 'Grid sale'};
end
end

function labs = gopt_daylabels(sc, daySel, lang)
%GOPT_DAYLABELS  生成典型日子图标题（单行，只写清这个典型日是哪一天）
%
%   刻意不再标注「簇内多少天」「覆盖第 a-b 天」「全年结果截取」等信息——
%   子图在 3 列布局下本来就窄，两行长标题会互相压住，而聚类信息放在命令行日志里
%   反而更清楚（见 gopt_daylog）。日期标识与日志严格同口径：
%     full_year    模式 -> repDay（真实代表日；图里画的正是这一天的 24 h）
%     typical_days 模式 -> dMed  （簇内成员自然日中位数）
%   例：{'典型日1：第104天'}  /  {'Typical day 1: Day 104'}
labs = cell(numel(daySel), 1);
for j = 1:numel(daySel)
    k = daySel(j);
    d = gopt_show_day(sc, k);
    if isempty(d) || ~isfinite(d)
        if strcmpi(lang, 'zh')
            labs{j} = sprintf('典型日%d', k);
        else
            labs{j} = sprintf('Typical day %d', k);
        end
    elseif strcmpi(lang, 'zh')
        labs{j} = sprintf('典型日%d：第%d天', k, round(d));
    else
        labs{j} = sprintf('Typical day %d: Day %d', k, round(d));
    end
end
end

function d = gopt_show_day(sc, k)
%GOPT_SHOW_DAY  取第 k 个典型日用于「命令行日志 + 图内标题」的标识自然日
%   与 gopt_daylog 的口径严格一致，保证同一个典型日在日志和图里显示的是同一天：
%     full_year 模式（sc.plotRanges 非空）-> repDay（真实代表日）
%     其余                                  -> dMed（簇内成员自然日中位数）
%   取不到时返回 NaN，由调用方决定退化显示方式。
d = NaN;
if ~isempty(sc.typDay) && numel(sc.typDay) >= k
    if isfield(sc, 'plotRanges') && ~isempty(sc.plotRanges) ...
            && isfield(sc.typDay, 'repDay') && ~isempty(sc.typDay(k).repDay)
        d = sc.typDay(k).repDay;
    elseif isfield(sc.typDay, 'dMed') && ~isempty(sc.typDay(k).dMed)
        d = round(sc.typDay(k).dMed);
    end
end
end

function s = gopt_day2date(day, lang)
%GOPT_DAY2DATE  把「自然日序号」换算成公历日期文字（第 1 天 = 1 月 1 日，非闰年）
%   用途：让日志与图标题里的「第 104 天」一眼能看出大致是什么季节，
%        不需要读者自己在脑子里做累加。
%   数据恒为一整年 365 天（8760 h），故一律按非闰年切分（2 月 28 天）。
%
%   输入  day  自然日序号（可为小数，内部四舍五入）
%         lang 'zh' -> '4月14日'（默认） | 'en' -> 'Apr 14'
if nargin < 2 || isempty(lang), lang = 'zh'; end
md    = [31 28 31 30 31 30 31 31 30 31 30 31];
edges = cumsum(md);
en    = {'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'};

d = round(day);
d = max(1, min(d, edges(end)));              % 夹到 1..365，防止越界
m = find(edges >= d, 1, 'first');            % 落在第几个月
if m > 1
    dd = d - edges(m - 1);                   % 该月内的第几天
else
    dd = d;
end
if strcmpi(lang, 'en')
    s = sprintf('%s %d', en{m}, dd);
else
    s = sprintf('%d月%d日', m, dd);
end
end

function gopt_daylog(k, prof, scMode, cfg)
%GOPT_DAYLOG  打印一行「典型日」概要（命令行傻瓜式输出，一个典型日恰好一行）
%   输出格式（固定列宽，便于上下扫读）：
%       典型日 1   第 104 天（约 4月14日）  本类共  97 天
%   各列的「日期标识」口径与图内子图标题严格一致：
%     full_year    模式 -> prof.repDay（真实代表日；图里画的就是这一天的 24 h）
%     typical_days 模式 -> prof.dMed  （簇内成员自然日中位数；簇内均值曲线没有
%                                     唯一对应的自然日，故用中位日作日期标识）
%   cfg.out.showMonthHist = true 时，再追加一行缩进的 12 个月分布（默认关闭）。
%
%   输入  k      典型日编号（1..K，已按日期键升序）
%         prof   gopt_day_typ 返回的单个典型日结构体（需 .weight/.members/.dMed 等）
%         scMode sc.mode：'full_year' | 'typical_days'
%         cfg    全局配置
lang = 'zh';
if isfield(cfg.out, 'figLang') && ~isempty(cfg.out.figLang)
    lang = cfg.out.figLang;
end

if strcmpi(scMode, 'full_year') && isfield(prof, 'repDay') && ~isempty(prof.repDay)
    d = prof.repDay;
else
    d = round(prof.dMed);
end

fprintf('       典型日 %-2d  第 %3d 天（约 %s）  本类共 %3d 天\n', ...
    k, d, gopt_day2date(d, lang), prof.weight);

if isfield(cfg.out, 'showMonthHist') && logical(cfg.out.showMonthHist) ...
        && isfield(prof, 'members') && ~isempty(prof.members)
    h = gopt_month_hist(prof.members);
    mm = find(h > 0);
    parts = arrayfun(@(m) sprintf('%d月%d天', m, h(m)), mm, 'UniformOutput', false);
    fprintf('                 按月分布：%s（真实历法月，合计 %d 天）\n', ...
        strjoin(parts, ' '), sum(h));
end
end

function h = gopt_month_hist(days)
%GOPT_MONTH_HIST  统计一组自然日按「真实历法月」的天数分布（1x12，单位：天）
%   输入 days 为自然日序号（第 1 天 = 1 月 1 日），按非闰年切分：
%   各月天数 = [31 28 31 30 31 30 31 31 30 31 30 31]。
%   返回 h(m) = 落在第 m 月的天数，恒有 sum(h) == numel(days)（越界值先剔除）。
%
%   历史说明：旧版用 ceil(day/30.5) 做 12 个等宽分桶，会把第 355~365 天全部并进
%   「12 月」，还会让「2 月」出现 30 天这种不存在的历法；现改为真实历法月，
%   同时保留「12 个数之和 = 簇内天数」这一守恒性质。
md    = [31 28 31 30 31 30 31 31 30 31 30 31];
edges = cumsum(md);
d     = round(days(:));
d     = d(d >= 1 & d <= edges(end));       % 剔除越界值，避免污染统计
h     = zeros(1, 12);
for m = 1:12
    lo   = 1 + sum(md(1:m-1));             % 第 m 月的首日序号
    h(m) = sum(d >= lo & d <= edges(m));
end
end

function f = gopt_newfig(wcm, hcm)
f = figure('Visible', 'off', 'Color', 'w', 'Units', 'centimeters', ...
    'Position', [1 1 wcm hcm], 'PaperUnits', 'centimeters', ...
    'PaperSize', [wcm hcm], 'PaperPosition', [0 0 wcm hcm]);
end

function gopt_style(ax, S, cfg)
set(ax, 'FontName', S.font, 'FontSize', cfg.out.figFontSize, ...
    'LineWidth', cfg.out.axisLineWidth, 'Box', 'on', 'TickDir', 'in', ...
    'TickLength', [0.012 0.012], 'XMinorTick', 'on', 'YMinorTick', 'on', 'Layer', 'top');
if cfg.out.grid
    grid(ax, 'on');
    set(ax, 'GridLineStyle', ':', 'GridAlpha', 0.20, 'GridColor', [0.45 0.45 0.45], ...
        'MinorGridLineStyle', 'none');
    try
        set(ax, 'GridLineWidth', 0.4);
    catch
    end
else
    grid(ax, 'off');
end
end

function s = gopt_numlabel(v, maxDec)
%GOPT_NUMLABEL  图表数值标签「按量级精简小数位」的格式化（返回字符串）
%   规则：|v| >= 100 取整；10 <= |v| < 100 留 1 位；|v| < 10 留 2 位。
%   为什么按量级分档而不是统一位数：标签的可读性只取决于字符数——窄柱图上字符越少越
%   不容易与邻柱标签相碰；而大数值保留两位小数（5374.24）视觉上毫无价值（有效信息不足
%   万分之一），小数值（0.42）丢掉小数位则信息全失。
%   maxDec（可选，默认 2）是该标签允许的最多小数位，用于整体收紧或放宽。
if nargin < 2 || isempty(maxDec), maxDec = 2; end
a = abs(v);
if a >= 100
    nd = 0;
elseif a >= 10
    nd = min(1, maxDec);
else
    nd = min(2, maxDec);
end
s = sprintf('%.*f', nd, v);
end

function fs = gopt_bar_labelfs(cfg)
%GOPT_BAR_LABELFS  柱顶数值标签的字号：读 cfg.out.barLabelFontSize，缺省退回「正文 - 1」
fs = cfg.out.figFontSize - 1;
if isfield(cfg.out, 'barLabelFontSize') && ~isempty(cfg.out.barLabelFontSize)
    fs = cfg.out.barLabelFontSize;
end
end

function tf = gopt_bar_overlap(hs)
%GOPT_BAR_OVERLAP  相邻柱顶标签是否会在水平方向相碰（供错位摆放兜底）
%   判据：本类柱状图的柱心恒为 1,2,...,n（间距恰好 1 个数据单位），故第 i 与第 i+1 个
%   标签相碰 <=> 两者渲染宽度之和 > 2。
%   用真实渲染宽度（Extent）而非「字符数 x 平均字宽」估算：汉字、负号、数码的宽度各不
%   相同，估算在边界情况下必然误判，而 Extent 是排版后的实测值。
hs = hs(:);
tf = false;
if numel(hs) < 2, return; end
drawnow;                                   % 刷新渲染状态，保证 Extent 可用
w  = zeros(numel(hs), 1);
for i = 1:numel(hs)
    try
        e = get(hs(i), 'Extent');
        w(i) = e(3);
    catch
        return;                            % 量不出尺寸（极旧版本）=> 不错位，保持原样式
    end
end
for i = 1:numel(hs) - 1
    if (w(i) + w(i + 1)) / 2 > 1.0
        tf = true;  return;
    end
end
end

function s = gopt_flat_note(lang)
%GOPT_FLAT_NOTE  「该轴在这段扫描区间内近似恒定」的图内说明文字（中/英）
if strcmpi(lang, 'en')
    s = 'nearly constant in this range (capacity-independent)';
else
    s = '该区间内近似恒定（与容量无关）';
end
end

function r = gopt_ruler(ax, side)
%GOPT_RULER  取坐标轴某一侧的刻度尺对象（'x' | 'left' | 'right'）
switch lower(side)
    case 'x',     r = ax.XAxis;
    case 'left',  r = ax.YAxis(1);
    case 'right', r = ax.YAxis(2);
    otherwise,    error('gopt_ruler:side', 'side 只能是 ''x'' / ''left'' / ''right''。');
end
end

function n = gopt_dec_need(v)
%GOPT_DEC_NEED  把这组数值恰好写出来所需的最少小数位（0~6），用于定刻度标签位数
%   判定方式是「保留 n 位后能否还原原值」，而不是看数值落在什么量级——因为后者会把
%   10 / 12.5 / 15 这组刻度判成 0 位，于是 12.5 被标成 13，属于错读。
v = v(:);  v = v(isfinite(v));
n = 0;
if isempty(v), return; end
tol = 1e-9 * max(1, max(abs(v)));
for n = 0:6
    if max(abs(round(v * 10^n) / 10^n - v)) <= tol
        return;
    end
end
n = 6;
end

function tk = gopt_nice_ticks(lo, hi, nMax)
%GOPT_NICE_TICKS  在 [lo, hi] 内生成一组「整齐」的刻度（步长取 1/2/5 x 10^k）
%   不用 MATLAB 自动刻度的理由：自动刻度在「范围极窄」的轴上会给出浮点噪声级的位置，
%   这里显式钉住，使刻度位置与 gopt_tickfmt 算出的小数位严格对应、结果可复现。
if ~(isfinite(lo) && isfinite(hi)) || hi <= lo
    tk = [];
    return;
end
raw = (hi - lo) / max(nMax - 1, 1);
e   = floor(log10(raw));
m   = raw / 10^e;
if       m <= 1, m = 1;
elseif   m <= 2, m = 2;
elseif   m <= 5, m = 5;
else,            m = 10;
end
st    = m * 10^e;
first = ceil(lo / st) * st;
tk    = first : st : hi;
epsT  = 1e-9 * abs(st);                       % 浮点边界修正（避免端点被舍掉）
tk    = tk(tk >= lo - epsT & tk <= hi + epsT);
if numel(tk) < 2, tk = [lo, hi]; end
end

function nDec = gopt_tickfmt(ax, side, maxDec)
%GOPT_TICKFMT  把某一侧刻度钉成「刚好够用」的固定小数位，并返回所用位数
%
%   为什么需要：自动刻度在「数值近似恒定」的轴上会把浮点噪声展开成十几位小数。
%   本项目的真实案例——fig_sensitivity 的 (h) 右轴（自发电度电成本）：它等于
%   「单位投资 x 年化费用率 / 等效满发小时 + 运行成本」，与装机容量无关，9 个扫描点算
%   出来全是 0.109738831231284（差异在 1e-15 量级），MATLAB 于是把纵轴标成
%   0.1097388312313 / 0.10973883123129 …：既读不出信息，又把版面挤爆。
%
%   处理策略（尽量少动）：
%     ① 先看自动刻度本身需要几位小数。若 <= 2 位（整数或一两位小数），说明它已经足够
%        简洁，本函数**什么都不做**直接返回 —— 这样其它子图的外观与本函数引入前完全一致；
%     ② 若自动刻度需要 3 位以上但不超过 maxDec，保留自动刻度的位置，只把标签格式钉死
%        （防止 MATLAB 在同一根轴上改用指数记法）；
%     ③ 若自动刻度需要超过 maxDec（≈数值近似恒定的轴上把浮点噪声展开），则改用 1/2/5
%        步长的整齐刻度，再钉格式；
%     ④ 最后逐级放宽小数位，直到各刻度标签互不相同（否则会出现两个刻度显示同一个读数，
%        这比位数多更难读）。放宽上限为 maxDec + 3。
%   调用时机要求：必须在 ylim / 数据全部画完之后调用（它读的是当前范围与刻度）。
if nargin < 3 || isempty(maxDec), maxDec = 4; end
r  = gopt_ruler(ax, side);
tk = r.TickValues;                            % 自动模式下 MATLAB 也会返回已算好的刻度
if isempty(tk)                                % 量不到就自己造一组，保证后续判断有依据
    lm = r.Limits;
    tk = gopt_nice_ticks(lm(1), lm(2), 6);
end
nDec = gopt_dec_need(tk);
if nDec <= 2
    return;                                   % ① 自动刻度已足够简洁 —— 保持原样，不干预
end
if nDec > maxDec                              % ③ 位数失控 —— 换用整齐刻度
    lm = r.Limits;
    tn = gopt_nice_ticks(lm(1), lm(2), 6);
    if numel(tn) >= 2
        r.TickValues = tn;
        tk = tn;
    end
end
nDec = min(max(gopt_dec_need(tk), 0), maxDec);
while nDec < maxDec + 3                       % ④ 保证相邻刻度读数互不相同
    lb = arrayfun(@(v) sprintf('%%.%df', nDec, v), tk, 'UniformOutput', false);
    if numel(unique(lb)) == numel(lb), break; end
    nDec = nDec + 1;
end
r.TickLabelFormat = sprintf('%%.%df', nDec);
try
    r.Exponent = 0;                           % 关掉 x10^n 指数标记（标签已是定长小数）
catch
end
end

function tf = gopt_axis_readable(ax, side, ydata, relWin)
%GOPT_AXIS_READABLE  把「近似恒定」的某一侧轴撑成一个可读量程
%   背景：fig_sensitivity (h) 右轴画的自发电度电成本 = 「单位投资 x 年化费用率 / 等效满发
%   小时 + 运行成本」，与装机容量无关，9 个扫描点算出来全是 0.109738831231284
%   （差异只在 1e-15 量级）。此时自动量程会把这点浮点噪声铺满整根轴：实测刻度是
%   0.1097388312313 / 0.10973883123129 …，既读不出信息又挤爆版面。
%   做法：把量程改写成「数据中心值 x (1 ± relWin)」（默认 ±1%），使刻度能落在若干个互不
%   相同的可读数值上，再由 gopt_tickfmt 把小数位钉死。
%
%   ★ 判据必须基于**数据本身**，不能基于当前量程——这是实测踩到的坑：若数据完全恒定
%     （极差恰为 0），MATLAB 对双 y 轴副轴的自动量程会退化成 [-1, 1.5] 这种默认区间，
%     此时「量程的相对宽度」是 1000%，用它会判定为「不恒定」，于是反而把一根水平线画在
%     了 -1~1.5 的坐标里（线贴在 44% 高度、刻度全是 -1/0/1 这类无意义数字）。
%     所以这里直接看 ydata 的极差。
%   返回 tf 表示是否触发，供调用方决定要不要在图上补一行说明。本函数只改「看多大范围」，
%   不触碰任何数据，故不改变图中曲线的真实含义。
if nargin < 4 || isempty(relWin), relWin = 0.01; end
tf = false;
d  = ydata(:);  d = d(isfinite(d));
if isempty(d), return; end
c   = mean([min(d), max(d)]);
if ~(isfinite(c) && abs(c) > 0), return; end
if (max(d) - min(d)) / abs(c) < 1e-3
    r  = gopt_ruler(ax, side);
    lm = sort(c * [1 - relWin, 1 + relWin]);     % sort 兼容负中心值
    r.Limits = lm;
    tf = true;
end
end

function gopt_save(f, base, cfg)
%GOPT_SAVE  把图导出为 cfg.out.figFormats 指定的各格式
%   默认只出 PNG 位图（cfg.out.figFormats = {'png'}）；若把 'pdf' 等矢量格式加回该选项，
%   程序会自动为矢量格式改走 ContentType='vector' 分支，两边的坐标轴设置完全共用。
%
%  ★ 高分辨率导出前必须关闭坐标轴裁剪（ax.Clipping = 'off'），否则 MATLAB 会
%    把部分数据曲线整条丢掉——这是本项目踩过的真实坑，务必保留本段代码：
%      · 触发条件：导出像素尺寸较大时。实测本图（24x14 cm）在 450 dpi 及以下正常，
%        500 dpi 开始出现部分丢失，600 dpi 下 (c) 光伏装机子图两条曲线完全消失；
%      · 表现：坐标框、刻度、图例、文字照常显示，只有数据线（含标记）一个像素都不画，
%        看起来就像「曲线跑到量程外了」，其实曲线数据完全落在坐标范围之内；
%      · 原因：MATLAB 渲染管线在高分辨率下会把坐标轴的裁剪矩形算错，落在矩形外的
%        数据线被整体裁掉（双 y 轴面板尤其容易触发）；
%      · 旁证：同一次运行导出的 PDF（矢量路径）里曲线完全正常，可据此确认不是数据问题。
%    规避：导出前把各坐标轴的 Clipping 设为 'off'。本项目的曲线数据都在各自坐标范围
%    之内，关掉裁剪不会让任何数据溢出坐标框，屏幕显示效果不变。
%    参考：MathWorks Answers「Line markers disappeared after save as .eps/.emf when
%          yyaxis was used」给出的同类规避方法。
axAll = findall(f, 'Type', 'axes');
for q = 1:numel(axAll)
    try
        axAll(q).Clipping = 'off';
    catch
    end
end
for i = 1:numel(cfg.out.figFormats)
    ext = cfg.out.figFormats{i};
    fp  = fullfile(cfg.path.outDir, [base '.' ext]);
    if strcmpi(ext, 'png')
        exportgraphics(f, fp, 'Resolution', cfg.out.dpi, 'BackgroundColor', 'white');
    else
        exportgraphics(f, fp, 'ContentType', 'vector', 'BackgroundColor', 'white');
    end
end
    close(f);
end

function gopt_plot_pro_metrics(res, cfg)
%GOPT_PLOT_PRO_METRICS  专业化指标对比图（左：两个 LCOE；右：三个比例指标）
%
%   这张图只负责排版，不重算任何指标：全部数值取自 res.pro（= gopt_metrics_pro 的结果），
%   与命令行 9c 段、Excel「专业指标」表是同一份数字，不产生第三个口径。
%   由 cfg.out.plotFigures.proMetrics 控制，默认关闭——它不影响任何数值，纯粹为汇报排版。
%
%   纵轴同样是显式设的：柱顶一旦贴住坐标框线就会被 Layer='top' 的框线压住，
%   看起来像被切掉（缘由见 gopt_ylim_pad）。本图数据全为非负，故下界钉 0。
%
%   输入  res  最优解结构（需 .pro）
%         cfg  全局配置
X  = res.pro;
P  = gopt_palette();
S  = gopt_labels(cfg.out.figLang);
f  = gopt_newfig(17.5, 6.8);
tl = tiledlayout(f, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

% ---- (a) 两个 LCOE（发电口径 / 消纳口径）----
ax = nexttile(tl);
v  = [X.lcoeGen, X.lcoeCon];
bh = bar(ax, v, 0.55, 'EdgeColor', 'none');
bh.FaceColor = 'flat';
bh.CData(1, :) = P.orange;
bh.CData(2, :) = P.blue;
set(ax, 'XTick', 1:2, 'XTickLabel', {S.lcoeGen, S.lcoeCon}, 'XTickLabelRotation', 0);
ylabel(ax, S.lcoeY);
title(ax, gopt_t(cfg.out.figLang, 'prolcoe'), 'FontSize', cfg.out.figFontSize + 1);
vv = v(isfinite(v));
if isempty(vv), vv = 1; end
vm = max(abs(vv));  if ~(vm > 0), vm = 1; end
ylim(ax, [0, vm * 1.18]);
for i = 1:numel(v)
    if isfinite(v(i))
        text(ax, i, v(i) + 0.03 * vm, sprintf('%.4f', v(i)), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontName', S.font, 'FontSize', cfg.out.figFontSize);
    end
end
gopt_style(ax, S, cfg);

% ---- (b) 三个比例指标 ----
ax = nexttile(tl);
v  = [X.greenRate, X.absorbRate, X.saveRate];
bh = bar(ax, v, 0.5, 'EdgeColor', 'none');
bh.FaceColor = 'flat';
bh.CData(1, :) = P.sky;
bh.CData(2, :) = P.green;
bh.CData(3, :) = P.purple;
set(ax, 'XTick', 1:3, 'XTickLabel', {S.mGreen, S.mAbsorb, S.mSave}, 'XTickLabelRotation', 20);
ylabel(ax, S.rateY);
title(ax, gopt_t(cfg.out.figLang, 'prorate'), 'FontSize', cfg.out.figFontSize + 1);
vv = v(isfinite(v));
if isempty(vv), vv = 1; end
vm = max([abs(vv), 1]);
ylim(ax, [0, vm * 1.18]);
for i = 1:numel(v)
    if isfinite(v(i))
        text(ax, i, v(i) + 0.03 * vm, sprintf('%.2f%%', v(i)), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontName', S.font, 'FontSize', cfg.out.figFontSize);
    end
end
gopt_style(ax, S, cfg);

% 总标题只写「短口径」，完整说明（含为何是全年/典型日）在命令行与 Excel 里；
% 完整 refTag 塞进标题会变成三层括号、又长又难读。
title(tl, sprintf('%s（%s）', gopt_t(cfg.out.figLang, 'protitle'), X.refShort), ...
    'FontName', S.font, 'FontSize', cfg.out.figTitleSize, 'FontWeight', 'bold');
gopt_save(f, 'fig_pro_metrics', cfg);
end

%% ============================================================== 结果导出
function outFile = gopt_export(res, ds, sc, scw, Rw, cfg)
%GOPT_EXPORT  写出全部结果到 Excel / MAT
%   工作表：最优配置 / 成本与电量 / 分档明细（★本轮新增）/ 典型日调度 / 典型周调度 /
%           全年SOC充放电（汇总）/ 全年SOC逐小时（8760 行逐时明细） / PSO收敛 /
%           搜索设置 / 数据说明 / 专业指标 / 敏感性分析 / 全年核准

if ~exist(cfg.path.outDir, 'dir'), mkdir(cfg.path.outDir); end
outFile = fullfile(cfg.path.outDir, 'optimization_results.xlsx');
if exist(outFile, 'file'), delete(outFile); end

cap = res.cap(:);
R = res.R;
[~, capD] = gopt_annual_capex(cap, cfg, R);   % 传 R：储能寿命口径与主线一致

% ---- 最终解贴界情况：把贴界的维度名列出来 ----
% 为什么要单列一行：容量贴上界意味着「这个维度的结论其实由上界决定，而不是由经济性决定」，
% 必须让人一眼看见，否则容易把「上界刚好卡住」当成「最优就在这儿」。
% 而「取下限 0」是另一回事（= 不该建该资产），故分开表述。
[varNm, ~] = gopt_varnames();
if isfield(res, 'hitUpper') && any(res.hitUpper)
    hitTxt = ['是，贴上界：' strjoin(varNm(logical(res.hitUpper(:)))', '、') '（结论可能由上界决定，见下方诊断明细）'];
elseif isfield(res, 'hitBound') && any(res.hitBound)
    hitTxt = ['否（有维度取下限 0：' strjoin(varNm(logical(res.hitBound(:)))', '、') '，表示不建该资产）'];
else
    hitTxt = '否';
end

%% ---------- 1. 最优配置 ----------
% 成本一律以 万元/年 输出（1 万元 = 1e4 元）；表中数值为 double 原始精度，
% 只是数量级换算，不做四舍五入。
C1 = {
    '项目', '数值', '单位'
    '光伏最优容量',              cap(1),                    'MW'
    '风电最优容量',              cap(2),                    'MW'
    '储能最优功率',              cap(3),                    'MW'
    '储能最优时长',              res.s(4),                  'h'
    '储能最优容量(功率x时长)',   cap(4),                    'MWh'
    '厂内自发电最优容量',        cap(5),                    'MW'
    '自发电度电成本',            gopt_tern(cap(5) > 0, res.pro.genLcoe, NaN), '元/kWh（年化投资+运行成本，分母为实发电量）'
    '年化总成本',                res.fit / 1e4,             '万元/年'
    '其中：年化投资成本',        res.costCapex / 1e4,       '万元/年'
    '其中：年化运行成本',        res.costOp / 1e4,          '万元/年'
    '年化总成本(全年8760h核准)', res.fitFY / 1e4,           '万元/年，NaN 表示未启用核准'
    '单位负荷年化用电成本',      res.fit / max(R.energyLoad, eps), '元/(MWh·年)'
    '外层求解模式',              gopt_tern(res.fixedMode, '固定配置（仅内层调度）', ...
                                 gopt_tern(res.twoStage, '两阶段 PSO（典型日粗搜 + 目标口径精搜）+ 局部精修', ...
                                   '单阶段 PSO + 局部精修')), ''
    '内层求解次数',              res.nEval,                 '次'
    '其中局部精修次数',          res.refineN,               '次'
    '寻优耗时',                  res.wall,                  's'
    '最终解是否贴搜索边界',      hitTxt, ''
    };
% 上面那行「是否贴界」只给结论；具体是哪个维度、扩没扩界，写在紧随其后的几行里
% （由 res.boundLog 逐条落表），这样 Excel 里既能一眼看到结论，也能追到过程。
if ~isempty(res.boundLog)
    C1(end + 1, :) = {'边界诊断明细', sprintf('共 %d 条（见下方逐条）', numel(res.boundLog)), ''};
    for b = 1:numel(res.boundLog)
        C1(end + 1, :) = {sprintf('  诊断 %d', b), res.boundLog{b}, ''};   %#ok<AGROW>
    end
end
if ~isempty(res.stageInfo)
    for s = 1:numel(res.stageInfo)
        if isempty(res.stageInfo(s).name), continue; end
        C1(end + 1, :) = {sprintf('阶段 %d', s), sprintf('%s：评估 %d 次，耗时 %.1f s，成本 %.2f 万元/年（%s）', ...
            res.stageInfo(s).name, res.stageInfo(s).nEval, res.stageInfo(s).wall, ...
            res.stageInfo(s).fit / 1e4, res.stageInfo(s).note), ''};   %#ok<AGROW>
    end
end
writecell(C1, outFile, 'Sheet', '最优配置');

%% ---------- 2. 成本与电量 ----------
% 储能那条说明里的「寿命」必须报实际用到的年数：开启循环寿命耦合后，寿命不再是
% cfg.cost.ess.life 这个常数，而是由本次调度反算出来的（见 gopt_ess_life）。
% ★ 本轮起「单位投资」不再必然是常数：若 cfg.cost.mode = 'tiered'，说明列里直接给出
%   本次命中的档位与插值单价（capD.u.*.note，形如「落在第 3 档（区间 20~50 MW，单价
%   3100 元/kW）」），逐档明细见「分档明细」工作表。note 里已经含单价，故不再重复打印。
essLifeTxt = sprintf('功率：%s + 容量：%s；寿命 %.2f 年（%s）', ...
    capD.u.essP.note, capD.u.essE.note, capD.lifeEss, ...
    gopt_tern(strcmp(capD.life.limited, 'cycle'), ...
        sprintf('受循环寿命 %g 次限制', capD.life.cycleLife), '受日历寿命限制'));
C2 = {
    '成本项',                        '数值(万元/年)',   '说明'
    '购电成本',        R.costBuy / 1e4,     'Σ 购电价 x 购电量'
    '售电收益',        R.revenueSell / 1e4, 'Σ 售电价 x 售电量（抵减）'
    '自发电运行成本',  R.costGenVar / 1e4,  sprintf('实发电量 x %.2f 元/kWh（燃料+变动运维；弃电部分不付费）', cfg.cost.gen.varCost)
    '净运行成本',      R.cost / 1e4,        '购电成本 - 售电收益 + 自发电运行成本'
    '初始投资合计(一次投资额)', capD.totalInv / 1e4, ...
        sprintf('= Σ 容量 x 单位投资单价（口径：cfg.cost.mode = ''%s''）；逐档明细见「分档明细」工作表', capD.costMode)
    '光伏年化投资(含运维)', capD.pv / 1e4,  sprintf('%s；寿命 %d 年，运维 %.1f%%/年', ...
        capD.u.pv.note, cfg.cost.pv.life, cfg.cost.pv.opexRate*100)
    '风电年化投资(含运维)', capD.wt / 1e4,  sprintf('%s；寿命 %d 年，运维 %.1f%%/年', ...
        capD.u.wt.note, cfg.cost.wt.life, cfg.cost.wt.opexRate*100)
    '储能年化投资(含运维)', capD.ess / 1e4, essLifeTxt
    '自发电年化投资(含运维)', capD.gen / 1e4, sprintf('%s；寿命 %d 年，运维 %.1f%%/年；年化费用率 %.6f', ...
        capD.genD.u.note, cfg.cost.gen.life, cfg.cost.gen.opexRate*100, capD.genD.a)
    '自发电度电成本(元/kWh)', gopt_tern(cap(5) > 0, capD.genD.lcoe, NaN), ...
        '= （自发电年化投资 + 自发电运行成本）/ 实发电量；分母为实发量，弃电越多该值越高'
    '年化总成本',      (capD.total + R.cost) / 1e4, '运行成本 + 投资成本（含自发电两块）'
    };
writecell(C2, outFile, 'Sheet', '成本与电量');

C2b = {
    '电量项',             '数值(MWh/年)',  '说明'
    '负荷电量',            R.energyLoad,  '典型日加权年化'
    '购电量',              R.energyBuy,   ''
    '售电量',              R.energySell,  ''
    '储能充电量',          R.energyCh,    ''
    '储能放电量',          R.energyDis,   ''
    '光伏+风电可用量',     R.energyRenAvail, '绿电口径（本轮起不含自发电）'
    '自发电可用量',        R.energyGenAvail, '= 自发电容量 x Σ标幺'
    '自发电实发电量',      R.energyGen,   '= 可用量 - 弃自发电'
    '可再生+自发电可用量', R.energyRen,   '光伏 + 风电 + 自发电（合计口径，便于与旧版对照）'
    '弃风弃光电量',        R.energyCurt,  '= 弃光伏 + 弃风电 + 弃自发电'
    '  其中 弃光伏',       R.energyCurtPV, ''
    '  其中 弃风电',       R.energyCurtWT, ''
    '  其中 弃自发电',     R.energyCurtGen, ''
    '光伏+风电利用率(%)',  gopt_tern(R.energyRenAvail > 1e-9, R.utilRenOnly * 100, NaN), ...
        '= 1 - （弃光伏 + 弃风电）/（光伏+风电可用量）；未装光伏/风电时无定义（留空）'
    '自发电利用率(%)',     gopt_tern(R.energyGenAvail > 1e-9, R.utilGen * 100, NaN), ...
        '= 1 - 弃自发电 / 自发电可用量；未建自发电时无定义（留空）'
    '可再生能源利用率(%)', gopt_tern(R.energyRen > 1e-9, R.utilRen * 100, NaN), ...
        '合计口径（光伏+风电+自发电可用量作分母），与旧版一致'
    };
writecell(C2b, outFile, 'Sheet', '成本与电量', 'Range', sprintf('A%d', size(C2, 1) + 3));

%% ---------- 2b. 分档明细（★ 本轮新增：成本如何随装机容量对应）----------
%  为什么单独开一张表：分档单价是非线性的，只报一个总投资额，读者看不出单价到底取了
%  哪一档、容量再大一档钱会差多少。单元格全部由 gopt_tier_detail_cells 生成
%  （甲：本次命中档 / 乙：各档贡献的投资额 / 丙：逐档对照），这里只负责落盘。
writecell(gopt_tier_detail_cells(cap, capD, cfg), outFile, 'Sheet', '分档明细');

%% ---------- 3/4. 调度结果 ----------
% 列数由 18 扩到 21（★）：自发电拆出「出力(MW) + 标幺」，弃电拆成「弃光伏/弃风电/弃自发电」。
hdr = {'序号','典型日','时刻(h)','代表天数','购电价(元/kWh)','售电价(元/kWh)', ...
       '负荷(MW)','光伏出力(MW)','风电出力(MW)','自发电出力(MW)','自发电标幺(-)', ...
       '购电量(MW)','售电量(MW)','储能充电(MW)','储能放电(MW)','储能净出力(MW)', ...
       'SOC(MWh)','SOC(%)','弃光伏(MW)','弃风电(MW)','弃自发电(MW)'};
writecell([hdr; gopt_sheet(sc,  R)],   outFile, 'Sheet', '典型日调度');
writecell([hdr; gopt_sheet(scw, Rw)],  outFile, 'Sheet', '典型周调度');

%% ---------- 5. 全年 8760 h 逐小时结果（SOC 充放电输出的数据源）----------
% 口径优先级：
%   ① 全年 8760 h 模式        -> 直接用该次求解结果（最真实）
%   ② 典型日模式 + 全年核准   -> 用核准结果（在典型日最优配置上用 8760 h 重解）
%   ③ 都没有                  -> 现场补做一次全年核准，保证一定拿得到 8760 行
[Rs, tag] = gopt_year_result(res, ds, sc, cfg);
nHr = 8760;

%% ---------- 5a. 全年 SOC 充放电汇总（两列）----------
C9 = {
    '全年储能充电量(MWh)',  '全年储能放电量(MWh)'
    Rs.energyCh,            Rs.energyDis
    '口径说明',             tag
    };
writecell(C9, outFile, 'Sheet', '全年SOC充放电');
fprintf('[输出] 全年 SOC 充放电：充电 %.2f MWh，放电 %.2f MWh（%s）\n', ...
    Rs.energyCh, Rs.energyDis, tag);

%% ---------- 5b. 全年 SOC 充放电逐小时明细（8760 行）----------
% 两列物理量：储能充电功率 / 储能放电功率 [MW]。时间步长 Δt = 1 h，
% 故某一行的数值在数量上等于该小时充入 / 放出的电量 [MWh]，可直接按列求和得全年电量。
% 两列均为非负，同一小时不会同时非零（求解后已做充放互斥性核查）。
if ~isempty(Rs) && isfield(Rs, 'P_ch') && isfield(Rs, 'P_dis') ...
        && numel(Rs.P_ch) == nHr && numel(Rs.P_dis) == nHr
    hdrSoc = {'时间(h)', '储能充电(MW)', '储能放电(MW)'};
    Msoc   = [(1:nHr)', Rs.P_ch(:), Rs.P_dis(:)];
    writecell(hdrSoc, outFile, 'Sheet', '全年SOC逐小时');
    writematrix(Msoc, outFile, 'Sheet', '全年SOC逐小时', 'Range', 'A2');
    fprintf('[输出] 全年 SOC 逐小时明细：%d 行（时间序号 + 充电 + 放电），表内累计充 %.2f / 放 %.2f MWh\n', ...
        nHr, sum(Msoc(:, 2)), sum(Msoc(:, 3)));
else
    warning(['未能获得长度 8760 的全年逐小时调度结果（实际 %d 行），' ...
        '已跳过「全年SOC逐小时」工作表。'], numel(Rs.P_ch));
end

%% ---------- 6. PSO 收敛 ----------
h = res.hist;
C5 = cell(size(h, 1) + 1, 3);
C5(1, :) = {'迭代代数', '群体最优(万元/年)', '种群均值(万元/年)'};
for i = 1:size(h, 1)
    C5{i+1, 1} = i - 1;
    C5{i+1, 2} = h(i, 1) / 1e4;
    if size(h, 2) >= 2, C5{i+1, 3} = h(i, 2) / 1e4; else, C5{i+1, 3} = h(i, 1) / 1e4; end
end
writecell(C5, outFile, 'Sheet', 'PSO收敛');

%% ---------- 7. 搜索设置 ----------
C6 = {
    '项目', '内容'
    '优化变量1 光伏容量',   sprintf('搜索范围 [%.4g, %.4g] MW',  cfg.pso.lb(1), cfg.pso.ub(1))
    '优化变量2 风电容量',   sprintf('搜索范围 [%.4g, %.4g] MW',  cfg.pso.lb(2), cfg.pso.ub(2))
    '优化变量3 储能功率',   sprintf('搜索范围 [%.4g, %.4g] MW',  cfg.pso.lb(3), cfg.pso.ub(3))
    '优化变量4 储能时长',   sprintf('搜索范围 [%.4g, %.4g] h',   cfg.pso.lb(4), cfg.pso.ub(4))
    '优化变量5 自发电容量', sprintf('搜索范围 [%.4g, %.4g] MW',  cfg.pso.lb(5), cfg.pso.ub(5))
    '储能容量关系',         '储能容量(MWh) = 储能功率(MW) x 储能时长(h)'
    'Gen 列口径',           sprintf('cfg.data.genMode = ''%s''（pu = 标幺出力 x 自发电容量；mw = 直接给 MW）', cfg.data.genMode)
    '--- 投资单价口径（★ 本轮新增）---', ''
    '成本计价口径',         sprintf('cfg.cost.mode = ''%s''（%s）', gopt_cost_mode(cfg), ...
                            gopt_tern(strcmp(gopt_cost_mode(cfg), 'tiered'), ...
                            '分档单价：单价按容量分段线性插值，投资额 = 容量 x 插值单价', ...
                            '常数单价：单价与容量无关，投资额 = 容量 x 常数单价'))
    '光伏分档单价表',       gopt_tier_summary(gopt_pget(cfg.cost.pv, 'tier', []), 'MW', '元/kW')
    '风电分档单价表',       gopt_tier_summary(gopt_pget(cfg.cost.wt, 'tier', []), 'MW', '元/kW')
    '储能功率分档单价表',   gopt_tier_summary(gopt_pget(cfg.cost.ess, 'tierP', []), 'MW', '元/kW')
    '储能容量分档单价表',   gopt_tier_summary(gopt_pget(cfg.cost.ess, 'tierE', []), 'MWh', '元/kWh')
    '分档明细位置',         '本工作簿「分档明细」工作表：甲=本次命中档 / 乙=各档贡献的投资额（链式分解）/ 丙=逐档对照'
    '分档跳变点护栏',       sprintf(['cfg.cost.allowTierEdgeBound = %d（%s）；' ...
                            '启动时已检查：上界是否压在分档表的封顶档位（该处单价向下跳变）'], ...
                            cfg.cost.allowTierEdgeBound, ...
                            gopt_tern(cfg.cost.allowTierEdgeBound, '已按要求放行、仅打印警告', '已启用：压到跳变点直接报错'))
    '敏感性图档位标注',     sprintf('cfg.sens.markTiers = %d（%s）', ...
                            gopt_pget(cfg.sens, 'markTiers', false), ...
                            gopt_tern(logical(gopt_pget(cfg.sens, 'markTiers', false)), ...
                            '在容量轴上用灰虚线标出分档档位（封顶档位为点划线）', '未标注'))
    '自发电成本口径',       sprintf('投资 %.0f 元/kW（无分档表，恒为常数单价）、寿命 %g 年、运维 %.1f%%/年；运行 %.2f 元/kWh（按实发电量计）', ...
                            cfg.cost.gen.capex, cfg.cost.gen.life, cfg.cost.gen.opexRate*100, cfg.cost.gen.varCost)
    '自发电弃电口径',       sprintf('cfg.const.genCurtMode = ''%s''', cfg.const.genCurtMode)
    '--- PSO 调优（本轮新增）---', ''
    '搜索架构',             gopt_tern(cfg.pso.twoStage, ...
                            sprintf('两阶段（阶段A 典型日 K=%g 粗搜 -> 阶段B 目标口径精搜）', ...
                            gopt_pget(cfg.pso.stageA, 'K', 12)), '单阶段')
    'PSO 粒子数 x 迭代数',  sprintf('%d x %d（阶段B/%s）', cfg.pso.nPop, cfg.pso.maxIter, sc.mode)
    '阶段A 粒子数 x 迭代数', gopt_tern(cfg.pso.twoStage, ...
                            sprintf('%g x %g', gopt_pget(cfg.pso.stageA,'nPop',40), ...
                            gopt_pget(cfg.pso.stageA,'maxIter',60)), '-')
    '边界诊断与自动外扩',   gopt_tern(cfg.pso.boundCheck, ...
                            sprintf('开启（贴界判据 %.1f%% 区间宽，外扩 x%g，最多 %g 轮；储能时长与自发电容量锁定不外扩）', ...
                            cfg.pso.boundFrac*100, cfg.pso.expandFactor, cfg.pso.expandMax), '关闭')
    '初始化方式',           cfg.pso.initMode
    '多种群 / 逃逸重启',    sprintf('子群 %g 个（每 %g 代交换最优）；每代重置最差 %.0f%%；逃逸 %g 次 x 幅度 %g', ...
                            cfg.pso.multiSwarm, cfg.pso.exchangeIt, cfg.pso.resetFrac*100, ...
                            cfg.pso.escapeTries, cfg.pso.escapeAmp)
    '参数自适应',           gopt_tern(cfg.pso.adaptive, sprintf('开启（w %s %.2f->%.2f；c1 %.2f->%.2f；c2 %.2f->%.2f）', ...
                            cfg.pso.wShape, cfg.pso.wMax, cfg.pso.wMin, cfg.pso.c1, cfg.pso.c1End, cfg.pso.c2, cfg.pso.c2End), '关闭')
    '局部精修',             gopt_tern(cfg.pso.localRefine, ...
                            sprintf('开启（%s + Nelder-Mead %s）', cfg.pso.refineMethod, ...
                            gopt_tern(cfg.pso.refineNM, '收尾', '关闭')), '关闭')
    '随机种子',             num2str(cfg.pso.seed)
    };
writecell(C6, outFile, 'Sheet', '搜索设置');

%% ---------- 8. 数据说明 ----------
% 储能寿命口径写在这里便于日后复核：同一个配置，开启/关闭循环寿命耦合会得到
% 不同的年化投资成本，表里必须留下「本次到底用的哪种口径」的痕迹。
if capD.life.enable
    lifeTxt = sprintf('lifeMode = %s，额定循环寿命 %.0f 次（口径 %s，年等效循环 %.2f 次/年）-> 实际寿命 %.2f 年（%s）', ...
        capD.life.mode, capD.life.cycleLife, capD.life.basis, capD.life.cycles, capD.lifeEss, ...
        gopt_tern(strcmp(capD.life.limited, 'cycle'), '受循环寿命限制', '受日历寿命限制'));
else
    lifeTxt = sprintf('lifeMode = %s（未启用循环寿命耦合）-> 实际寿命 = 日历寿命 %.2f 年', ...
        capD.life.mode, capD.lifeEss);
end
C7 = {
    '项目', '内容'
    '数据文件', ds.file
    '数据时长', sprintf('%d 小时 / %d 天', ds.T, ds.nDay)
    '时间尺度模式', sc.mode
    'Gen 列口径', sprintf('cfg.data.genMode = ''%s''（pu：自发电出力 = 容量 x 标幺；mw：直接给 MW）', cfg.data.genMode)
    '成本计价口径', sprintf(['cfg.cost.mode = ''%s''；分档规则：容量 <= 表中倒数第二行档位（500）' ...
        '分段线性插值，容量 >= 500 直接取最后一行（20000 档）的单价；储能功率与容量各自独立分档；' ...
        '厂内自发电无分档表'], gopt_cost_mode(cfg))
    '自发电成本口径', sprintf('投资 %.0f 元/kW / 寿命 %g 年 / 运维 %.1f%%/年；运行 %.2f 元/kWh（按实发电量）', ...
        cfg.cost.gen.capex, cfg.cost.gen.life, cfg.cost.gen.opexRate*100, cfg.cost.gen.varCost)
    '自发电弃电口径', sprintf('cfg.const.genCurtMode = ''%s''（economic：按边际成本自动排序，先弃自发电）', cfg.const.genCurtMode)
    '典型日个数', gopt_tern(~isempty(sc.typDay), num2str(numel(sc.typDay)), '-')
    '典型日代表天数', gopt_tern(~isempty(sc.typDay), mat2str([sc.typDay.weight]), '-')
    '典型日代表日(自然日)', gopt_tern(~isempty(sc.typDay) && isfield(sc.typDay, 'repDay'), ...
        mat2str([sc.typDay.repDay]), '-')
    '典型日图曲线来源', gopt_tern(strcmpi(sc.mode, 'full_year'), ...
        '全年 8760 h 结果中截取真实代表日的 24 h（聚类仅用于出图）', ...
        '典型日场景本身（24K h 簇内代表曲线）')
    '零负荷原始小时数', num2str(ds.repair.nRaw)
    '零负荷已修复小时数', num2str(ds.repair.nFixed)
    'SOC 循环周期数', num2str(numel(sc.cyclicGroups))
    '储能寿命口径', lifeTxt
    '功率平衡最大残差(MW)', num2str(R.maxResid, '%.3e')
    '分源弃电合计校验(MWh)', sprintf('弃光伏 %.1f + 弃风电 %.1f + 弃自发电 %.1f = %.1f（合计字段 %.1f，差 %.2e）', ...
        R.energyCurtPV, R.energyCurtWT, R.energyCurtGen, ...
        R.energyCurtPV + R.energyCurtWT + R.energyCurtGen, R.energyCurt, ...
        abs(R.energyCurt - (R.energyCurtPV + R.energyCurtWT + R.energyCurtGen)))
    '自发电电量校验(MWh)', sprintf('可用 %.1f - 弃 %.1f = 实发 %.1f（差 %.2e）', ...
        R.energyGenAvail, R.energyCurtGen, R.energyGen, ...
        abs(R.energyGenAvail - R.energyCurtGen - R.energyGen))
    '同时充放电小时数', num2str(R.nSimChDis)
    '同时购售电小时数', num2str(R.nSimBuySell)
    '内层求解器', 'intlinprog (MATLAB Optimization Toolbox)'
    '全年SOC逐小时表', sprintf('%d 行 x 3 列（时间序号 / 充电MW / 放电MW），Δt=1h 故数值上即 MWh', nHr)
    '生成时间', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'))
    };
writecell(C7, outFile, 'Sheet', '数据说明');

%% ---------- 9. 全年核准 ----------
if ~isnan(res.fitFY) && ~isempty(res.Rfy)
    Rf = res.Rfy;
    C8 = {
        '项目', '内容'
        '全年8760h 年化总成本(万元/年)',   res.fitFY / 1e4
        '全年8760h 年化运行成本(万元/年)', Rf.cost / 1e4
        '典型日模型 年化总成本(万元/年)',  res.fit / 1e4
        '相对偏差(%)',                  res.dFitFY / res.fit * 100
        '全年 购电量(MWh)',             Rf.energyBuy
        '全年 售电量(MWh)',             Rf.energySell
        '全年 储能充电量(MWh)',         Rf.energyCh
        '全年 储能放电量(MWh)',         Rf.energyDis
        '全年 弃风弃光电量(MWh)',       Rf.energyCurt
        '全年   其中 弃光伏(MWh)',      Rf.energyCurtPV
        '全年   其中 弃风电(MWh)',      Rf.energyCurtWT
        '全年   其中 弃自发电(MWh)',    Rf.energyCurtGen
        '全年 自发电实发电量(MWh)',     Rf.energyGen
        '全年 自发电利用率(%)',         Rf.utilGen * 100
        '全年 光伏+风电利用率(%)',      Rf.utilRenOnly * 100
        '全年 可再生能源利用率(%)',     Rf.utilRen * 100
        '全年 功率平衡最大残差(MW)',    Rf.maxResid
        '说明', '典型日模型强制每典型日 SOC 日循环，属保守近似，成本通常略高于全年口径；'
        };
    writecell(C8, outFile, 'Sheet', '全年核准');
end

%% ---------- 10. 专业化指标（单独一张工作表）----------
% 为什么单独成表而不是塞进「成本与电量」：这张表的行数随开关变化（有几项指标、
% 口径说明区多长都不固定），单独一张表最省心，也便于与「成本与电量」交叉核对。
% 本函数开头已经 delete 掉旧工作簿并重建，因此不存在 writecell 残留旧内容的坑。
if isfield(res, 'pro') && ~isempty(res.pro) && isfield(cfg, 'met') ...
        && isfield(cfg.met, 'writeExcel') && logical(cfg.met.writeExcel)
    P = res.pro;
    genNumTxt = gopt_tern(strcmp(P.lcoeGenNumMode, 'total'), '年化总成本', '光伏+风电+储能年化投资与运维');
    genDenTxt = gopt_tern(strcmp(P.lcoeGenDenMode, 'avail'), '可用发电量（不扣弃电）', '扣掉弃电后的实际发电量');
    conNumTxt = gopt_tern(strcmp(P.lcoeConNumMode, 'asset'), '光伏+风电+储能年化投资与运维', '年化总成本');
    conDenTxt = gopt_tern(strcmp(P.lcoeConDenMode, 'self'), '自用绿电量（含储能循环损耗）', ...
        gopt_tern(strcmp(P.lcoeConDenMode, 'load'), '负荷总电量', '绿电供负荷电量 = 负荷电量 - 购电量'));

    C10 = {
        '指标', '数值', '单位', '口径 / 说明'
        '成本口径', P.refTag, '', '④⑤ 两项成本类指标采用的成本来源（cfg.met.costBasis）'
        '储能年损耗电量', P.lossTot, '万kWh/年', '年充电量 - 年放电量（含充放转换损耗与自放电损耗）'
        '  其中 充放转换损耗', P.lossConv, '万kWh/年', '= 总损耗 - 自放电损耗'
        '  其中 自放电损耗', P.lossSelf, '万kWh/年', '= etaCh x 年充电量 - 年放电量 / etaDis'
        '储能年损耗占充电量比例', P.lossRate, '%', '= 年损耗电量 / 年充电量'
        '用户绿电占用电量比例', P.greenRate, '%', '= （负荷电量 - 购电量）/ 负荷电量'
        '  其中 绿电供负荷电量', P.E_greenLoad, 'MWh/年', '= 负荷电量 - 购电量（已自动扣除储能循环损耗）'
        '  其中 年负荷电量', P.E_load, 'MWh/年', '与成本口径同步（典型日加权年化 / 全年 8760 h）'
        '新能源发电量消纳比例', gopt_tern(P.noRen, NaN, P.absorbRate), '%', ...
            gopt_tern(P.noRen, '不适用：本方案不含光伏/风电装机，绿电发电量为 0，该比例为 0/0', ...
            '= （绿电发电量 - 弃电量）/ 绿电发电量 = 100 - 弃电率（绿电不含自发电）')
        '  其中 绿电发电量', P.m.E_ren, 'MWh/年', gopt_tern(P.m.genInGreen, '光伏 + 风电 + 自发电（cfg.met.genInGreen = true）', '光伏 + 风电（本轮口径，不含自发电）')
        '  其中 弃风弃光电量', P.m.E_curt, 'MWh/年', '本轮口径下只含弃光伏 + 弃风电'
        '  其中 绿电上网电量', P.m.E_sellGreen, 'MWh/年', '按「上网全部归绿电」归属后的绿电上网电量'
        '  其中 自发电上网(外溢)', P.m.E_sellGen, 'MWh/年', '超出绿电可上网余量的部分，单列不并入绿电（通常为 0）'
        '--- 厂内自发电（单列，不计入绿电）---', '', '', ''
        '自发电装机容量', P.genCap, 'MW', sprintf('第 5 维优化变量；投资 %.0f 元/kW、寿命 %g 年、运维 %.1f%%/年', ...
            P.genCapex, P.genLife, P.genOpex*100)
        '自发电可用电量', P.genEAvail, 'MWh/年', '= 容量 x Σ标幺出力（年化加权）'
        '自发电实发电量', P.genE, 'MWh/年', '= 可用电量 - 弃自发电'
        '自发电弃电量', P.genCurt, 'MWh/年', '分源弃电变量 P_curt,Gn 的年累计'
        '自发电利用率', P.genUseRate, '%', '= 实发电量 / 可用电量'
        '自发电年化投资', P.genInvAnn / 1e4, '万元/年', sprintf('= 容量(kW) x %.0f 元/kW x 年化费用率 %.6f', P.genCapex, P.genA)
        '自发电年运行成本', P.genVarAnn / 1e4, '万元/年', sprintf('= 实发电量 x %.2f 元/kWh（弃电部分不付费）', P.genVarCost)
        '自发电度电成本', P.genLcoe, '元/kWh', '= （年化投资 + 年运行成本）/ 实发电量；分母用实发量，弃电越多该值越高'
        '  其中 投资折算', P.genLcoeCap, '元/kWh', '= 年化投资 /（实发电量 x 1000）'
        '  其中 运行成本', P.genLcoeVar, '元/kWh', '= cfg.cost.gen.varCost'
        '自发电供负荷电量', P.genLoadE, 'MWh/年', '= min(实发电量, 负荷电量 - 购电量)，即自发电优先自用'
        '自发电占负荷电量比例', P.genRate, '%', '= 自发电供负荷电量 / 负荷电量'
        '比价参照 光伏全成本', P.refLcoePV, '元/kWh', '= 光伏年化投资 /（光伏扣弃电发电量 x 1000），与自发电度电成本同算法'
        '比价参照 风电全成本', P.refLcoeWT, '元/kWh', '= 风电年化投资 /（风电扣弃电发电量 x 1000）'
        '比价参照 购电均价', P.basePrice, '元/kWh', '= 基准购电成本 / 年用电量（全成本口径下自发电最便宜）'
        '用电成本综合节省率', P.saveRate, '%', '= （基准购电成本 - 年化总成本）/ 基准购电成本'
        '  基准购电成本', P.costBase / 1e4, '万元/年', '不建任何绿电、负荷全靠电网买电的年电费（逐时购电价加权，不含投资）'
        '  年化总成本', P.costRef / 1e4, '万元/年', '年化投资成本 + 年化运行净成本'
        '基准购电均价', P.basePrice, '元/kWh', '= 基准购电成本 / 年用电量'
        '用户综合度电成本', P.avgPrice, '元/kWh', '= 年化总成本 / 年用电量'
        '绿电度电成本 LCOE（发电口径）', P.lcoeGen, '元/kWh', sprintf('不含税；分子 = %s；分母 = %s', genNumTxt, genDenTxt)
        '  其中 分子', P.numGen / 1e4, '万元/年', ''
        '  其中 分母', P.denGen, 'MWh/年', ''
        'LCOE 发电口径（含自发电对照）', gopt_tern(isfield(cfg.met, 'genLcoeRef') && logical(cfg.met.genLcoeRef), P.lcoeGenWG, NaN), '元/kWh', ...
            '复刻上一版口径（分子含自发电投资、分母含自发电发电量），仅用于与历史结果纵向对比'
        '绿电度电成本 LCOE（消纳口径）', P.lcoeCon, '元/kWh', sprintf('不含税；分子 = %s；分母 = %s', conNumTxt, conDenTxt)
        '  其中 分子', P.numCon / 1e4, '万元/年', ''
        '  其中 分母', P.denCon, 'MWh/年', ''
        };
    if P.essL.enable
        C10(end + 1, :) = {'储能额定循环寿命', P.essL.cycleLife, '次', 'cfg.ess.cycleLife'};
        C10(end + 1, :) = {'储能年等效循环次数', P.essL.cycles, '次/年', ['循环次数口径：' P.essL.basis]};
        C10(end + 1, :) = {'储能循环折算寿命', P.essL.lifeCyc, '年', '= 额定循环寿命 / 年等效循环次数'};
        C10(end + 1, :) = {'储能实际寿命(用于年化投资)', P.essL.lifeUsed, '年', ...
            gopt_tern(strcmp(P.essL.limited, 'cycle'), '受循环寿命限制', '受日历寿命限制')};
    end
    writecell(C10, outFile, 'Sheet', '专业指标');
    if isfield(P, 'formulaLines') && ~isempty(P.formulaLines)
        r0 = size(C10, 1) + 2;
        writecell({'口径与公式说明', '（与命令行日志共用同一份文本，由 gopt_pro_formula_lines 生成）'}, ...
            outFile, 'Sheet', '专业指标', 'Range', sprintf('A%d', r0));
        writecell(P.formulaLines, outFile, 'Sheet', '专业指标', 'Range', sprintf('A%d', r0 + 1));
    end
    fprintf('[输出] 专业化指标已写入「专业指标」工作表（%d 项指标 + %d 行口径说明）\n', ...
        size(C10, 1) - 1, size(P.formulaLines, 1));
end

fprintf('[输出] 结果已写入：%s\n', outFile);

if cfg.out.saveMat
    matFile = fullfile(cfg.path.outDir, 'optimization_results.mat');
    save(matFile, 'res', 'sc', 'scw', 'Rw', 'cfg', 'capD');
    fprintf('[输出] 完整结果已存为：%s\n', matFile);
end
end

function [Rs, tag] = gopt_year_result(res, ds, sc, cfg)
%GOPT_YEAR_RESULT  取一份覆盖全年 8760 h 的调度结果，保证足以支撑逐小时输出
%   返回
%     Rs  : 求解结果结构体（含 P_ch / P_dis / E_soc / socPct / energyCh / energyDis 等），
%           正常情况 numel(Rs.P_ch) == 8760；求解失败时返回 []。
%     tag : 该结果的口径说明文字，会写进 Excel 的「口径说明」单元格。
%
%   口径优先级（与成本口径保持一致，便于两处交叉核对）：
%     ① cfg.time.mode = 'full_year'
%        本次优化的内层就是在 8760 h 上求解的，直接用 res.R，无需任何额外计算。
%     ② 典型日模式 且 cfg.out.fullYearCheck 已开启
%        主流程第 5b 段已经用 8760 h 在最优配置上重解过一次（res.Rfy），直接复用，
%        避免重复求解；该结果与典型日模型只差「时域压缩」，是保真度最高的现成数据。
%     ③ 典型日模式 且 未做全年核准
%        典型日模型的解只有 24K 行（默认 288 行），无法展开成 8760 h。此时现场
%        补做一次全年核准：沿用同一最优配置与同一 SOC 循环周期假设，只把时域换成
%        8760 h。这样「逐小时表」在任何配置组合下都不会缺行。
if strcmpi(sc.mode, 'full_year')
    Rs  = res.R;
    tag = '全年 8760 h 逐小时调度结果';
    return;
end

if ~isnan(res.fitFY) && ~isempty(res.Rfy)
    Rs  = res.Rfy;
    tag = '全年 8760 h 核准结果（在典型日最优配置上重解）';
    return;
end

% 情况 ③：现场补做全年核准
fprintf('[输出] 当前为典型日模式且未开启全年核准，为输出 8760 h 逐小时明细，临时补做一次全年核算...\n');
cfgFY = cfg;
cfgFY.time.mode = 'full_year';
cfgFY.io.quiet  = true;
scFY  = gopt_build_scenario(ds, cfgFY);
Rs    = gopt_milp(res.cap, scFY, cfgFY);
if Rs.ok
    tag = '全年 8760 h 临时核准结果（导出时补算，未参与寻优）';
else
    warning('补做的全年核准求解失败，无法输出逐小时明细。');
    Rs  = [];
    tag = '全年核准失败';
end
end

function D = gopt_sheet(sc, R)
%GOPT_SHEET  把一个调度场景整理成 Excel 单元格矩阵（不含表头，共 21 列）
%   ★ 本轮改动：
%     · 「自发电」由 1 列扩成 2 列（出力 MW + 标幺）：Gen 列现在是标幺出力，
%       只给出力看不出「是数据变了还是容量变了」，两列并排才能追溯；
%     · 「弃风弃光」由 1 列拆成 3 列（弃光伏 / 弃风电 / 弃自发电），
%       与内层的分源弃电变量一一对应，便于核对「谁被弃了」。
T = sc.T;
D = cell(T, 21);
w = sc.w(:);
% 自发电容量（MW）：由调度结果里的 cap 取；老调用没有该字段时退化为「按当前出力/标幺」
C_gen = 0;
if isfield(R, 'cap') && numel(R.cap) >= 5, C_gen = R.cap(5); end
for t = 1:T
    D{t, 1}  = t;
    D{t, 2}  = ceil(t / 24);
    D{t, 3}  = mod(t - 1, 24) + 1;
    D{t, 4}  = w(t);
    D{t, 5}  = sc.buy(t);
    D{t, 6}  = sc.sell(t);
    D{t, 7}  = sc.load(t);
    D{t, 8}  = R.P_pv(t);
    D{t, 9}  = R.P_wt(t);
    D{t, 10} = R.P_gen(t);           % 自发电实际出力 [MW] = 容量 x 标幺 - 弃自发电
    D{t, 11} = sc.Gen(t);            % 自发电标幺出力 [-]
    D{t, 12} = R.P_buy(t);
    D{t, 13} = R.P_sell(t);
    D{t, 14} = R.P_ch(t);            % 储能优化调度充电 (MW)
    D{t, 15} = R.P_dis(t);           % 储能优化调度放电 (MW)
    D{t, 16} = R.P_dis(t) - R.P_ch(t);
    D{t, 17} = R.E_soc(t);
    D{t, 18} = R.socPct(t);
    D{t, 19} = R.P_curtPV(t);        % 弃光伏
    D{t, 20} = R.P_curtWT(t);        % 弃风电
    D{t, 21} = R.P_curtGen(t);       % 弃自发电
end
end

function s = gopt_pct(v)
%GOPT_PCT  把比率（0~1 小数）格式化成日志用字符串
%   为什么要单独一个函数：某一路电源没装机时，它的「利用率 / 占比」在数学上是 0/0，
%   程序里一律存成 NaN。NaN 直接丢进 fprintf 会打出「NaN %」，既难看又容易被当成报错；
%   更重要的是「不适用」这个信息本身必须传出去 —— 否则读者会以为那个指标正常。
if ~isfinite(v)
    s = '  不适用（分母为 0）';
else
    s = sprintf('%7.2f %%', v * 100);
end
end

function s = gopt_lcoe_cmp(lcoeGen, lcoePV, lcoeWT, buyAvg)
%GOPT_LCOE_CMP  拼出「自发电 / 光伏 / 风电 / 购电均价」的全成本比价字符串
%   未装机电源的度电成本无定义（0/0 -> NaN），这里直接略去而不是打成 "光伏 NaN"。
%   而且只有在四类数据齐全时才给出「谁最便宜」的排序 —— 缺项时排序会得出片面结论。
items = {sprintf('自发电 %.4f', lcoeGen), sprintf('光伏 %.4f', lcoePV), ...
         sprintf('风电 %.4f', lcoeWT), sprintf('购电均价 %.4f', buyAvg)};
names = {'自发电', '光伏', '风电', '购电'};
vals  = [lcoeGen, lcoePV, lcoeWT, buyAvg];
fin   = isfinite(vals);
if ~any(fin)
    s = '全部无定义（本方案各电源均未装机）';
    return;
end
s = strjoin(items(fin), ' / ');
if all(fin)
    [~, ord] = sort(vals);
    s = sprintf('%s  -> 由低到高：%s', s, strjoin(names(ord), ' < '));
end
s = sprintf('%s（元/kWh；未装机的电源无定义，已略去）', s);
end

function v = gopt_tern(c, a, b)
if c, v = a; else, v = b; end
end

function gopt_say(cfg, varargin)
%GOPT_SAY  受 cfg.io.quiet 控制的日志输出
if ~cfg.io.quiet
    fprintf(varargin{:});
end
end

%% ============================================================ 敏感性分析
function SEN = gopt_sensitivity(res, ds, sc, cfg)
%GOPT_SENSITIVITY  敏感性分析：以「底座配置」为基准，逐个维度扫描并重解内层最优调度
%
%   为什么做这个分析：外层 PSO（或手工固定）只给出一个最优点，但「最优」是否真的
%   落在谷底、谷底有多平、换个容量会付出多少代价，都需要在最优解附近再算一圈才看得
%   出来。本函数把最优配置当作基准点（底座），对四个维度各扫一组点：
%       储能功率 P（时长固定为底座时长）
%       储能容量 E（功率固定为底座功率）
%       光伏装机、风电装机（其余维度保持底座值）
%   每个扫描点都调用一次内层 MILP 重算最优运行成本，因此结果口径与主线完全一致。
%
%   性质：**不参与寻优**。全部计算只做「给定 cap 求最优调度」，对最优配置、主线成本
%         与电量指标没有任何影响，纯属事后复盘。
%
%   输入  res 主线结果（用 res.cap 作底座）
%         ds  数据字典（当 cfg.sens.mode 需要另建场景时使用）
%         sc  主线调度场景（cfg.sens.mode = 'follow' 时直接复用，零额外成本）
%         cfg 全局配置（见 cfg_greenopt.m 第 7b 节）
%   输出  SEN 扫描结果结构体（为空 [] 表示未启用或全部子图关闭）
%         .on/.tag/.baseSrc/.capB/.Tfix/.PfixE/.nSolve/.wall
%         .P/.E/.PV/.WT 四组扫描，每组含 .x 及 .cost/.selfRate/.sellRate/
%         .curtRate/.unusedRate/.capexPV/.capexWT/.capexESS/.costOp/.ok

SEN = [];

%% ---- 0. 底座配置 ----
capB    = res.cap(:);
baseSrc = '本次优化结果 res.cap';
if isfield(cfg.sens, 'base') && ~isempty(cfg.sens.base)
    b = cfg.sens.base(:);
    % 允许只写前 4 维（旧参数文件）：自发电那一维按 0 处理，
    % 这样「方案A」这类历史底座配置不用改也能直接复刻。
    if numel(b) == 4, b(5, 1) = 0; end
    assert(numel(b) == 5, ...
        ['cfg.sens.base 必须是 5 维 [光伏MW; 风电MW; 储能功率MW; 储能容量MWh; 自发电MW]，' ...
         '或只写前 4 维（自发电按 0 处理）。']);
    assert(all(b >= 0), 'cfg.sens.base 不能出现负值。');
    capB    = b;
    baseSrc = 'cfg.sens.base（手工指定）';
end
if numel(capB) == 4, capB(5, 1) = 0; end

%% ---- 1. 由子图开关决定需要做哪几组扫描 ----
p      = cfg.sens.panels;
needP  = logical(p.pPower);
needE  = logical(p.pEnergy) || logical(p.util) || logical(p.cost);   % (b)(e)(f) 共用同一组
needPV = logical(p.pvCap);
needWT = logical(p.wtCap);
% ★ 本轮新增：自发电容量两组子图（(g) 成本、(h) 占比与度电成本）
needGen = false;
if isfield(p, 'genCap'),   needGen = needGen || logical(p.genCap);   end
if isfield(p, 'genShare'), needGen = needGen || logical(p.genShare); end
if ~(needP || needE || needPV || needWT || needGen)
    fprintf('[敏感性] 各子图的开关全部为 false，跳过敏感性分析。\n');
    return;
end

%% ---- 2. 扫描用的内层场景（可独立于主线的 cfg.time.mode）----
cfgS = cfg;
cfgS.io.quiet = true;
tag  = lower(char(cfg.time.mode));
switch lower(char(cfg.sens.mode))
    case 'follow'
        % 直接复用主线场景：口径与主线完全一致，且不重复构建场景
        scS = sc;
    case 'typical_days'
        cfgS.time.mode = 'typical_days';
        if isfield(cfg.sens, 'nTypicalDays') && ~isempty(cfg.sens.nTypicalDays)
            cfgS.time.nTypicalDays = cfg.sens.nTypicalDays;
        end
        scS = gopt_build_scenario(ds, cfgS);
        tag = 'typical_days';
    case 'full_year'
        cfgS.time.mode = 'full_year';
        scS = gopt_build_scenario(ds, cfgS);
        tag = 'full_year';
    otherwise
        error(['未知的 cfg.sens.mode：%s\n' ...
               '应为 ''follow'' / ''typical_days'' / ''full_year''。'], cfg.sens.mode);
end

%% ---- 3. 扫描网格与两个派生关系 ----
nP  = max(round(cfg.sens.nPoint), 3);
rel = cfg.sens.relRange;
zr  = cfg.sens.zeroRef;

% 储能功率扫描时固定的「储能时长」：优先取底座自身的 E/P（这样底座点一定落在曲线上）
Tfix = cfg.ess.durationSeed;
if capB(3) > 0 && capB(4) > 0
    Tfix = capB(4) / capB(3);
end
% 储能容量扫描时固定的「储能功率」：底座功率为 0 时用兜底值（日志会明确提示）
PfixE = capB(3);
if PfixE <= 0
    PfixE = cfg.sens.pFallback;
end

gridP  = cfg.sens.gridP(:);
gridE  = cfg.sens.gridE(:);
gridPV = cfg.sens.gridPV(:);
gridWT = cfg.sens.gridWT(:);
gridGen = [];
if isfield(cfg.sens, 'gridGen'), gridGen = cfg.sens.gridGen(:); end
if isempty(gridP),  gridP  = gopt_sens_grid(capB(3), rel, nP, cfg.sens.scanFromZero, zr); end
if isempty(gridE),  gridE  = gopt_sens_grid(capB(4), rel, nP, cfg.sens.scanFromZero, zr); end
if isempty(gridPV), gridPV = gopt_sens_grid(capB(1), rel, nP, cfg.sens.scanFromZero, zr); end
if isempty(gridWT), gridWT = gopt_sens_grid(capB(2), rel, nP, cfg.sens.scanFromZero, zr); end
% 自发电容量这一维的自动网格很特殊：它比购电便宜得多，成本曲线通常是「单边下降」，
% 底座值又往往就在上界附近，用 ±relRange 只能扫到一小段。所以底座为 0 或区间退化时
% 直接用「0 ~ 上界」的全局区间（上界取 cfg.pso.ub(5)，缺省 100 MW）。
if needGen && isempty(gridGen)
    gUB = 100;
    if isfield(cfg, 'pso') && isfield(cfg.pso, 'ub') && numel(cfg.pso.ub) >= 5
        gUB = cfg.pso.ub(5);
    end
    if capB(5) > 0 && ~cfg.sens.scanFromZero
        gridGen = gopt_sens_grid(capB(5), rel, nP, false, zr);
    else
        gridGen = linspace(0, gUB, max(round(nP), 3))';
    end
end

nSweep = needP + needE + needPV + needWT + needGen;
% 实际求解次数按「各组扫描点个数之和」统计（cfg.sens.grid* 填了自定义点时点数可能与 nP 不同）
nSolve = 0;
if needP,   nSolve = nSolve + numel(gridP);   end
if needE,   nSolve = nSolve + numel(gridE);   end
if needPV,  nSolve = nSolve + numel(gridPV);  end
if needWT,  nSolve = nSolve + numel(gridWT);  end
if needGen, nSolve = nSolve + numel(gridGen); end

fprintf('\n[敏感性] 底座（%s）：光伏 %.2f MW | 风电 %.2f MW | 储能 %.2f MW / %.2f MWh (%.2f h)\n', ...
    baseSrc, capB(1), capB(2), capB(3), capB(4), Tfix);
fprintf('[敏感性] 内层口径：%s；%d 组扫描，共 %d 次内层求解（自动网格时每组 %d 点）\n', ...
    tag, nSweep, nSolve, nP);
fprintf('[敏感性] 这是全流程最耗时的一步（该分析不参与寻优，纯粹事后复盘），请耐心等待。\n');

%% ---- 3b. 方法与公式（把本段的扫描构造、网格、判据一并打印出来）----
% 与「9b. 指标口径与关键公式」同一思路：那一段讲的是主线口径，这里补的是敏感性分析
% 自身的定义——底座怎么取、四组扫描各自固定哪几维、网格怎么生成、最低点与谷底平坦区
% 怎么判。打印出来看日志时就不必再回头翻代码。
% 文本由 gopt_sens_formula_lines 统一生成，Excel「敏感性分析」表的说明区引用同一份，
% 保证命令行与表格两处永远不会漂移。
% 注意：网格变量（gridP/gridE/gridPV/gridWT）无论该维度是否需要扫描都会被自动生成，
% 所以必须按 need* 开关置空，否则会把「没做的扫描」也写进说明里。
G = struct('P', [], 'E', [], 'PV', [], 'WT', [], 'GEN', []);
if needP,   G.P   = gridP;   end
if needE,   G.E   = gridE;   end
if needPV,  G.PV  = gridPV;  end
if needWT,  G.WT  = gridWT;  end
if needGen, G.GEN = gridGen; end
FL = gopt_sens_formula_lines(capB, Tfix, PfixE, G, cfg);
fprintf('[敏感性] 方法与公式（本段不参与寻优，纯事后复盘）：\n');
for i = 1:size(FL, 1)
    lab = FL{i, 1};
    val = FL{i, 2};
    if isempty(lab)
        fprintf('          %s\n', val);
    else
        fprintf('    %s%s %s\n', lab, repmat(' ', 1, max(0, 20 - gopt_dispw(lab))), val);
    end
end

if capB(3) <= 0
    fprintf(['[敏感性] 提示：底座储能功率为 0，储能容量扫描时功率按兜底值 %.2f MW 固定，\n' ...
             '                  图上与表中会标注该口径，不要误读成「最优储能功率 = %.2f MW」。\n'], ...
             PfixE, PfixE);
end

%% ---- 4. 四组扫描 ----
tAll = tic;

SEN.P   = struct();
SEN.E   = struct();
SEN.PV  = struct();
SEN.WT  = struct();
SEN.GEN = struct();
if needP
    % 注意：所有 mkCap 都必须补齐到 5 维（含 capB(5) 自发电容量），否则扫描点传下去
    % 只有 4 维 —— gopt_milp 内部会补 0，但 gopt_metrics 会直接索引 cap(5) 而报错。
    SEN.P  = gopt_sens_sweep(gridP,  @(v) [capB(1); capB(2); v; v * Tfix; capB(5)], cfgS, scS, '(a) 储能功率');
end
if needE
    SEN.E  = gopt_sens_sweep(gridE,  @(v) [capB(1); capB(2); PfixE; v; capB(5)],   cfgS, scS, '(b) 储能容量');
end
if needPV
    SEN.PV = gopt_sens_sweep(gridPV, @(v) [v; capB(2); capB(3); capB(4); capB(5)], cfgS, scS, '(c) 光伏装机');
end
if needWT
    SEN.WT = gopt_sens_sweep(gridWT, @(v) [capB(1); v; capB(3); capB(4); capB(5)], cfgS, scS, '(d) 风电装机');
end
if needGen
    % ★ 本轮新增：(g)(h) 两组子图共用这一组扫描（自发电容量变化，其余维度保持底座值）
    SEN.GEN = gopt_sens_sweep(gridGen, @(v) [capB(1); capB(2); capB(3); capB(4); v], cfgS, scS, '(g)(h) 自发电容量');
end

wall = toc(tAll);

%% ---- 5. 汇总打印（最低点 + 谷底平坦区）----
fprintf('[敏感性] 全部完成：%d 次内层求解，总用时 %.1f s\n', nSolve, wall);
fprintf('[敏感性] 各维度最优：\n');
if needP,   gopt_sens_report(SEN.P,   '储能功率', 'MW');  end
if needE,   gopt_sens_report(SEN.E,   '储能容量', 'MWh'); end
if needPV,  gopt_sens_report(SEN.PV,  '光伏装机', 'MW');  end
if needWT,  gopt_sens_report(SEN.WT,  '风电装机', 'MW');  end
if needGen
    gopt_sens_report(SEN.GEN, '自发电容量', 'MW');
    % 自发电这一维要额外提示一句：它的成本曲线通常是单边下降，最低点往往落在扫描区间
    % 的右端点。若不提示，容易被误读成「算法找到了谷底」，其实只是「还没扫到头」。
    yg = SEN.GEN.cost(isfinite(SEN.GEN.cost));
    xg = SEN.GEN.x(isfinite(SEN.GEN.cost));
    if ~isempty(yg)
        [~, jg] = min(yg);
        if xg(jg) >= max(xg) - 1e-9
            fprintf(['       ⚠ 自发电容量扫描的最低点在区间右端（%.4g MW）：说明这一段仍是' ...
                     '「越大越省」，把上界放宽（cfg.pso.ub(5)）还能继续降成本。\n'], xg(jg));
        end
    end
end

SEN.on      = true;
SEN.tag     = tag;
SEN.baseSrc = baseSrc;
SEN.capB    = capB;
SEN.Tfix    = Tfix;
SEN.PfixE   = PfixE;
SEN.nSolve  = nSolve;
SEN.wall    = wall;
% 方法与公式文本一并存入结构体：Excel 导出（gopt_export_sensitivity）与
% sensitivity_results.mat 都引用同一份，避免日后改了一处忘了改另一处。
SEN.formulaLines = FL;
end

function [ok, m] = gopt_sens_point(cap, cfgS, scS)
%GOPT_SENS_POINT  敏感性分析的单个扫描点：解一次内层最优调度，返回指标
%   ok = R.ok（求解是否成功）；失败时 m 返回 []，调用方把该点置 NaN。
%   注意：这里刻意不抛异常——某个扫描点不可行（例如储能功率为 0 又要求日循环）
%   不应该让整张图失败，只要在图与表里如实体现出来即可。
R  = gopt_milp(cap, scS, cfgS);
ok = logical(R.ok);
if ok
    m = gopt_metrics(R, cap, scS, cfgS);
else
    m = [];
end
end

function Sweep = gopt_sens_sweep(x, mkCap, cfgS, scS, label)
%GOPT_SENS_SWEEP  跑完一个维度的扫描，返回逐点结果
%   输入  x     扫描点（列向量）
%         mkCap 由扫描值构造 4 维容量的匿名函数（其余维度保持底座值）
%         cfgS  内层配置（已置 quiet）  scS 内层场景
%         label 进度显示用的名字
%   输出  Sweep.x 以及逐点的成本 / 电量指标 / 求解状态（失败点一律 NaN）
x = x(:);
n = numel(x);
Sweep = struct('x', x, 'cost', nan(n, 1), 'ok', false(n, 1), ...
    'selfRate', nan(n, 1), 'sellRate', nan(n, 1), 'curtRate', nan(n, 1), ...
    'unusedRate', nan(n, 1), 'capexPV', nan(n, 1), 'capexWT', nan(n, 1), ...
    'capexESS', nan(n, 1), 'capexGen', nan(n, 1), 'costOp', nan(n, 1), ...
    'costGenVar', nan(n, 1), 'genRate', nan(n, 1), 'genUseRate', nan(n, 1), ...
    'genLcoe', nan(n, 1));
t0 = tic;
step = max(1, round(n / 5));
for i = 1:n
    [ok, m] = gopt_sens_point(mkCap(x(i)), cfgS, scS);
    Sweep.ok(i) = ok;
    if ok
        Sweep.cost(i)       = m.costTotal;
        Sweep.selfRate(i)   = m.selfRate;
        Sweep.sellRate(i)   = m.sellRate;
        Sweep.curtRate(i)   = m.curtRate;
        Sweep.unusedRate(i) = m.unusedRate;
        Sweep.capexPV(i)    = m.capexPV;
        Sweep.capexWT(i)    = m.capexWT;
        Sweep.capexESS(i)   = m.capexESS;
        Sweep.capexGen(i)   = m.capexGen;
        Sweep.costOp(i)     = m.costOp;
        Sweep.costGenVar(i) = m.costGenVar;
        Sweep.genRate(i)    = m.genRate;
        Sweep.genUseRate(i) = m.genUseRate;
        Sweep.genLcoe(i)    = m.genLcoe;
    else
        fprintf('[敏感性]     %s 第 %d 点（取值 %.4g）无可行解，已置 NaN。\n', label, i, x(i));
    end
    if mod(i, step) == 0 || i == n
        fprintf('[敏感性]     %s %2d/%2d 点，累计 %.1f s\n', label, i, n, toc(t0));
    end
end
fprintf('[敏感性]   %s 完成：%d 点，用时 %.1f s\n', label, n, toc(t0));
end

function gopt_sens_report(Sweep, name, unit)
%GOPT_SENS_REPORT  打印单个维度的「最低点」与「谷底平坦区」
%   平坦区 = 总成本不超过最低值 1% 的扫描点范围。区间越宽说明该维度上结论越稳健
%   （容量选得略有偏差也不影响经济性），越窄说明越需要把这一维卡准。
if isempty(Sweep) || ~isfield(Sweep, 'cost') || ~any(isfinite(Sweep.cost))
    fprintf('       %-8s ：全部扫描点均无可行解。\n', name);
    return;
end
y = Sweep.cost(:);  x = Sweep.x(:);
g = isfinite(y);
[ymin, j] = min(y);
flat = g & (y <= ymin * 1.01);
fprintf('       %-8s ：最低 %.2f 万元/年 @ %.4g %s', name, ymin, x(j), unit);
if sum(flat) >= 2
    fprintf('；谷底平坦区（≤ 最低 +1%%）：%.4g ~ %.4g %s\n', min(x(flat)), max(x(flat)), unit);
else
    fprintf('；谷底平坦区（≤ 最低 +1%%）：仅 1 个扫描点，谷底较尖\n');
end
end

function L = gopt_sens_formula_lines(capB, Tfix, PfixE, G, cfg)
%GOPT_SENS_FORMULA_LINES  敏感性分析的方法与公式说明（命令行日志与 Excel 说明区共用同一份文本）
%
%   为什么要抽成一个函数：同一段说明要同时出现在两个地方——命令行日志，以及（若开启）
%   Excel「敏感性分析」工作表的说明区。分散写两处必然随时间漂移（改了一处忘了另一处），
%   所以只生成一次，两处都引用它。
%
%   输入  capB  底座 4 维 [C_pv; C_wt; P_ess; E_ess]
%         Tfix  储能功率扫描时固定的储能时长 [h]（= 底座的 E/P）
%         PfixE 储能容量扫描时固定的储能功率 [MW]
%         G     各维度「确实做了扫描」的扫描点：G.P / G.E / G.PV / G.WT，未扫描传 []
%         cfg   全局配置（用到 cfg.sens.relRange / nPoint / scanFromZero / zeroRef / grid*）
%   输出  L     N×2 cell：第一列短标签，第二列式子或说明。日志里拼成一整行；
%               写入 Excel 时正好落在「项目 / 内容」这两列上。

c = capB(:);
L = cell(0, 2);        % 预分配成 N×2（0 行也带列数），下面逐行追加即可
L(end + 1, :) = {'① 底座（基准点）', sprintf( ...
    'capB = res.cap = [光伏 %.2f MW, 风电 %.2f MW, 储能 %.2f MW / %.2f MWh, 自发电 %.2f MW]', ...
    c(1), c(2), c(3), c(4), c(5))};
if ~isempty(G.P)
    L(end + 1, :) = {'② 储能功率扫描', sprintf( ...
        'cap(v) = [PV_B, WT_B, v, Tfix*v]；储能时长固定 Tfix = E_B/P_B = %.4g h', Tfix)};
end
if ~isempty(G.E)
    L(end + 1, :) = {'③ 储能容量扫描', sprintf( ...
        'cap(v) = [PV_B, WT_B, PfixE, v]；储能功率固定 PfixE = %.4g MW', PfixE)};
end
if ~isempty(G.PV)
    L(end + 1, :) = {'④ 光伏装机扫描', 'cap(v) = [v, WT_B, P_B, E_B, Gen_B]'};
end
if ~isempty(G.WT)
    L(end + 1, :) = {'⑤ 风电装机扫描', 'cap(v) = [PV_B, v, P_B, E_B, Gen_B]'};
end
if isfield(G, 'GEN') && ~isempty(G.GEN)
    L(end + 1, :) = {'⑥ 自发电容量扫描（★ 本轮新增）', 'cap(v) = [PV_B, WT_B, P_B, E_B, v]'};
    L(end + 1, :) = {'', ['每一个 v 都重解一次内层 MILP：v 越小 -> 自发电出力越小、弃自发电越少；' ...
        'v 越大 -> 替代的购电量越多、但盈余时刻被弃的也越多']};
end
L(end + 1, :) = {'⑦ 每个扫描点', ...
    ['cost(v) = 用 cap(v) 重解一次内层 MILP 最优调度得到的年化总成本' ...
     ' = 年化投资 + 年化运行成本（口径同主线，实现同为 gopt_metrics）']};

% 网格：先给默认规则，再列本次实际用的网格（哪几维走了自定义网格会单独标注）
L(end + 1, :) = {'⑧ 扫描网格（默认）', sprintf( ...
    ['grid = linspace(b*(1-rel), b*(1+rel), n)；b = 该维度底座值，' ...
     'rel = %.4g，n = %d，区间下限截断到 >= 0'], ...
    cfg.sens.relRange, max(round(cfg.sens.nPoint), 3))};
L(end + 1, :) = {'', sprintf( ...
    'scanFromZero = %d（%s）；某维底座值为 0 时区间退化为 0 ~ 1.5*zeroRef，zeroRef = %.4g', ...
    double(logical(cfg.sens.scanFromZero)), ...
    gopt_tern(logical(cfg.sens.scanFromZero), '下限强制取 0', '保留 b*(1-rel)'), ...
    cfg.sens.zeroRef)};
spec  = {'储能功率', G.P,  'MW',  'gridP';  '储能容量', G.E,  'MWh', 'gridE'; ...
         '光伏装机', G.PV, 'MW',  'gridPV'; '风电装机', G.WT, 'MW',  'gridWT'; ...
         '自发电容量', G.GEN, 'MW', 'gridGen'};
nSp     = size(spec, 1);
gridTxt = cell(nSp, 1);      % 先预分配：避免在循环里逐次追加数组
for s = 1:nSp
    v = spec{s, 2};
    if isempty(v), continue; end
    v = v(:);
    custom = isfield(cfg.sens, spec{s, 4}) && ~isempty(cfg.sens.(spec{s, 4}));
    step = NaN;
    if numel(v) > 1
        d = diff(v);
        if all(abs(d - d(1)) <= 1e-9 * max(1, abs(d(1)))), step = d(1); end
    end
    gridTxt{s} = sprintf('%s %g ~ %g %s（%d 点%s，%s）', spec{s, 1}, min(v), max(v), ...
        spec{s, 3}, numel(v), ...
        gopt_tern(isfinite(step), sprintf('，步长 %g', step), ''), ...
        gopt_tern(custom, ['自定义 cfg.sens.' spec{s, 4}], '默认 linspace'));
end
gridTxt = gridTxt(~cellfun(@isempty, gridTxt));   % 没做扫描的维度留空，这里剔掉
if ~isempty(gridTxt)
    % 只有首行带「实际网格」标签，其余行留空标签（日志里缩进续排）；
    % 一次性拼进 L 而不是逐行追加，省得在循环里反复重新分配。
    lab = [{'实际网格'}; repmat({''}, numel(gridTxt) - 1, 1)];
    L   = [L; [lab, gridTxt(:)]];
end

L(end + 1, :) = {'⑨ 最低点', 'x* = argmin_v cost(v)，ymin = min_v cost(v)（即图中红五星与其旁读数）'};
L(end + 1, :) = {'⑩ 谷底平坦区', ...
    'flat = { v : cost(v) <= 1.01 * ymin }，取 min(flat) ~ max(flat) 作为区间端点'};
L(end + 1, :) = {'', ...
    ['含义：成本相对最低值上浮不超过 1% 的容量区间。区间越宽 → 该维度上结论越稳健' ...
     '（容量选得略有偏差也不影响经济性）；越窄 → 越需要把这一维卡准']};
end

function w = gopt_dispw(s)
%GOPT_DISPDW  估算字符串在等宽终端里的显示宽度（全角字符按 2 列计）
%   为什么需要它：fprintf 的 %-Ns 按「字符个数」补齐，而中日韩字符在终端里占 2 列，
%   直接用 %-Ns 对齐会越对越歪。公式块是要跟日志正文一起看的，故按显示宽度手工补空格。
w = 0;
for k = 1:numel(s)
    if double(s(k)) > 127
        w = w + 2;
    else
        w = w + 1;
    end
end
end

function g = gopt_sens_grid(b, rel, n, fromZero, zr)
%GOPT_SENS_GRID  生成单个维度的扫描点
%   b        底座值
%   rel      扫描半宽系数：区间 = b x (1 ± rel)
%   n        点数
%   fromZero true => 区间下限取 0（复刻「从 0 扫起」的版式）
%   zr       底座值为 0 时使用的参考量级（区间退化为 0 ~ 1.5 x zr）
%
%   为什么需要 zr 这条退路：底座可能是「风电 0 MW」这类零值（本算例最优风电容量
%   就是 0），此时 ±rel 的相对区间恒等于 0，扫出来是无意义的退化曲线；退化为
%   「0 ~ 1.5 x 参考量级」至少还能看出「从 0 往上加这一维」的代价走势。
b = double(b);
if b > 0
    lo = (1 - rel) * b;
    hi = (1 + rel) * b;
    if fromZero, lo = 0; end
else
    lo = 0;
    hi = 1.5 * max(zr, eps);
end
g = linspace(max(lo, 0), max(hi, 0), max(round(n), 3))';
end

function t = gopt_tier_of(cfg, kind)
%GOPT_TIER_OF  按资产简称取分档表（'pv' / 'wt' / 'essP' / 'essE' / 'gen'）；无表返回 []
%   存在的意义：分档表的读取口径只写一次。写 'essE' 时不要顺手写 'esse'（大小写）——
%   这个 getter 统一做 lower，避免各处大小写不一致导致「读不到表却当成了没有分档表」。
switch lower(char(kind))
    case 'pv',   t = gopt_pget(cfg.cost.pv,  'tier',  []);
    case 'wt',   t = gopt_pget(cfg.cost.wt,  'tier',  []);
    case 'essp', t = gopt_pget(cfg.cost.ess, 'tierP', []);
    case 'esse', t = gopt_pget(cfg.cost.ess, 'tierE', []);
    case 'gen',  t = gopt_pget(cfg.cost.gen, 'tier',  []);
    otherwise,   t = [];
end
end

function cfg = gopt_check_tier_ub(cfg)
%GOPT_CHECK_TIER_UB  拦截「搜索上界正好落在分档表的封顶档位」
%
%  为什么必须拦：分档表按「容量 >= 倒数第二行档位时取最后一行的单价」实现，于是
%  封顶档位处单价会**向下跳变**（本算例：风电 4182.75 -> 3968.25，−5.1%；储能容量
%  700 -> 680，−2.9%；储能功率 440 -> 430，−2.3%；光伏两行同值，无跳变）。
%  若搜索上界正好等于该档位，优化器会稳定地坐在这个「价格悬崖」上 —— 结论就完全由
%  这条口径的边界决定，而不是由经济性决定。它比「解贴上界」更隐蔽：看起来是个内部解，
%  实际上是被跳变吸过去的。
%
%  ⚠ 调用位置必须在 gopt_apply_fixed 之后：cfg.fixed.* 会改写 lb/ub（例如
%    cfg.fixed.pv = 500），搜索框定型之前判会漏。
%  ⚠ 下界落在封顶档位不算问题（那时整个可行域都在常数段内，域内无跳变），故只查上界。
%
%  两种修法（报错信息里也会写明）：① 把该资产分档表最后两行的单价改成同一个值；
%  ② 把该维上界挪开一点。确实要保留时，把 cfg.cost.allowTierEdgeBound 设为 true 放行。
if ~strcmp(gopt_cost_mode(cfg), 'tiered'), return; end
u    = cfg.pso.ub(:);
spec = { '优化变量1 光伏容量 [MW]',        u(1),        'pv'
         '优化变量2 风电容量 [MW]',        u(2),        'wt'
         '优化变量3 储能功率 [MW]',        u(3),        'essP'
         '储能容量 [MWh]（= 功率 x 时长）', u(3) * u(4), 'essE' };
hit    = cell(0, 1);
capHit = NaN;
for k = 1:size(spec, 1)
    tbl = gopt_tier_of(cfg, spec{k, 3});
    if isempty(tbl) || size(tbl, 1) < 2, continue; end
    cap = tbl(end - 1, 1);                       % 封顶档位
    pLo = tbl(end - 1, 2);  pHi = tbl(end, 2);   % 跳变前后单价
    % 两个条件同时成立才拦：① 上界正好压在封顶档位；② 该处**确实有跳变**。
    % ⚠ 条件 ② 不能省：本表光伏最后两行单价相同（3000 -> 3000），那里根本不存在
    %   价格悬崖，把 ub = 500 也拦下来就是误报（实测踩过）。
    if abs(spec{k, 2} - cap) <= 1e-9 * max(1, abs(cap)) && abs(pHi - pLo) > 1e-12
        capHit = cap;
        hit{end + 1, 1} = sprintf('%s：上界 %.6g = 封顶档位 %.6g，该处单价由 %.4g 跳到 %.4g（%+.1f%%）', ...
            spec{k, 1}, spec{k, 2}, cap, pLo, pHi, (pHi - pLo) / pLo * 100);   %#ok<AGROW>
    end
end
if isempty(hit), return; end

t1 = ['搜索上界正好落在分档表的封顶档位上（cfg.cost.mode = ''tiered''）：' ...
      sprintf('\n  · %s', hit{:})];
t2 = sprintf(['\n\n  该档位之后单价不再随容量变化（口径是「容量 >= 封顶档位时取最后一行的单价」），' ...
    '\n  所以正好取到它时价格会向下跳一档。优化器会稳定地坐在这个跳变点上，结论就由' ...
    '\n  这条口径的边界决定、而不是由经济性决定 —— 与「解贴上界」同源，但更难察觉。' ...
    '\n\n  两种修法：' ...
    '\n    ①（推荐）把对应分档表最后两行的单价改成同一个值 —— 表本身连续，跳变即消失；' ...
    '\n    ②  把该维上界挪开（避开 %.6g，例如取 499 或 501）。' ...
    '\n  确实要保留这个上界，就把 cfg.cost.allowTierEdgeBound 设为 true 显式放行。'], capHit);
if cfg.cost.allowTierEdgeBound
    fprintf('[警告] %s%s\n  （cfg.cost.allowTierEdgeBound = true，已按要求放行）\n', t1, t2);
else
    error('gopt_check_tier_ub:tierEdgeBound', '%s%s', t1, t2);
end
end

%% --------------------------------------------- 分档档位边界标注（敏感性图用）
function gopt_tier_marks(ax, tbl, cfg, scale, tag, showLabel)
%GOPT_TIER_MARKS  在容量轴上标出「分档单价表的档位边界」（竖直虚线 + 档位读数）
%
%  为什么需要它：cfg.cost.mode = 'tiered' 时，单位投资单价是容量的**分段线性函数**，
%  于是成本曲线在每个档位处都会出现**折点**（斜率突变），在封顶档位处甚至是一个
%  跳变（本算例 500 MW 处风电 4182.75 -> 3968.25，−5.1%）。不把边界标出来，读者
%  很容易把折点当成数值噪声或模型抖动，进而怀疑结果。
%
%  —— 画法约定 ——
%    · 只画**落在当前 x 量程内**的档位：量程外的自然不画，免得把图挤满；
%    · 插值结点用灰虚线（--），**封顶档位**用点划线（-.）—— 它之后单价不再随容量
%      变化（常数段），语义不同，故用不同线型区分；
%    · 所有线都设 HandleVisibility='off'，不会污染图例；
%    · 档位读数只在量程内档位不超过 MARKLABEL_MAX 个时才标（否则必然互相压字），
%      且始终标在顶部，避免压住曲线数据。
%
%  输入  ax    目标坐标轴（须已画完数据，量程已定 —— 线型判据与标签位置都依赖量程）
%        tbl   分档表 N x 2（空 => 直接返回，例如厂内自发电没有分档表）
%        cfg   全局配置（用 out.axisLineWidth / out.figFontSize / sens.markTiers）
%        scale 档位 -> 当前 x 轴单位的换算比例（x 轴读数 = 档位 / scale）；缺省 1。
%              典型用法：面板 (a) 的 x 轴是**储能功率** P [MW]，而「储能容量」档位表
%              是按 MWh 给的、且扫描时储能时长固定为 Tfix，于是 E = P x Tfix
%               => P = 档位 / Tfix，传 scale = Tfix 就把容量档位换算到了功率轴。
%        tag   标签前缀（如 'P' / 'E'），用于区分「本维直接分档」与「由另一张表派生」；
%              缺省 '' 表示不加前缀。
%        showLabel  是否写档位读数；缺省 [] = 自动（量程内档位 <= MARKLABEL_MAX 时才写，
%              否则必然互相压字）。同一张图上同时标两族线时，把「派生」那一族设为
%              false，只留线不写读数，避免两类数字混在一起。
MARKLABEL_MAX = 4;          % 自动模式下：量程内档位超过这个数就只画线、不写读数
if nargin < 4 || isempty(scale), scale = 1; end
if nargin < 5, tag = ''; end
if nargin < 6, showLabel = []; end
if isempty(tbl) || size(tbl, 1) < 2, return; end

xr  = sort(xlim(ax));
x   = tbl(:, 1) / scale;
cap = x(end - 1);                              % 封顶档位（表的倒数第二行）
x   = x(1:end - 1);                            % 只画插值结点；最后一行的值是常数段取值、不是边界
in  = isfinite(x) & x > xr(1) & x < xr(2);
if ~any(in), return; end

doLabel = nnz(in) <= MARKLABEL_MAX;
if ~isempty(showLabel), doLabel = logical(showLabel); end
if doLabel
    yl = ylim(ax);
    % 读数用 text 而不是 ConstantLine 的 Label：后者只能贴着轴顶边放，实测会压在顶框线上。
    % 这里从顶框内缩 2.5% 的量程，既避开框线、又不压住曲线数据（数据都在下方）。
    % ⚠ 双 y 轴面板上 ylim 返回的是**当前活动侧**的量程，数值不同但视觉位置一致。
    yT = yl(2) - 0.025 * (yl(2) - yl(1));
end
for k = 1:numel(x)
    if ~in(k), continue; end
    xk = x(k);
    h  = xline(ax, xk);                        % 先建对象再设属性：比记 linespec 语法更稳
    if abs(xk - cap) <= 1e-9 * max(1, abs(cap))
        h.LineStyle = '-.';                    % 封顶档位：之后进入常数段
    else
        h.LineStyle = '--';
    end
    h.Color            = [0.55 0.55 0.55];
    h.LineWidth        = cfg.out.axisLineWidth * 0.8;
    h.HandleVisibility = 'off';
    if doLabel
        text(ax, xk, yT, sprintf(' %s%g', tag, xk), ...
            'VerticalAlignment', 'top', 'HorizontalAlignment', 'left', ...
            'FontName', 'Helvetica', 'FontSize', cfg.out.figFontSize - 2, ...
            'Color', [0.45 0.45 0.45]);
    end
end
end

function gopt_plot_sensitivity(SEN, ~, cfg)
%GOPT_PLOT_SENSITIVITY  绘制敏感性分析图（2 x 3 六子图）
%   第二个形参（主线结果 res）现在用不到了：底座配置与来源已由 SEN.capB / SEN.baseSrc
%   一并带入，不必再从主线结果里取。保留成占位符是为了不动调用处的实参顺序。
%   版面（2 x 4 八子图）：
%     (a) 储能功率 -> 年化总成本（储能时长固定）
%     (b) 储能容量 -> 年化总成本（储能功率固定）
%     (c) 光伏装机 -> 年化总成本 + 未自用率（双轴）
%     (d) 风电装机 -> 年化总成本 + 未自用率（双轴）
%     (e) 储能容量 -> 自用率 / 上网率 / 弃电率
%     (f) 储能容量 -> 年化成本构成（堆叠面积）
%     (g) 自发电容量 -> 年化总成本 + 未自用率（双轴）      ★ 本轮新增
%     (h) 自发电容量 -> 自发电占负荷比例 + 自发电度电成本（双轴）★ 本轮新增
%   每条成本曲线上用红五星标出「扫描区间内的最低点」，并给出坐标读数；
%   与底座值重合时即说明当前最优点确实落在谷底。
if isempty(SEN) || ~SEN.on
    return;
end
if ~exist(cfg.path.outDir, 'dir'), mkdir(cfg.path.outDir); end

P  = gopt_palette();
S  = gopt_labels(cfg.out.figLang);
lw = cfg.out.lineWidth;
ms = 3.6;

% 子图数由 6 增到 8（新增自发电两格），故版面由 2x3 改成 2x4、画布相应加宽，
% 保证每格的数据区宽度与原来相当（缩放后字号观感不变）。
f  = gopt_newfig(32.0, 14.0);
tl = tiledlayout(f, 2, 4, 'TileSpacing', 'compact', 'Padding', 'compact');

%% (a) 储能功率 -> 总成本
if ~isempty(SEN.P) && isfield(SEN.P, 'x') && ~isempty(SEN.P.x)
    ax = nexttile(tl); hold(ax, 'on');
    gopt_sens_curve(ax, SEN.P.x, SEN.P.cost, P.blue, lw, ms, S, cfg);
    xlabel(ax, sprintf('%s（%s %.2f h）', S.esP, S.fixDur, SEN.Tfix));
    ylabel(ax, S.sensCostY);
    title(ax, S.tSensP, 'FontSize', cfg.out.figFontSize);
    % (a) 的 x 轴是储能功率 P，直接分档表是 tierP，故标它。
    % ⚠ 实测提示：储能容量 = P x Tfix 也随 P 变化，所以 tierE 在功率轴上还有一族
    %   折点（位置 = 容量档位 / Tfix）。但那族线在功率轴上会挤在低速段、又没有刻度
    %   读数可对，两族线混在一张图上反而像噪声（本项目实测过），故**刻意只标本维
    %   直接分档表**。要连派生折点一起看，就用 (b) 储能容量面板（同一条曲线的另一
    %   个视角，横轴直接是容量）。
    if cfg.sens.markTiers
        gopt_tier_marks(ax, cfg.cost.ess.tierP, cfg, 1, 'P', true);
    end
    gopt_sens_noexp(ax, 'left');
    gopt_style(ax, S, cfg);
end

%% (b) 储能容量 -> 总成本
if ~isempty(SEN.E) && isfield(SEN.E, 'x') && ~isempty(SEN.E.x)
    ax = nexttile(tl); hold(ax, 'on');
    gopt_sens_curve(ax, SEN.E.x, SEN.E.cost, P.blue, lw, ms, S, cfg);
    xlabel(ax, sprintf('%s（%s %.2f MW）', S.esE, S.fixPow, SEN.PfixE));
    ylabel(ax, S.sensCostY);
    title(ax, S.tSensE, 'FontSize', cfg.out.figFontSize);
    % (b) 的 x 轴直接就是储能容量 [MWh]，查 tierE，一一对应，故直接标（含读数）。
    if cfg.sens.markTiers
        gopt_tier_marks(ax, cfg.cost.ess.tierE, cfg, 1, '', true);
    end
    gopt_sens_noexp(ax, 'left');
    gopt_style(ax, S, cfg);
end

%% (c) 光伏装机 -> 总成本 + 未自用率
if ~isempty(SEN.PV) && isfield(SEN.PV, 'x') && ~isempty(SEN.PV.x)
    ax = nexttile(tl); hold(ax, 'on');
    yyaxis(ax, 'left');
    gopt_sens_curve(ax, SEN.PV.x, SEN.PV.cost, P.blue, lw, ms, S, cfg, 'nw');
    ylabel(ax, S.sensCostY);
    yyaxis(ax, 'right');
    plot(ax, SEN.PV.x, SEN.PV.unusedRate, '--s', 'Color', P.verm, ...
        'LineWidth', lw * 0.9, 'MarkerSize', ms - 0.8, 'MarkerFaceColor', P.verm, ...
        'MarkerEdgeColor', 'none');
    ylabel(ax, S.unusedY);
    ur = SEN.PV.unusedRate(isfinite(SEN.PV.unusedRate));
    if isempty(ur), ur = 0; end
    ylim(ax, [0, max(5, 1.2 * max(ur))]);
    xlabel(ax, S.pvCap);
    legend(ax, {S.sensCostY, S.unusedY}, 'Location', 'northwest', ...
        'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
    title(ax, S.tSensPV, 'FontSize', cfg.out.figFontSize);
    % (c) 的 x 轴是光伏装机 [MW]，直接查 cfg.cost.pv.tier。
    if cfg.sens.markTiers
        gopt_tier_marks(ax, cfg.cost.pv.tier, cfg, 1, '', true);
    end
    gopt_sens_noexp(ax, 'left');
    gopt_style(ax, S, cfg);
end

%% (d) 风电装机 -> 总成本 + 未自用率
if ~isempty(SEN.WT) && isfield(SEN.WT, 'x') && ~isempty(SEN.WT.x)
    ax = nexttile(tl); hold(ax, 'on');
    yyaxis(ax, 'left');
    gopt_sens_curve(ax, SEN.WT.x, SEN.WT.cost, P.blue, lw, ms, S, cfg);
    ylabel(ax, S.sensCostY);
    yyaxis(ax, 'right');
    plot(ax, SEN.WT.x, SEN.WT.unusedRate, '--s', 'Color', P.verm, ...
        'LineWidth', lw * 0.9, 'MarkerSize', ms - 0.8, 'MarkerFaceColor', P.verm, ...
        'MarkerEdgeColor', 'none');
    ylabel(ax, S.unusedY);
    ur = SEN.WT.unusedRate(isfinite(SEN.WT.unusedRate));
    if isempty(ur), ur = 0; end
    ylim(ax, [0, max(5, 1.2 * max(ur))]);
    xlabel(ax, S.wtCap);
    legend(ax, {S.sensCostY, S.unusedY}, 'Location', 'northwest', ...
        'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
    title(ax, S.tSensWT, 'FontSize', cfg.out.figFontSize);
    % (d) 的 x 轴是风电装机 [MW]，直接查 cfg.cost.wt.tier。
    if cfg.sens.markTiers
        gopt_tier_marks(ax, cfg.cost.wt.tier, cfg, 1, '', true);
    end
    gopt_sens_noexp(ax, 'left');
    gopt_style(ax, S, cfg);
end

%% (e) 储能容量 -> 自用率 / 上网率 / 弃电率
if ~isempty(SEN.E) && isfield(SEN.E, 'x') && ~isempty(SEN.E.x)
    ax = nexttile(tl); hold(ax, 'on');
    plot(ax, SEN.E.x, SEN.E.selfRate, '-o', 'Color', P.blue, 'LineWidth', lw, ...
        'MarkerSize', ms, 'MarkerFaceColor', P.blue, 'MarkerEdgeColor', 'none');
    plot(ax, SEN.E.x, SEN.E.sellRate, '--s', 'Color', P.verm, 'LineWidth', lw * 0.9, ...
        'MarkerSize', ms - 0.8, 'MarkerFaceColor', P.verm, 'MarkerEdgeColor', 'none');
    plot(ax, SEN.E.x, SEN.E.curtRate, ':^', 'Color', P.green, 'LineWidth', lw * 0.9, ...
        'MarkerSize', ms - 0.4, 'MarkerFaceColor', P.green, 'MarkerEdgeColor', 'none');
    yline(ax, 0, '-', 'Color', [0.20 0.20 0.20], 'LineWidth', cfg.out.axisLineWidth * 0.8, ...
        'HandleVisibility', 'off');
    xlabel(ax, sprintf('%s（%s %.2f MW）', S.esE, S.fixPow, SEN.PfixE));
    ylabel(ax, S.rateY);
    ylim(ax, [0 100]);
    legend(ax, {S.selfRate, S.sellRate, S.curtRate}, 'Location', 'east', ...
        'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
    title(ax, S.tSensUtil, 'FontSize', cfg.out.figFontSize);
    gopt_style(ax, S, cfg);
end

%% (f) 储能容量 -> 年化成本构成（堆叠面积）
if ~isempty(SEN.E) && isfield(SEN.E, 'x') && ~isempty(SEN.E.x)
    ax = nexttile(tl); hold(ax, 'on');
    g = isfinite(SEN.E.cost);
    if any(g)
        xx = SEN.E.x(g);
        YM = [SEN.E.capexPV(g), SEN.E.capexWT(g), SEN.E.capexESS(g), SEN.E.costOp(g)];
        hA = area(ax, xx, YM, 'EdgeColor', 'none');
        cc = {P.orange, P.sky, P.purple, P.verm};
        for q = 1:numel(hA)
            hA(q).FaceColor = cc{q};
            try, hA(q).FaceAlpha = 0.85; end
        end
    end
    xlabel(ax, sprintf('%s（%s %.2f MW）', S.esE, S.fixPow, SEN.PfixE));
    ylabel(ax, S.capexY);
    legend(ax, {S.capexPv, S.capexWt, S.capexEss, S.opCost}, 'Location', 'northwest', ...
        'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
    title(ax, S.tSensCost, 'FontSize', cfg.out.figFontSize);
    % (f) 的成本构成堆叠面积图同样以储能容量为横轴，折点来源与 (b) 相同；
    % 本格左上角已有图例，为免压字只画线、不写读数（读数看同轴的 (b)）。
    if cfg.sens.markTiers
        gopt_tier_marks(ax, cfg.cost.ess.tierE, cfg, 1, '', false);
    end
    gopt_style(ax, S, cfg);
end

%% (g) 自发电容量 -> 总成本 + 未自用率（★ 本轮新增）
if ~isempty(SEN.GEN) && isfield(SEN.GEN, 'x') && ~isempty(SEN.GEN.x)
    ax = nexttile(tl); hold(ax, 'on');
    yyaxis(ax, 'left');
    gopt_sens_curve(ax, SEN.GEN.x, SEN.GEN.cost, P.blue, lw, ms, S, cfg, 'nw');
    ylabel(ax, S.sensCostY);
    yyaxis(ax, 'right');
    plot(ax, SEN.GEN.x, SEN.GEN.unusedRate, '--s', 'Color', P.verm, ...
        'LineWidth', lw * 0.9, 'MarkerSize', ms - 0.8, 'MarkerFaceColor', P.verm, ...
        'MarkerEdgeColor', 'none');
    ylabel(ax, S.unusedY);
    ur = SEN.GEN.unusedRate(isfinite(SEN.GEN.unusedRate));
    if isempty(ur), ur = 0; end
    ylim(ax, [0, max(5, 1.2 * max(ur))]);
    xlabel(ax, S.genCap);
    legend(ax, {S.sensCostY, S.unusedY}, 'Location', 'northwest', ...
        'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
    title(ax, S.tSensGen, 'FontSize', cfg.out.figFontSize);
    gopt_sens_noexp(ax, 'left');
    gopt_style(ax, S, cfg);
    % 刻度位数按「刚好够用」钉住：自发电容量轴按整数显示（扫描点间距常带 0.25 这类
    % 小数步长，自动刻度可能给出 6.3 / 8.8 之类的位置），左右纵轴分别按 0 位与 2 位封顶。
    gopt_tickfmt(ax, 'x',     2);
    gopt_tickfmt(ax, 'left',  0);
    gopt_tickfmt(ax, 'right', 2);
end

%% (h) 自发电容量 -> 自发电占负荷比例 + 自发电度电成本（★ 本轮新增）
if ~isempty(SEN.GEN) && isfield(SEN.GEN, 'x') && ~isempty(SEN.GEN.x)
    ax = nexttile(tl); hold(ax, 'on');
    yyaxis(ax, 'left');
    plot(ax, SEN.GEN.x, SEN.GEN.genRate, '-o', 'Color', P.blue, 'LineWidth', lw, ...
        'MarkerSize', ms, 'MarkerFaceColor', P.blue, 'MarkerEdgeColor', 'none');
    ylabel(ax, S.genShareY);
    gr = SEN.GEN.genRate(isfinite(SEN.GEN.genRate));
    if isempty(gr), gr = 0; end
    ylim(ax, [0, max(5, 1.2 * max(gr))]);
    yyaxis(ax, 'right');
    plot(ax, SEN.GEN.x, SEN.GEN.genLcoe, '--^', 'Color', P.verm, 'LineWidth', lw * 0.9, ...
        'MarkerSize', ms - 0.4, 'MarkerFaceColor', P.verm, 'MarkerEdgeColor', 'none');
    ylabel(ax, S.genLcoeY);
    % ★ 自发电度电成本与装机容量无关（= 单位投资 x 年化费用率 / 等效满发小时 + 运行成本），
    %   所以本轴的数据近似恒定。若直接交给自动刻度，MATLAB 会把 1e-15 量级的数值噪声
    %   展开成 13 位小数（实测 0.1097388312313 / 0.10973883123129 …），刻度不可读。
    %   两步处理：① 把「近似恒定」的量程撑成中心值 ±1%，让刻度落在互不相同的可读数值上；
    %   ② 把刻度钉成固定 4 位小数（0.1090 / 0.1095 / 0.1100 …）。
    isFlat = gopt_axis_readable(ax, 'right', SEN.GEN.genLcoe, 0.01);
    gopt_tickfmt(ax, 'right', 4);
    xlabel(ax, S.genCap);
    legend(ax, {S.genShareY, S.genLcoeY}, 'Location', 'northwest', ...
        'Box', 'off', 'FontSize', cfg.out.figFontSize - 1);
    title(ax, S.tSensGenShare, 'FontSize', cfg.out.figFontSize);
    gopt_sens_noexp(ax, 'left');
    gopt_style(ax, S, cfg);
    gopt_tickfmt(ax, 'x',    2);
    gopt_tickfmt(ax, 'left', 0);
    % 触发过「量程撑开」时补一行说明：否则读者会以为这 4 位小数在展示真实变化，
    % 而真相是在本扫描区间内它与容量无关、曲线就是一条水平线。
    if isFlat
        text(ax, 0.97, 0.05, gopt_flat_note(cfg.out.figLang), 'Units', 'normalized', ...
            'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', ...
            'FontName', S.font, 'FontSize', cfg.out.figFontSize - 1, ...
            'Color', [0.45 0.45 0.45], 'Interpreter', 'none');
    end
end

%% 总标题（两行：第一行口径与底座来源，第二行底座容量明细）
sn1 = sprintf('%s（%s，内层均为最优运行）', ...
    gopt_t(cfg.out.figLang, 'senstitle'), SEN.baseSrc);
sn2 = sprintf('光伏 %.2f MW | 风电 %.2f MW | 储能 %.2f MW / %.2f MWh (%.2f h) | 自发电 %.2f MW', ...
    SEN.capB(1), SEN.capB(2), SEN.capB(3), SEN.capB(4), SEN.Tfix, SEN.capB(5));
title(tl, sprintf('%s\n%s', sn1, sn2), 'FontName', S.font, ...
    'FontSize', cfg.out.figTitleSize, 'FontWeight', 'bold', 'Interpreter', 'none');

gopt_save(f, 'fig_sensitivity', cfg);
fprintf('[绘图] 敏感性分析图已保存：fig_sensitivity（%s）\n', strjoin(cfg.out.figFormats, ' / '));
end

function gopt_sens_curve(ax, x, y, c, lw, ms, S, cfg, resv)
%GOPT_SENS_CURVE  画一条敏感性成本曲线：折线 + 圆点 + 最低点红五星与读数标注
%   两个细节：
%     · 读数标注会自动避让曲线与图例（见 gopt_sens_minlabel）：先在最低点旁试写，
%       压线就依次换到谷底上方 / 顶部空白带 / 底部空白带，绝不遮住曲线或图例；
%     · 关掉 y 轴的 ×10^n 指数标记——纵轴标题已写明「万元/年」，再叠一层指数会让人
%       误以为还要再乘 1e4。
%
%   resv（可选）：预留区域，'' 表示无 | 'nw' 表示该子图稍后会加一个西北角的图例。
%   为什么需要它：本函数在图例之前调用（图例的句柄这时还不存在，量不到图例尺寸），
%   所以只能由调用方告知「这儿将来会有图例」，把西北角整块留出来。
if nargin < 9, resv = ''; end
x = x(:);  y = y(:);
good = isfinite(y);
plot(ax, x(good), y(good), '-o', 'Color', c, 'LineWidth', lw, ...
    'MarkerSize', ms, 'MarkerFaceColor', c, 'MarkerEdgeColor', 'none');

if any(good)
    [ymin, j] = min(y);
    xm = x(j);
    plot(ax, xm, ymin, 'p', 'MarkerSize', 9, 'MarkerFaceColor', [0.85 0.10 0.10], ...
        'MarkerEdgeColor', 'none', 'HandleVisibility', 'off');
    % 顶部留出标注空间。注意顺序：标注位置要按「撑开之后」的纵轴范围来算，
    % 所以先设好 ylim，再落标注。
    yl  = ylim(ax);
    pad = 0.16 * max(diff(yl), eps);
    ylim(ax, [yl(1), yl(2) + pad]);
    gopt_sens_minlabel(ax, x(good), y(good), xm, ymin, S, cfg, resv);
end
end

function gopt_sens_minlabel(ax, x, y, xm, ymin, S, cfg, resv)
%GOPT_SENS_MINLABEL  写出最低点读数，并自动挑一个「不压曲线、不压图例」的位置
%   做法：先把文字建出来、量出它的数据坐标包围盒（Extent），再按下面的优先级试着
%   摆放，取第一个「完整落在坐标区内、且与折线、图例都不相交」的位置：
%     ① 与最低点同高（原样式）  ② 最低点正上方（U 形谷底正好落进谷底内侧的空白）
%     ③ 坐标区顶部空白带        ④ 贴近底部
%   每个高度上都试 4 个横向锚点：贴着最低点右侧 / 左侧、贴右边界、贴左边界。
%   为什么不做成「固定放某处」：面板越窄，一行字的相对宽度越大，而且四个子图的
%   曲线形状（单调下降 / U 形谷底）与图例位置各不相同，只能按「哪儿空往哪儿放」来试。
%   全部试完仍躲不开时退回位置 ① 的贴点写法——宁可贴近一点，也保证读数值不丢。
if nargin < 8, resv = ''; end
xr   = xlim(ax);   yl = ylim(ax);
xrng = max(diff(xr), eps);   yrng = max(diff(yl), eps);
txt  = sprintf('%s %.4g / %.2f 万元/年', S.minPt, xm, ymin);
t = text(ax, xm, ymin, txt, 'FontSize', cfg.out.figFontSize - 1, ...
    'Color', [0.72 0.05 0.05], 'VerticalAlignment', 'bottom', ...
    'HorizontalAlignment', 'left', 'Interpreter', 'none');
e  = get(t, 'Extent');            % [左 下 宽 高]，数据坐标
tw = e(3);   th = e(4);
if ~(tw > 0 && th > 0)            % 量不出尺寸（极旧版本）=> 不折腾，保持原样式
    t.Position = [xm, ymin + 0.03 * yrng, 0];
    return;
end

% 障碍：真实图例（若已存在）
lgBx = gopt_sens_legendbox(ax, xr, yl);
% 障碍：即将创建的西北角图例，按保守尺寸预留（宽 70%、高 20%）
if isempty(lgBx) && strcmpi(resv, 'nw')
    lgBx = [xr(1), xr(1) + 0.70 * xrng, yl(2) - 0.20 * yrng, yl(2)];
end

gap  = 0.04 * xrng;                                    % 文字与最低点之间的留白
padX = 0.02 * xrng;                                    % 文字与坐标边框之间的留白
lvls = [ymin + 0.015 * yrng;                           % ① 与最低点同高
        ymin + 0.20  * yrng;                           % ② 最低点正上方
        yl(2) - 0.06 * yrng - th;                      % ③ 顶部空白带
        yl(1) + 0.03 * yrng];                          % ④ 贴近底部
anch = {'min+', 'min-', 'edgeR', 'edgeL'};

for L = 1:numel(lvls)
    for A = 1:numel(anch)
        switch anch{A}
            case 'min+'
                x1 = xm + gap;            ha = 'left';
            case 'min-'
                x1 = xm - gap - tw;       ha = 'right';
            case 'edgeR'
                x1 = xr(2) - padX - tw;   ha = 'right';
            otherwise
                x1 = xr(1) + padX;        ha = 'left';
        end
        x1 = min(max(x1, xr(1) + padX * 0.5), xr(2) - padX * 0.5 - tw);
        bx = [x1, x1 + tw, lvls(L), lvls(L) + th];
        if bx(4) > yl(2) - 0.015 * yrng, continue; end    % 顶出坐标区，试下一个
        if gopt_sens_free(x, y, bx, 0.02 * yrng, lgBx)
            t.HorizontalAlignment = ha;
            if strcmp(ha, 'right')
                t.Position = [bx(2), bx(3), 0];
            else
                t.Position = [bx(1), bx(3), 0];
            end
            return;
        end
    end
end
t.HorizontalAlignment = 'left';
t.Position = [xm + gap, ymin + 0.03 * yrng, 0];
end

function bx = gopt_sens_legendbox(ax, xr, yl)
%GOPT_SENS_LEGENDBOX  图例在数据坐标下的包围盒（供标注避让）；无图例时返回空
%   图例 Position 是「相对图窗归一化」的，坐标区 Position 同样是相对图窗归一化，
%   所以可以直接线性换算。外扩 8% 作为安全余量，避免文字贴着图例边沿。
bx = [];
lg = [];
try
    lg = ax.Legend;
catch
end
if isempty(lg), return; end
try
    if ~isvalid(lg), return; end
catch
    return;
end
p  = lg.Position;                 % [左 下 宽 高]，相对图窗归一化
ap = ax.Position;                 % [左 下 宽 高]，相对图窗归一化
if numel(p) ~= 4 || numel(ap) ~= 4 || ap(3) <= 0 || ap(4) <= 0, return; end
x1 = xr(1) + (p(1) - ap(1)) / ap(3) * diff(xr);
x2 = x1 + p(3) / ap(3) * diff(xr);
y1 = yl(1) + (p(2) - ap(2)) / ap(4) * diff(yl);
y2 = y1 + p(4) / ap(4) * diff(yl);
dx = 0.08 * (x2 - x1);   dy = 0.08 * (y2 - y1);
bx = [x1 - dx, x2 + dx, y1 - dy, y2 + dy];
end

function ok = gopt_sens_free(x, y, bx, m, lgBx)
%GOPT_SENS_FREE  判断矩形 bx=[左 右 下 上] 是否可以安放文字
%   两条判据：① 不与图例包围盒相交；② 不与折线相交。
%   ② 的判法：在矩形覆盖的横坐标区间内按线性插值加密取样，只要有任一点落进
%   「上下各外扩 m 之后的纵向区间」，就认为这行字会压住曲线。
ok = true;
if nargin >= 5 && ~isempty(lgBx) && ...
        bx(1) < lgBx(2) && bx(2) > lgBx(1) && bx(3) < lgBx(4) && bx(4) > lgBx(3)
    ok = false;
    return;
end
xs = linspace(max(bx(1), min(x)), min(bx(2), max(x)), 241);
if numel(xs) < 2, return; end
ys = interp1(x, y, xs, 'linear');
g  = isfinite(ys);
ok = ~any(ys(g) >= bx(3) - m & ys(g) <= bx(4) + m);
end

function gopt_sens_noexp(ax, which)
%GOPT_SENS_NOEXP  关掉指定 y 轴的 ×10^n 指数标记（纵轴标题已写明单位）
%   which：'left' | 'right'（双轴图必须分别指定；单轴图用 'left' 即可）
try
    if strcmpi(which, 'left') && numel(ax.YAxis) == 2
        ax.YAxis(1).Exponent = 0;
    elseif numel(ax.YAxis) == 2
        ax.YAxis(2).Exponent = 0;
    else
        ax.YAxis.Exponent = 0;
    end
catch
    % 极旧版本没有 Exponent 属性，忽略即可（不影响图的正确性）
end
end

function gopt_export_sensitivity(SEN, cfg)
%GOPT_EXPORT_SENSITIVITY  把敏感性扫描明细追加到 Excel（新增「敏感性分析」工作表）
%   写入时机：主线结果已由 gopt_export 写完，这里只是「补一张表」，因此直接
%   writecell 到同一个文件的新工作表，不会覆盖前面任何内容。
%   表结构：第一段是口径说明，第二段起是长表（4 组扫描依次接排）。
if isempty(SEN) || ~SEN.on
    return;
end
outFile = fullfile(cfg.path.outDir, 'optimization_results.xlsx');
if exist(outFile, 'file') ~= 2
    fprintf('[敏感性] 未找到 %s（cfg.out.writeExcel 未开启？），跳过敏感性表导出。\n', outFile);
    return;
end

hdr = {'扫描维度', '取值', '单位', '年化总成本(万元/年)', ...
       '光伏年化(万元/年)', '风电年化(万元/年)', '储能年化(万元/年)', '自发电年化(万元/年)', ...
       '自发电运行(万元/年)', '运行成本(万元/年)', ...
       '自用率(%)', '上网率(%)', '弃电率(%)', '未自用率(%)', ...
       '自发电占负荷(%)', '自发电度电成本(元/kWh)', '求解状态'};

info = {
    '项目', '内容'
    '底座来源', SEN.baseSrc
    '底座 光伏(MW)', SEN.capB(1)
    '底座 风电(MW)', SEN.capB(2)
    '底座 储能功率(MW)', SEN.capB(3)
    '底座 储能容量(MWh)', SEN.capB(4)
    '底座 自发电(MW)', SEN.capB(5)
    '储能功率扫描 固定时长(h)', SEN.Tfix
    '储能容量扫描 固定功率(MW)', SEN.PfixE
    '内层时间尺度口径', SEN.tag
    '内层求解次数', SEN.nSolve
    '扫描总耗时(s)', SEN.wall
    '自用率口径', '（绿电发电量 - 绿电上网电量 - 绿电弃电量）/ 绿电发电量'
    '上网率口径', '绿电上网电量 / 绿电发电量（上网全部归绿电）'
    '弃电率口径', '绿电弃电量 / 绿电发电量（仅弃光伏 + 弃风电）'
    '未自用率口径', '上网率 + 弃电率 = 1 - 自用率'
    '绿电口径', '绿电 = 光伏 + 风电（不含自发电；自发电单列）'
    };
if isfield(SEN, 'capB') && numel(SEN.capB) < 5
    info{end + 1, :} = {'提示', '底座配置不足 5 维，自发电按 0 处理'};
end

% 方法与公式：与命令行日志引用同一份文本（SEN.formulaLines），避免两处漂移。
% 插在口径行之后、扫描明细表之前；表头与数据区的起始行由 size(info,1) 顺延，
% 所以下面的 Range 不需要手工改——改完这里就是对的。
if isfield(SEN, 'formulaLines') && ~isempty(SEN.formulaLines)
    info = [info; {'', ''}; {'敏感性分析方法与公式', '（含本次实际参数）'}; SEN.formulaLines];
end

rows = cell(0, 17);
specs = {SEN.P, '储能功率', 'MW'; SEN.E, '储能容量', 'MWh'; ...
         SEN.PV, '光伏装机', 'MW'; SEN.WT, '风电装机', 'MW'; ...
         SEN.GEN, '自发电容量', 'MW'};
for s = 1:size(specs, 1)
    Sw = specs{s, 1};
    if isempty(Sw) || ~isfield(Sw, 'x') || isempty(Sw.x)
        continue;
    end
    for i = 1:numel(Sw.x)
        rows(end + 1, :) = {specs{s, 2}, Sw.x(i), specs{s, 3}, ...
            Sw.cost(i), Sw.capexPV(i), Sw.capexWT(i), Sw.capexESS(i), Sw.capexGen(i), ...
            Sw.costGenVar(i), Sw.costOp(i), ...
            Sw.selfRate(i), Sw.sellRate(i), Sw.curtRate(i), Sw.unusedRate(i), ...
            Sw.genRate(i), Sw.genLcoe(i), ...
            gopt_tern(Sw.ok(i), '正常', '无可行解')};   %#ok<AGROW>
    end
end

% ---- 写之前先把本表清空 ----
% 为什么必须先清空：说明区的行数会随版本变化（本轮就新增了「方法与公式」若干行），
% 而 writecell 只覆盖它实际写到的那个矩形，不会去清理右侧/下方更远处的旧内容。
% 不清空的话，说明区一变长，上一轮的表头与数据行就会残留在旁边，看起来像错位的脏数据。
% 注意：这只是「补一张表」，所以只清本工作表，不碰同一文件里的其他工作表。
if exist(outFile, 'file') == 2
    try
        oldR = readcell(outFile, 'Sheet', '敏感性分析');
        nRow = max(size(oldR, 1), size(info, 1) + 2 + size(rows, 1));
        nCol = max(size(oldR, 2), numel(hdr));
        writecell(repmat({''}, nRow, nCol), outFile, 'Sheet', '敏感性分析');
    catch
        % 该工作表还不存在（首次运行）或读不动：后面本来就会新建，无需清空
    end
end

writecell(info, outFile, 'Sheet', '敏感性分析');
writecell(hdr,  outFile, 'Sheet', '敏感性分析', 'Range', sprintf('A%d', size(info, 1) + 2));
if ~isempty(rows)
    writecell(rows, outFile, 'Sheet', '敏感性分析', ...
        'Range', sprintf('A%d', size(info, 1) + 3));
end
fprintf('[输出] 敏感性分析明细已追加到「敏感性分析」工作表（%d 行）\n', size(rows, 1));
end

%% ============================================================== 模型自检
function gopt_selftest(cfg)
%GOPT_SELFTEST  模型回归自检：内层调度正确性 + 外层 PSO 准确性
%   运行：把 run_greenopt.m 顶部的 RUN_SELFTEST 改为 true 后运行本脚本

fprintf('%s\n', repmat('=', 1, 82));
fprintf('  模型自检：内层调度正确性 + 外层 PSO 准确性\n');
fprintf('  %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
fprintf('%s\n', repmat('=', 1, 82));

cfg.io.quiet       = true;
cfg.out.makePlots  = false;
cfg.out.writeExcel = false;
cfg.milp.display   = 'off';
cfg.pso.nPop       = 20;
cfg.pso.maxIter    = 15;
% 自检只验证「逻辑对不对」，不追求搜索质量，故关掉两个会成倍放大运行时间的机制：
%   · 边界诊断外扩：每外扩一次就多跑一整轮 PSO；
%   · 两阶段搜索：阶段 A 需要 ds，且自检本身用的是典型日口径（已经是「便宜的模型」）。
cfg.pso.boundCheck = false;
cfg.pso.twoStage   = false;
cfg.pso.multiRun   = 0;

% ---- 自检固定使用「典型日 + 逐日 SOC 闭合」口径 ----
% 自检必须与用户当前在 cfg_greenopt.m 里设的 time.mode / yearCyclic 解耦，
% 否则当 cfg 被改成 full_year 或 yearCyclic='year' 时，
% A/B 段的「典型日口径」校验会因场景结构不同而误判或索引越界。
cfg.time.mode         = 'typical_days';
cfg.time.nTypicalDays = cfg.selftest.nTypicalDays;
cfg.time.yearCyclic   = 'day';
cfg.ess.cycleMode     = 'day';
cfg.ess.fixInitialSoc = false;

nP = 0;  nF = 0;
[nP, nF] = gopt_hdr(nP, nF, 'A. 数据与场景一致性');

ds = gopt_load_dataset(cfg);
sc = gopt_build_scenario(ds, cfg);

[nP, nF] = gopt_chk(nP, nF, '数据行数为 8760（365 天）', ds.T == 8760 && ds.nDay == 365, ...
    sprintf('T=%d, nDay=%d', ds.T, ds.nDay));
[nP, nF] = gopt_chk(nP, nF, '典型日代表天数之和 = 全年天数', abs(sum(sc.dayWeight) - ds.nDay) < 1e-12, ...
    sprintf('ΣdayWeight=%d, nDay=%d', sum(sc.dayWeight), ds.nDay));
[nP, nF] = gopt_chk(nP, nF, '逐小时权重 x 步长之和 = 全年小时数', abs(sum(sc.w) * sc.dt - ds.T) < 1e-9, ...
    sprintf('Σw x dt=%.6f h, T=%d h', sum(sc.w) * sc.dt, ds.T));
[nP, nF] = gopt_chk(nP, nF, '场景时长 = 24 x 典型日个数', sc.T == 24 * numel(sc.cyclicGroups), ...
    sprintf('T=%d, K=%d', sc.T, numel(sc.cyclicGroups)));
[nP, nF] = gopt_chk(nP, nF, '每个簇均有成员（无空簇）', all(sc.dayWeight > 0), ...
    sprintf('dayWeight=%s', mat2str(sc.dayWeight')));

[nP, nF] = gopt_hdr(nP, nF, 'B. 内层最优调度正确性');

% ---- B1 无储能 + 禁止上网：与解析解逐点比对 ----
% cap 现在是 5 维（第 5 维 = 自发电容量）。这里刻意取 0，让解析式退化为
% 「光伏 + 风电」两源，比对关系最干净；自发电参与的情形放在 B2 之后单列（B6b/B9）。
cap0 = [40; 20; 0; 0; 0];
cfgB = cfg;  cfgB.const.gridExportMax = 0;
RB = gopt_milp(cap0, sc, cfgB);
pvAv = cap0(1) * sc.PV;  wtAv = cap0(2) * sc.WT;  genAv = cap0(5) * sc.Gen;
reAv = pvAv + wtAv + genAv;  ld = sc.load;
buyRef  = max(0, ld - reAv);
curtRef = max(0, reAv - ld);
errBuy  = max(abs(RB.P_buy  - buyRef));
errCurt = max(abs(RB.P_curt - curtRef));
costRef = sum(sc.w .* sc.buy * 1000 * sc.dt .* buyRef);
[nP, nF] = gopt_chk(nP, nF, 'B1 无储能+禁上网：购电与解析解一致', errBuy < 1e-6, ...
    sprintf('最大偏差 %.3e MW', errBuy));
[nP, nF] = gopt_chk(nP, nF, 'B1 无储能+禁上网：弃电与解析解一致', errCurt < 1e-6, ...
    sprintf('最大偏差 %.3e MW', errCurt));
[nP, nF] = gopt_chk(nP, nF, 'B1 无储能+禁上网：成本与解析解一致', ...
    abs(RB.cost - costRef) / max(abs(costRef), eps) < 1e-6, ...
    sprintf('MILP %.2f 元 vs 解析 %.2f 元', RB.cost, costRef));
[nP, nF] = gopt_chk(nP, nF, 'B1 禁止上网时售电量为 0', RB.energySell < 1e-6, ...
    sprintf('售电 %.3e MWh', RB.energySell));

% ---- B1b 自发电参与 + 燃料成本：解析解（★ 本轮新增）----
% 允许弃电、禁止上网时，最优调度就是「先用自有电源（光伏/风电/自发电）顶负荷，
% 顶不完的买电，多出来的按边际成本弃」。因为自发电的边际成本 0.2 元/kWh 高于
% 光伏/风电的 0，所以盈余时应当**先弃自发电**、最后才弃光伏 —— 这条正是用户
% 要的「不使用高成本电量、保留低成本电量」，这里用解析解把它钉死。
capG = [40; 20; 0; 0; 30];
RBg  = gopt_milp(capG, sc, cfgB);
pvG  = capG(1) * sc.PV;  wtG = capG(2) * sc.WT;  gnG = capG(5) * sc.Gen;
% 允许弃电、禁止上网、无储能时，总弃电量必然等于盈余量 surplus；其中
%   · 自发电那一路：因为它有 0.2 元/kWh 的边际成本，优化器会把它弃到「不能再弃」为止，
%     即 min(自发电出力, surplus)；
%   · 剩下的盈余由 光伏/风电 承担：两者边际成本都是 0，**在它们之间怎么分是退化的**
%     （无穷多组同样最优的解），因此这里只校验两者之和，不区分具体归谁。
surplus     = max(pvG + wtG + gnG - ld, 0);
curtGnRef   = min(gnG, surplus);
curtRestRef = max(surplus - gnG, 0);
[nP, nF] = gopt_chk(nP, nF, 'B1b 自发电燃料成本按实发电量计', ...
    abs(RBg.costGenVar - sum(sc.w .* RBg.P_gen * cfg.cost.gen.varCost * 1000 * sc.dt)) ...
        / max(abs(RBg.costGenVar), eps) < 1e-9, ...
    sprintf('成本项 %.4f 元 vs 复算 %.4f 元', RBg.costGenVar, ...
    sum(sc.w .* RBg.P_gen * cfg.cost.gen.varCost * 1000 * sc.dt)));
[nP, nF] = gopt_chk(nP, nF, 'B1b 分源弃电「先弃自发电」（与解析解一致）', ...
    max(abs(RBg.P_curtGen - curtGnRef)) < 1e-6 && ...
    max(abs((RBg.P_curtPV + RBg.P_curtWT) - curtRestRef)) < 1e-6, ...
    sprintf(['弃自发电偏差 %.3e MW；弃光伏+弃风电偏差 %.3e MW' ...
    '（光伏与风电之间边际成本同为 0，属退化最优，不做区分）'], ...
    max(abs(RBg.P_curtGen - curtGnRef)), ...
    max(abs((RBg.P_curtPV + RBg.P_curtWT) - curtRestRef))));
[nP, nF] = gopt_chk(nP, nF, 'B1b 自发电电量恒等式：实发 = 可用 - 弃', ...
    abs(RBg.energyGenAvail - RBg.energyCurtGen - RBg.energyGen) < 1e-6, ...
    sprintf('可用 %.4f - 弃 %.4f = %.4f（实发 %.4f）MWh', ...
    RBg.energyGenAvail, RBg.energyCurtGen, RBg.energyGenAvail - RBg.energyCurtGen, RBg.energyGen));
[nP, nF] = gopt_chk(nP, nF, 'B1b 分源弃电合计 = 三个分量之和', ...
    abs(RBg.energyCurt - (RBg.energyCurtPV + RBg.energyCurtWT + RBg.energyCurtGen)) < 1e-9, ...
    sprintf('合计 %.6f vs 分量和 %.6f MWh', RBg.energyCurt, ...
    RBg.energyCurtPV + RBg.energyCurtWT + RBg.energyCurtGen));

% ---- B1c 自发电不可弃口径（cfg.const.genCurtMode = 'no_curtail'）----
% ⚠ 这一模式必须允许上网：数据集里有 312 个零负荷小时，若同时禁止上网，自发电无处可去，
%   内层直接无可行解（下面第 4 条检查专门把这一点钉住，避免日后误判成程序 bug）。
cfgNc  = cfg;  cfgNc.const.genCurtMode = 'no_curtail';
capNc  = [40; 20; 0; 0; 20];
RNc    = gopt_milp(capNc, sc, cfgNc);
% 注意：R.message 只在「求解失败」分支里才有，成功时该字段不存在。
% gopt_chk 的实参是立即求值的，所以必须先判 ok 再取 message，否则会自己报错。
msgNc = '';   if ~RNc.ok,    msgNc = RNc.message;    end
[nP, nF] = gopt_chk(nP, nF, 'B1c 自发电不可弃（允许上网）：求解成功', RNc.ok, msgNc);
[nP, nF] = gopt_chk(nP, nF, 'B1c 自发电不可弃时弃自发电恒为 0', ...
    RNc.ok && max(RNc.P_curtGen) < 1e-9, ...
    sprintf('max 弃自发电 %.3e MW', max([RNc.P_curtGen; 0])));
[nP, nF] = gopt_chk(nP, nF, 'B1c 自发电不可弃时实发 = 可用', ...
    RNc.ok && abs(RNc.energyGen - RNc.energyGenAvail) < 1e-9, ...
    sprintf('可用 %.4f vs 实发 %.4f MWh', RNc.energyGenAvail, RNc.energyGen));
cfgNcBan = cfgNc;  cfgNcBan.const.gridExportMax = 0;      % 再禁止上网
RNcBan   = gopt_milp(capNc, sc, cfgNcBan);
msgBan = 'ok=1（意外：居然可行）';
if ~RNcBan.ok, msgBan = sprintf('ok=%d（%s）', RNcBan.ok, RNcBan.message); end
[nP, nF] = gopt_chk(nP, nF, 'B1c 自发电不可弃 + 禁上网 + 零负荷小时 => 无可行解（预期行为）', ...
    ~RNcBan.ok, [msgBan '——说明该组合本身建模不可行，不是求解器故障']);

% ---- B1d 可弃 vs 不可弃：可弃的自由度更多，运行成本不应更高 ----
cfgCn = cfg;  cfgCn.const.genCurtMode = 'economic';
RCn   = gopt_milp(capNc, sc, cfgCn);
[nP, nF] = gopt_chk(nP, nF, 'B1d 自发电可弃时运行成本不高于不可弃', ...
    RCn.ok && RNc.ok && RCn.cost <= RNc.cost + 1e-3, ...
    sprintf('可弃 %.2f 元 vs 不可弃 %.2f 元（差额 %+.2f，应为负或零）', ...
    RCn.cost, RNc.cost, RCn.cost - RNc.cost));

% ---- B2 一般配置：约束满足性 + 成本口径复算 ----
% capT 给足 5 维：第 5 维取 25 MW，让自发电在一般情形里也参与（否则这段只测了光风储）。
capT = [120; 30; 20; 40; 25];
RT = gopt_milp(capT, sc, cfg);
[nP, nF] = gopt_chk(nP, nF, 'B2 功率平衡残差 < 1e-6 MW', RT.maxResid < 1e-6, ...
    sprintf('残差 %.3e MW', RT.maxResid));
[nP, nF] = gopt_chk(nP, nF, 'B2 SOC 在上下限内', ...
    min(RT.E_soc) >= cfg.ess.socMin * capT(4) - 1e-6 && ...
    max(RT.E_soc) <= cfg.ess.socMax * capT(4) + 1e-6, ...
    sprintf('SOC 区间 [%.4f, %.4f]，限值 [%.4f, %.4f]', ...
    min(RT.E_soc), max(RT.E_soc), cfg.ess.socMin*capT(4), cfg.ess.socMax*capT(4)));
[nP, nF] = gopt_chk(nP, nF, 'B2 充放电功率不超过储能功率', ...
    max([RT.P_ch; RT.P_dis]) <= capT(3) + 1e-6, ...
    sprintf('max 充 %.4f / 放 %.4f MW <= %.4f', max(RT.P_ch), max(RT.P_dis), capT(3)));
[nP, nF] = gopt_chk(nP, nF, 'B2 无同时购售电', RT.simBuySellMWh < 1e-3, ...
    sprintf('重叠 %.3e MWh', RT.simBuySellMWh));

% SOC 周期闭合性：按 SOC 动态方程逐点回代（日循环模式）
cfgDay = cfg;  cfgDay.ess.cycleMode = 'day';
RD = gopt_milp(capT, sc, cfgDay);
sig = cfg.ess.selfDis;  dt = sc.dt;
socErr = 0;
for g = 1:numel(sc.cyclicGroups)
    grp = sc.cyclicGroups{g}(:);
    prev = [grp(end); grp(1:end-1)];
    lhs = RD.E_soc(grp);
    rhs = (1 - sig) * RD.E_soc(prev) + cfg.ess.etaCh * dt * RD.P_ch(grp) ...
          - dt / cfg.ess.etaDis * RD.P_dis(grp);
    socErr = max(socErr, max(abs(lhs - rhs)));
end
[nP, nF] = gopt_chk(nP, nF, 'B2 [day] SOC 动态方程与周期边界闭合', socErr < 1e-6, ...
    sprintf('最大闭合误差 %.3e MWh', socErr));

% 年加权能量中性模式：组内递推 + 全周期中性
cfgN = cfg;  cfgN.ess.cycleMode = 'neutral';
RN = gopt_milp(capT, sc, cfgN);
netE = 0;  socErrN = 0;
for g = 1:numel(sc.cyclicGroups)
    grp = sc.cyclicGroups{g}(:);
    netE = netE + sc.dayWeight(g) * (RN.E_soc(grp(end)) - RN.E0(g));
    rhs = (1 - sig) * [RN.E0(g); RN.E_soc(grp(1:end-1))] ...
          + cfg.ess.etaCh * dt * RN.P_ch(grp) - dt / cfg.ess.etaDis * RN.P_dis(grp);
    socErrN = max(socErrN, max(abs(RN.E_soc(grp) - rhs)));
end
[nP, nF] = gopt_chk(nP, nF, 'B2 [neutral] SOC 动态方程成立', socErrN < 1e-6, ...
    sprintf('最大误差 %.3e MWh', socErrN));
[nP, nF] = gopt_chk(nP, nF, 'B2 [neutral] 年加权能量中性 Σ w(E_end - E_start) = 0', ...
    abs(netE) < 1e-6, sprintf('净值 %.3e MWh', netE));
[nP, nF] = gopt_chk(nP, nF, 'B2 [neutral] 起始 SOC 满足上下限', ...
    all(RN.E0 >= cfg.ess.socMin * capT(4) - 1e-6) && all(RN.E0 <= cfg.ess.socMax * capT(4) + 1e-6), ...
    sprintf('E0 区间 [%.4f, %.4f]，限值 [%.4f, %.4f]', ...
    min(RN.E0), max(RN.E0), cfg.ess.socMin*capT(4), cfg.ess.socMax*capT(4)));

costRe = sum(sc.w .* sc.buy * 1000 * dt .* RT.P_buy) ...
       - sum(sc.w .* sc.sell * 1000 * dt .* RT.P_sell) ...
       + sum(sc.w .* RT.cGen * 1000 * dt .* RT.P_gen);     % ★ 自发电燃料成本要一起复算
[nP, nF] = gopt_chk(nP, nF, 'B2 成本口径复算一致（含自发电燃料成本）', ...
    abs(costRe - RT.cost) / max(abs(RT.cost), eps) < 1e-9, ...
    sprintf('复算 %.4f 元 vs 模型 %.4f 元', costRe, RT.cost));

% ---- B3 与 LP 松弛下界对比（检验 MILP 未偏离可行域最优）----
cfgL = cfg;  cfgL.milp.useBinary = false;  cfgL.milp.cdBinary = false;
RL = gopt_milp(capT, sc, cfgL);
gapPct = (RT.cost - RL.cost) / max(abs(RT.cost), eps) * 100;
[nP, nF] = gopt_chk(nP, nF, 'B3 MILP 成本不低于 LP 松弛下界', RL.cost <= RT.cost + 1e-6, ...
    sprintf('MILP %.2f 元 >= LP %.2f 元（对偶间隙 %.5f%%）', RT.cost, RL.cost, gapPct));

% ---- B4 配置储能不会使运行成本上升（经济单调性）----
R_no = gopt_milp([120; 30; 0; 0],  sc, cfg);
R_es = gopt_milp([120; 30; 20; 40], sc, cfg);
[nP, nF] = gopt_chk(nP, nF, 'B4 配置储能后运行成本不上升', R_es.cost <= R_no.cost + 1e-3, ...
    sprintf('无储能 %.2f -> 有储能 %.2f 万元/年（节省 %.2f）', ...
    R_no.cost / 1e4, R_es.cost / 1e4, (R_no.cost - R_es.cost) / 1e4));

% ---- B5 典型日加权后的年化电量能还原全年电量 ----
devE = abs(RT.energyLoad - sum(ds.load)) / sum(ds.load) * 100;
[nP, nF] = gopt_chk(nP, nF, 'B5 年化负荷电量还原全年电量（偏差 < 3%）', devE < 3.0, ...
    sprintf('典型日年化 %.0f MWh vs 全年 %.0f MWh（偏差 %.2f%%）', RT.energyLoad, sum(ds.load), devE));

% ---- B6 禁止上网 + 允许弃电时，弃电量应等于过剩可再生电量 ----
[nP, nF] = gopt_chk(nP, nF, 'B6 分源弃电上限各自受自身可用出力约束', ...
    all(RB.P_curtPV <= pvAv + 1e-6) && all(RB.P_curtWT <= wtAv + 1e-6) ...
    && all(RB.P_curtGen <= genAv + 1e-6), ...
    sprintf('max 弃PV %.4f<=%.4f / 弃WT %.4f<=%.4f / 弃Gen %.4f<=%.4f MW', ...
    max(RB.P_curtPV), max(pvAv), max(RB.P_curtWT), max(wtAv), ...
    max(RB.P_curtGen), max(genAv)));

% ---- B6b 全年/典型日模式下自发电量纲正确（标幺 x 容量，而不是把标幺当 MW）----
% 这条是本次改造最容易出的错：Gen 列现在是标幺，若哪一处漏乘容量，自发电量会整整
% 差一个容量倍数（本数据集下约差 25 倍）。用「总电量 = 容量 x 标幺累加量」直接钉死。
[nP, nF] = gopt_chk(nP, nF, 'B6b 自发电可用电量 = 容量 x 标幺累加量', ...
    abs(RT.energyGenAvail - capT(5) * sum(sc.w .* sc.Gen * dt)) < 1e-6, ...
    sprintf('模型 %.6f MWh vs 手算 %.6f MWh', RT.energyGenAvail, capT(5) * sum(sc.w .* sc.Gen * dt)));
[nP, nF] = gopt_chk(nP, nF, 'B6b 自发电容量为 0 时可用电量与燃料成本均为 0', ...
    abs(RB.energyGenAvail) < 1e-12 && abs(RB.costGenVar) < 1e-12, ...
    sprintf('可用 %.3e MWh，燃料成本 %.3e 元', RB.energyGenAvail, RB.costGenVar));

% ---- B7 默认求解间隙下成本已足够接近精确解 ----
cfgT2 = cfg;  cfgT2.milp.relGap = 1e-7;
Rt = gopt_milp(capT, sc, cfgT2);
devGap = abs(RT.cost - Rt.cost) / max(abs(Rt.cost), eps) * 100;
[nP, nF] = gopt_chk(nP, nF, 'B7 搜索间隙下的成本接近精确解（偏差 < 0.1%）', devGap < 0.1, ...
    sprintf('relGap=%.0e: %.2f 元 vs 精确 %.2f 元（偏差 %.5f%%）', cfg.milp.relGap, RT.cost, Rt.cost, devGap));

% ---- B8 典型日模型 与 全年 8760h 的运行成本一致性（压缩时域的近似误差）----
capN = [120; 30; 20; 160; 25];          % 8 h 时长，跨日搬运能力明显，最能暴露循环假设差异
RnD  = gopt_milp(capN, sc,  cfg);       % 典型日模型（默认 day 循环）
cfgFY = cfg;  cfgFY.time.mode = 'full_year';  cfgFY.io.quiet = true;
scFY  = gopt_build_scenario(ds, cfgFY);
Rfy   = gopt_milp(capN, scFY, cfgFY);
devFY = (RnD.cost - Rfy.cost) / max(abs(Rfy.cost), eps) * 100;
% 容差取 15% 而不是 10%：本配置刻意极端（光伏 120 MW 远超负荷、储能 8 h、自发电 25 MW），
% 而自发电是一条「可弃、且弃了能省钱」的电源，k-means 典型日会把盈余/缺口的时间形态抹平，
% 从而系统性低估弃电量 —— 时域压缩误差因此比纯风光储配置更大。这条偏差正是
% cfg.out.fullYearCheck 存在的意义（正式结论一律以全年口径为准），故只做「量级」把关。
[nP, nF] = gopt_chk(nP, nF, 'B8 典型日模型与全年 8760h 成本偏差 < 15%', abs(devFY) < 15.0, ...
    sprintf(['典型日 %.2f 元 vs 全年 %.2f 元（偏差 %+.3f%%；压缩时域的近似误差，符号不固定。' ...
    '含可弃自发电的配置该偏差会明显大于纯风光储）'], RnD.cost, Rfy.cost, devFY));

%% =====================================================================
[nP, nF] = gopt_hdr(nP, nF, 'C. 外层 PSO 准确性');

cfgG = cfg;
cfgG.time.nTypicalDays = cfg.selftest.nTypicalDays;
cfgG.pso.nPop    = 20;
cfgG.pso.maxIter = 15;
gridPV = cfg.selftest.gridPV(:);
gridWT = cfg.selftest.gridWT(:);
gridP  = cfg.selftest.gridP(:);
gridT  = cfg.selftest.gridT;
gridGen = cfg.selftest.gridGen(:);          % ★ 本轮新增：自发电容量网格
cfgG.pso.lb = [min(gridPV); min(gridWT); min(gridP); gridT; min(gridGen)];
cfgG.pso.ub = [max(gridPV); max(gridWT); max(gridP); gridT; max(gridGen)];
scG = gopt_build_scenario(ds, cfgG);

% ---- C1 全维固定 => 跳过搜索 ----
cfgC1 = cfgG;
cfgC1.pso.lb = [50; 20; 10; 2; 40];
cfgC1.pso.ub = [50; 20; 10; 2; 40];
rC1 = gopt_pso(cfgC1, scG);
[nP, nF] = gopt_chk(nP, nF, 'C1 全维固定时识别为固定配置且只求解 1 次', ...
    rC1.fixedMode && rC1.nEval == 1, ...
    sprintf('fixedMode=%d, nEval=%d', rC1.fixedMode, rC1.nEval));
[nP, nF] = gopt_chk(nP, nF, 'C1 固定容量按给值返回（储能容量 = 功率 x 时长；自发电 = 第 5 维）', ...
    abs(rC1.cap(1) - 50) < 1e-9 && abs(rC1.cap(3) - 10) < 1e-9 && ...
    abs(rC1.s(4) - 2) < 1e-9 && abs(rC1.cap(4) - 20) < 1e-9 && abs(rC1.cap(5) - 40) < 1e-9, ...
    sprintf('cap = [%.3f %.3f %.3f %.3f %.3f], s4 = %.3f', rC1.cap, rC1.s(4)));

% ---- C2 相同种子结果可复现 ----
cfgC2 = cfgG;  cfgC2.pso.localRefine = false;
rA1 = gopt_pso(cfgC2, scG);
rA2 = gopt_pso(cfgC2, scG);
[nP, nF] = gopt_chk(nP, nF, 'C2 相同随机种子下 PSO 结果完全可复现', ...
    abs(rA1.fit - rA2.fit) < 1e-9 && isequal(rA1.s, rA2.s), ...
    sprintf('两次结果 %.6f 元 / %.6f 元', rA1.fit, rA2.fit));

% ---- C3 与网格搜索对比（PSO 不劣于细网格）----
% 网格在 5 维上做（光伏 x 风电 x 储能功率 x 自发电容量，储能时长固定）。
% 网格用的是 cfg.selftest.grid*（点数刻意取稀，否则 5 维组合数会把自检拖到十几分钟）。
gBest = inf;  gBestS = [nan nan nan nan nan];
for a = gridPV'
    for b = gridWT'
        for c = gridP'
            for e = gridGen'
                capD = [a; b; c; c * gridT; e];
                Rd = gopt_milp(capD, scG, cfgG);
                if Rd.ok
                    fv = gopt_annual_capex(capD, cfgG, Rd) + Rd.cost;
                    if fv < gBest, gBest = fv;  gBestS = [a b c gridT e]; end
                end
            end
        end
    end
end
rAG = gopt_pso(cfgG, scG);
tolPct = cfg.selftest.tolPct;
relDev = (rAG.fit - gBest) / max(abs(gBest), eps) * 100;
[nP, nF] = gopt_chk(nP, nF, sprintf('C3 PSO 结果不劣于网格搜索（容差 %.2f%%）', tolPct), ...
    rAG.fit <= gBest * (1 + tolPct / 100) + 1e-6, ...
    sprintf(['PSO %.2f 万元/年 [PV %.1f WT %.1f Pess %.1f Tess %.2f Gen %.1f] vs ' ...
    '网格 %.2f 万元/年 [PV %g WT %g Pess %g Tess %g Gen %g]（相对差 %.4f%%）'], ...
    rAG.fit / 1e4, rAG.s(1), rAG.s(2), rAG.s(3), rAG.s(4), rAG.s(5), gBest / 1e4, ...
    gBestS(1), gBestS(2), gBestS(3), gBestS(4), gBestS(5), relDev));

% ---- C4 PSO 最优配置回代一致 ----
cfgC4 = cfgG;
cfgC4.pso.lb = rAG.s(:);
cfgC4.pso.ub = rAG.s(:);
rC4 = gopt_pso(cfgC4, scG);
[nP, nF] = gopt_chk(nP, nF, 'C4 把 PSO 最优配置固定后回代，成本一致', ...
    abs(rC4.fit - rAG.fit) <= max(1, abs(rAG.fit)) * 1e-6, ...
    sprintf('回代 %.4f 元 vs 搜索 %.4f 元', rC4.fit, rAG.fit));

% ---- C5 扩大搜索域不应使最优值变差 ----
cfgS = cfgG;  cfgS.pso.lb = [0; 0; 0; gridT; 0];  cfgS.pso.ub = [100; 25; 10; gridT; 50];
cfgB2 = cfgG; cfgB2.pso.lb = [0; 0; 0; gridT; 0]; cfgB2.pso.ub = [200; 50; 20; gridT; 100];
rS = gopt_pso(cfgS,  scG);
rB = gopt_pso(cfgB2, scG);
[nP, nF] = gopt_chk(nP, nF, 'C5 扩大搜索域后最优成本不劣化', rB.fit <= rS.fit * (1 + 5e-3) + 1e-6, ...
    sprintf('小域 [PV<=100 WT<=25 Pess<=10 Gen<=50] %.2f 元 -> 大域 [PV<=200 WT<=50 Pess<=20 Gen<=100] %.2f 元', ...
    rS.fit, rB.fit));

%% =====================================================================
[nP, nF] = gopt_hdr(nP, nF, 'D. 储能时长变量的换算正确性');

% ---- D1 PSO 返回的 s 与 cap 满足 容量 = 功率 x 时长 ----
[nP, nF] = gopt_chk(nP, nF, 'D1 储能容量 = 储能功率 x 储能时长', ...
    abs(rAG.cap(4) - rAG.cap(3) * rAG.s(4)) < 1e-9, ...
    sprintf('Pess=%.4f MW, Tess=%.4f h -> Eess=%.4f MWh', rAG.cap(3), rAG.s(4), rAG.cap(4)));
% ★ 本轮新增：第 5 维（自发电容量）不参加任何派生换算，必须原样传下去
[nP, nF] = gopt_chk(nP, nF, 'D1b 自发电容量原样传递（cap(5) = s(5)）', ...
    abs(rAG.cap(5) - rAG.s(5)) < 1e-9, ...
    sprintf('s(5)=%.4f MW -> cap(5)=%.4f MW', rAG.s(5), rAG.cap(5)));

% ---- D2 直接给容量 与 给功率x时长 等价 ----
cfgD1 = cfg;  cfgD1.fixed.pv = 30;  cfgD1.fixed.wt = 20;
cfgD1.fixed.essP = 10;  cfgD1.fixed.essT = 2;          % 10 MW x 2 h = 20 MWh
cfgD1 = gopt_apply_fixed(cfgD1);
rD1 = gopt_pso(cfgD1, sc);

cfgD2 = cfg;  cfgD2.fixed.pv = 30;  cfgD2.fixed.wt = 20;
cfgD2.fixed.essP = 10;  cfgD2.fixed.esse = 20;         % 直接给 20 MWh
cfgD2 = gopt_apply_fixed(cfgD2);
rD2 = gopt_pso(cfgD2, sc);

[nP, nF] = gopt_chk(nP, nF, 'D2 由容量换算的时长与直接给时长等价', ...
    abs(rD2.cap(4) - rD1.cap(4)) < 1e-9 && abs(rD2.s(4) - 2) < 1e-9 && ...
    abs(rD2.fit - rD1.fit) < max(1, abs(rD1.fit)) * 1e-9, ...
    sprintf('容量 %s: %.4f MWh / %.4f MWh，成本 %.2f / %.2f 元', ...
    '时长法 vs 容量法', rD1.cap(4), rD2.cap(4), rD1.fit, rD2.fit));

% ---- D3 储能功率固定为 0 时时长维度自动折叠 ----
cfgD3 = cfg;  cfgD3.fixed.essP = 0;  cfgD3.fixed.pv = 30;  cfgD3.fixed.wt = 20;
cfgD3 = gopt_apply_fixed(cfgD3);
cfgD3.pso.maxIter = 3;  cfgD3.pso.nPop = 6;
rD3 = gopt_pso(cfgD3, sc);
[nP, nF] = gopt_chk(nP, nF, 'D3 储能功率为 0 时储能容量恒为 0', ...
    abs(rD3.cap(4)) < 1e-12 && abs(rD3.cap(3)) < 1e-12, ...
    sprintf('Pess=%.4f MW, Eess=%.4f MWh', rD3.cap(3), rD3.cap(4)));

% ---- D4 自发电容量固定为 0 => 完全等价「自发电不参与」的旧口径（★ 本轮新增）----
% 这条是本次改造的「兼容性护栏」：只要 cfg.fixed.gen = 0，新模型就应退化为旧模型，
% 用同一份数据、同一套参数跑出来的成本差异只应来自「弃电由 1 个变量拆成 3 个」带来的
% 自由度（在容量为 0 时该自由度并不存在），所以两者应当完全相同。
cfgD4 = cfg;  cfgD4.fixed.pv = 60;  cfgD4.fixed.wt = 20;
cfgD4.fixed.essP = 10;  cfgD4.fixed.essT = 2;  cfgD4.fixed.gen = 0;
cfgD4 = gopt_apply_fixed(cfgD4);
rD4 = gopt_pso(cfgD4, sc);
[nP, nF] = gopt_chk(nP, nF, 'D4 自发电容量固定为 0 时，自发电电量与成本均为 0', ...
    abs(rD4.cap(5)) < 1e-12 && abs(rD4.R.energyGenAvail) < 1e-12 && ...
    abs(rD4.R.energyGen) < 1e-12 && abs(rD4.R.costGenVar) < 1e-12, ...
    sprintf('cap(5)=%.3f MW，可用 %.3e MWh，实发 %.3e MWh，燃料成本 %.3e 元', ...
    rD4.cap(5), rD4.R.energyGenAvail, rD4.R.energyGen, rD4.R.costGenVar));
[nP, nF] = gopt_chk(nP, nF, 'D4 自发电容量固定为 0 时，投资成本中自发电部分为 0', ...
    abs(gopt_gen_cost(rD4.cap, cfg, rD4.R).annual) < 1e-9, ...
    sprintf('年化投资合计 %.4f 元，其中自发电 %.4f 元', ...
    rD4.costCapex, gopt_gen_cost(rD4.cap, cfg, rD4.R).annual));

%% =====================================================================
[nP, nF] = gopt_hdr(nP, nF, 'E. 投资成本口径（flat 常数单价 / tiered 分档单价）');

% 本节直接校验「投资额怎么随装机容量变」这条链条。为什么必须钉住：分档单价把投资成本
% 从一个线性项改成了非线性项，一旦插值边界、封顶口径或单位换算写错，成本会悄悄偏几个
% 百分点 —— 这种错在结果表里完全看不出来（数值都「看着正常」），只能靠恒等式拦住。
capE  = [37.5; 12; 15; 30; 10];     % MW / MW / MW / MWh / MW（刻意取非整数，避开档位结点）
cfgFl = cfg;  cfgFl.cost.mode = 'flat';
cfgTi = cfg;  cfgTi.cost.mode = 'tiered';
iDis  = cfg.cost.discountRate;

% ---- E1 flat 口径：年化投资 = Σ 容量 x 常数单价 x (CRF + 运维) ----
[ctF, dF] = gopt_annual_capex(capE, cfgFl, RT);
expF = capE(1)*1000*cfg.cost.pv.capex   * (gopt_crf(iDis, cfg.cost.pv.life)   + cfg.cost.pv.opexRate) ...
     + capE(2)*1000*cfg.cost.wt.capex   * (gopt_crf(iDis, cfg.cost.wt.life)   + cfg.cost.wt.opexRate) ...
     + capE(3)*1000*cfg.cost.ess.capexP * (gopt_crf(iDis, dF.lifeEss)         + cfg.cost.ess.opexRate) ...
     + capE(4)*1000*cfg.cost.ess.capexE * (gopt_crf(iDis, dF.lifeEss)         + cfg.cost.ess.opexRate) ...
     + capE(5)*1000*cfg.cost.gen.capex  * (gopt_crf(iDis, cfg.cost.gen.life)  + cfg.cost.gen.opexRate);
[nP, nF] = gopt_chk(nP, nF, 'E1 flat 口径：年化投资 = Σ 容量 x 常数单价 x (CRF + 运维)', ...
    abs(ctF - expF) / max(abs(expF), eps) < 1e-12, ...
    sprintf('模型 %.6f 元 vs 手算 %.6f 元', ctF, expF));

% ---- E2 flat 口径下分档表必须被完全忽略 ----
% 防的是「以为切了口径其实没切」：故意塞一张荒谬的分档表（1 元/kW），flat 结果必须不变。
cfgFl2 = cfgFl;  cfgFl2.cost.pv.tier = [0 1; 100 1];
[ctF2, ~] = gopt_annual_capex(capE, cfgFl2, RT);
[nP, nF] = gopt_chk(nP, nF, 'E2 flat 口径下分档表被完全忽略（换成 1 元/kW 的表结果不变）', ...
    abs(ctF2 - ctF) < 1e-9, sprintf('原 %.6f 元 vs 换表后 %.6f 元', ctF, ctF2));

% ---- E3 分段线性插值：相邻档位之间线性过渡（手工复算）----
[pPV, uPV] = gopt_unit_price(capE(1), 'tiered', cfg.cost.pv.capex, cfg.cost.pv.tier, 'MW', '元/kW');
pPVref = 3100 + (3000 - 3100) * (capE(1) - 20) / (50 - 20);          % 37.5 MW 落在 20~50 档
[pWT, uWT] = gopt_unit_price(capE(2), 'tiered', cfg.cost.wt.capex, cfg.cost.wt.tier, 'MW', '元/kW');
pWTref = 4611.75 + (4504.5 - 4611.75) * (capE(2) - 6) / (20 - 6);    % 12 MW 落在 6~20 档
[nP, nF] = gopt_chk(nP, nF, 'E3 分档单价 = 相邻档位间线性插值（手工复算）', ...
    abs(pPV - pPVref) < 1e-9 && abs(pWT - pWTref) < 1e-9 && uPV.idx == 3 && uWT.idx == 2, ...
    sprintf('光伏 %.6f vs %.6f（第 %d 档）；风电 %.6f vs %.6f（第 %d 档）', ...
    pPV, pPVref, uPV.idx, pWT, pWTref, uWT.idx));

% ---- E4 档位结点处单价连续（只有斜率变，没有台阶）----
% 分段线性插值的核心性质。用极小偏移逼近左右极限，偏差应远小于 1e-3 元/kW。
nBad = 0;  dd = 1e-7;
for xk = [6 20 50 100 200]
    pL = gopt_unit_price(xk - dd, 'tiered', cfg.cost.wt.capex, cfg.cost.wt.tier, 'MW', '元/kW');
    pR = gopt_unit_price(xk + dd, 'tiered', cfg.cost.wt.capex, cfg.cost.wt.tier, 'MW', '元/kW');
    if abs(pL - pR) > 1e-3, nBad = nBad + 1; end
end
[nP, nF] = gopt_chk(nP, nF, 'E4 分档单价在档位结点处连续（无台阶、无跳变）', nBad == 0, ...
    sprintf('结点 6/20/50/100/200 中不连续的个数 = %d', nBad));

% ---- E5 容量 >= 封顶档位时直接取 20000 档的单价（不插值、不外推）----
% 用风电表验证最合适：它的 500 与 20000 两档单价不同（4182.75 vs 3968.25），
% 若错写成「继续线性插值」或「外推」，这里的三个点马上对不上。
xW    = cfg.cost.wt.tier;   pTopW = xW(end, 2);
pk    = zeros(3, 1);
pk(1) = gopt_unit_price(500,   'tiered', cfg.cost.wt.capex, xW, 'MW', '元/kW');
pk(2) = gopt_unit_price(5000,  'tiered', cfg.cost.wt.capex, xW, 'MW', '元/kW');
pk(3) = gopt_unit_price(50000, 'tiered', cfg.cost.wt.capex, xW, 'MW', '元/kW');
[nP, nF] = gopt_chk(nP, nF, 'E5 容量 >= 500 MW 时单价 = 20000 档的单价', ...
    all(abs(pk - pTopW) < 1e-12), ...
    sprintf('500/5000/50000 MW -> %.4f / %.4f / %.4f 元/kW；20000 档 = %.4f', ...
    pk(1), pk(2), pk(3), pTopW));

% ---- E6 储能功率(元/kW) 与 储能容量(元/kWh) 各自独立分档 ----
[pP, uP] = gopt_unit_price(capE(3), 'tiered', cfg.cost.ess.capexP, cfg.cost.ess.tierP, 'MW',  '元/kW');
[pEs, uEs] = gopt_unit_price(capE(4), 'tiered', cfg.cost.ess.capexE, cfg.cost.ess.tierE, 'MWh', '元/kWh');
pPref =  500 + (480 - 500) * (capE(3) -  6) / (20 -  6);      % 15 MW
pEref =  800 + (760 - 800) * (capE(4) - 20) / (50 - 20);      % 30 MWh
[nP, nF] = gopt_chk(nP, nF, 'E6 储能功率与储能容量各自独立分档（两张表、两个量纲）', ...
    abs(pP - pPref) < 1e-9 && abs(pEs - pEref) < 1e-9, ...
    sprintf('功率 %.6f vs %.6f 元/kW（第 %d 档）；容量 %.6f vs %.6f 元/kWh（第 %d 档）', ...
    pP, pPref, uP.idx, pEs, pEref, uEs.idx));

% ---- E7 tiered 口径：年化投资 = Σ 容量 x 插值单价 x (CRF + 运维) ----
[ctT, dT] = gopt_annual_capex(capE, cfgTi, RT);
expT = capE(1)*1000*dT.price.pv   * (gopt_crf(iDis, cfg.cost.pv.life)   + cfg.cost.pv.opexRate) ...
     + capE(2)*1000*dT.price.wt   * (gopt_crf(iDis, cfg.cost.wt.life)   + cfg.cost.wt.opexRate) ...
     + capE(3)*1000*dT.price.essP * (gopt_crf(iDis, dT.lifeEss)         + cfg.cost.ess.opexRate) ...
     + capE(4)*1000*dT.price.essE * (gopt_crf(iDis, dT.lifeEss)         + cfg.cost.ess.opexRate) ...
     + capE(5)*1000*dT.price.gen  * (gopt_crf(iDis, cfg.cost.gen.life)  + cfg.cost.gen.opexRate);
[nP, nF] = gopt_chk(nP, nF, 'E7 tiered 口径：年化投资 = Σ 容量 x 插值单价 x (CRF + 运维)', ...
    abs(ctT - expT) / max(abs(expT), eps) < 1e-12, ...
    sprintf('模型 %.6f 元 vs 手算 %.6f 元', ctT, expT));

% ---- E8 一次投资额 = Σ 容量 x 单价；且四项分档、自发电不分档 ----
expInv = 1000 * (capE(1)*dT.price.pv + capE(2)*dT.price.wt + capE(3)*dT.price.essP ...
               + capE(4)*dT.price.essE + capE(5)*dT.price.gen);
[nP, nF] = gopt_chk(nP, nF, 'E8 一次投资额合计 = Σ 容量 x 单价（分档标志正确）', ...
    abs(dT.totalInv - expInv) / max(abs(expInv), eps) < 1e-12 && ...
    dT.u.pv.isTier && dT.u.wt.isTier && dT.u.essP.isTier && dT.u.essE.isTier && ~dT.u.gen.isTier, ...
    sprintf(['模型 %.6f 元 vs 手算 %.6f 元；分档标志 pv/wt/essP/essE/gen = %d/%d/%d/%d/%d' ...
    '（自发电按用户指定恒为常数单价，故最后一个必须为 0）'], ...
    dT.totalInv, expInv, dT.u.pv.isTier, dT.u.wt.isTier, dT.u.essP.isTier, dT.u.essE.isTier, dT.u.gen.isTier));

% ---- E9 阶梯明细恒等式：各档贡献之和 = 该资产的一次投资额 ----
% 这条保证「分档明细」工作表乙块可信：链式分解在分段线性插值下是**精确恒等式**。
itE    = gopt_price_items(capE, dT, cfgTi);
maxDev = 0;
for k = 1:numel(itE)
    if ~itE(k).info.isTier, continue; end
    [~, ~, tot] = gopt_tier_chain(itE(k).info, itE(k).qty);
    maxDev = max(maxDev, abs(tot - itE(k).qty * itE(k).info.p / 10));
end
[nP, nF] = gopt_chk(nP, nF, 'E9 阶梯明细：各档贡献之和 = 一次投资额（链式分解恒等式）', ...
    maxDev < 1e-9, sprintf('四项资产的最大偏差 %.3e 万元（应 ~0）', maxDev));

% ---- E10 分档表非法输入必须被拦下（档位乱序 / 列数不对 / 单价为 0）----
badCnt = 0;
try, gopt_check_tier('E10 档位乱序', [0 100; 20 90; 10 80]); catch, badCnt = badCnt + 1; end
try, gopt_check_tier('E10 列数不对', [0 100 5; 6 90 4]);     catch, badCnt = badCnt + 1; end
try, gopt_check_tier('E10 单价为 0', [0 0; 6 90]);           catch, badCnt = badCnt + 1; end
[nP, nF] = gopt_chk(nP, nF, 'E10 分档表非法输入全部被拦下（档位乱序 / 列数不对 / 单价 0）', ...
    badCnt == 3, sprintf('3 种非法输入中拦下 %d 种', badCnt));

% ---- E11 两种口径都能算出有限正成本（不发生 NaN / Inf）----
[nP, nF] = gopt_chk(nP, nF, 'E11 flat 与 tiered 两种口径的年化投资均为有限正值', ...
    isfinite(ctF) && ctF > 0 && isfinite(ctT) && ctT > 0, ...
    sprintf('flat %.2f 万元/年 -> tiered %.2f 万元/年（同一配置、同一调度）', ctF / 1e4, ctT / 1e4));

%% =====================================================================
fprintf('\n%s\n', repmat('=', 1, 82));
if nF == 0
    fprintf('  自检结果：全部 %d 项通过\n', nP);
else
    fprintf('  自检结果：通过 %d 项，失败 %d 项 —— 请检查上方标 [FAIL] 的条目\n', nP, nF);
end
fprintf('%s\n', repmat('=', 1, 82));
end

function [nP, nF] = gopt_hdr(nP, nF, title)
fprintf('\n--- %s ---\n', title);
end

function [nP, nF] = gopt_chk(nP, nF, name, cond, detail)
if cond
    fprintf('  [PASS] %s\n', name);
    nP = nP + 1;
else
    fprintf('  [FAIL] %s\n', name);
    nF = nF + 1;
end
if nargin >= 5 && ~isempty(detail)
    fprintf('         %s\n', detail);
end
end
%