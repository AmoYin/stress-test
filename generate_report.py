#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#=============================================================================
# generate_report.py — 压测数据汇总, 生成 HTML 报告
# 用法: python3 generate_report.py <monitor.csv> <输出.html>
# 依赖: 无第三方库 (纯标准库), 图表使用内嵌 Chart.js CDN
# 适用: 任意 x86_64 服务器 / RHEL 8.x (CPU 型号/频率/OS 动态读取, 不写死)
#
# v2.6 (2026-10-20) 报告端：稳态窗口统计 + stress-ng 执行结果 + 基线频率可指定
#   - 默认剔除首尾空载过渡样本再统计 (采样稀疏时 2 个空载点就能把内存均值
#     90.7% 拉低到 84.4%, 把一次满载通过误判为未达标); --no-steady 恢复旧口径
#   - --stress-log: 从 stress-ng 日志抽取 bogo ops / passed / failed 生成执行结果卡片
#   - --base-freq: 离线生成报告时指定基频; 读不到基频不再用 1500MHz 兜底硬判"正常"
#
# v2.4 (2026-10-20) 报告纳入内存 ECC (EDAC) 判定
#   - 新增 KPI 卡片: 内存 CE / UE 累计
#   - 新增曲线: 内存 ECC 错误累计 (CE / UE 双线)
#   - 关键指标汇总新增 4 行 (CE/UE 累计与新增的 min/avg/max)
#   - 稳定性判定新增 2 行: 内存无 UE (出现即失败) / 内存无 CE (新增即告警)
#   - 新增 "ECC 错误定位 (EDAC)" 卡片: 按 CE 降序列出 控制器/DIMM:错误数
#   - 旧版 CSV (无 EDAC 列) 自动降级为 "未采集", 不判通过、不影响其余版式
#=============================================================================

import csv
import os
import re
import sys
import json
from datetime import datetime


def parse_csv(path):
    """读取监控 CSV, 返回 (metadata, rows).
    顶部以 '#' 开头的行是元数据 (如 '# cpu_model: AMD EPYC ...'), 其余为数据行."""
    metadata = {}
    data_lines = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.rstrip("\n")
            stripped = line.strip()
            if stripped.startswith("#"):
                m = re.match(r"^#\s*([^:]+):\s*(.*)$", stripped)
                if m:
                    metadata[m.group(1).strip()] = m.group(2).strip()
                continue
            data_lines.append(line)

    rows = []
    numeric_fields = ("cpu_usage_pct", "cpu_freq_mhz", "mem_used_gb",
                      "mem_total_gb", "mem_usage_pct", "load_1m",
                      "load_5m", "load_15m", "cpu_temp_c", "power_w",
                      "context_switches", "processes",
                      # v2.4 内存 ECC (旧版 CSV 无这些列, 解析结果为 None, 报告自动降级)
                      "edac_ce_total", "edac_ue_total",
                      "edac_ce_delta", "edac_ue_delta")
    reader = csv.DictReader(data_lines)
    for line in reader:
        row = {}
        for k, v in line.items():
            k = k.strip()
            v = v.strip()
            if k in numeric_fields:
                try:
                    row[k] = float(v) if v not in ("N/A", "") else None
                except ValueError:
                    row[k] = None
            else:
                row[k] = v
        rows.append(row)
    if not rows:
        sys.exit("[ERROR] CSV 无数据行: %s" % path)
    return metadata, rows


def to_num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def stats(rows, key):
    """返回 (min, avg, max) 三元组, 忽略 None."""
    vals = [to_num(r.get(key)) for r in rows]
    vals = [v for v in vals if v is not None]
    if not vals:
        return (None, None, None)
    return (min(vals), sum(vals) / len(vals), max(vals))


def fmt(v, nd=1):
    if v is None:
        return "N/A"
    return "%.*f" % (nd, v)


def build_chart_data(rows, fields, colors, names=None):
    """把行数据转成 Chart.js 数据集. names 可选, 用于图例显示中文名."""
    labels = [r.get("datetime", "") for r in rows]
    datasets = []
    for i, (field, color) in enumerate(zip(fields, colors)):
        data = [r.get(field) if r.get(field) is not None else None for r in rows]
        datasets.append({
            "label": (names[i] if names and i < len(names) else field),
            "data": data,
            "borderColor": color,
            "backgroundColor": color + "22",
            "borderWidth": 1.5,
            "pointRadius": 0,
            "tension": 0.2,
            "fill": False,
        })
    return {"labels": labels, "datasets": datasets}


def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def trim_transient(rows, cpu_key="cpu_usage_pct", low_pct=50.0):
    """剔除首尾非满载过渡样本 (压测启动前的空闲点 / 压测结束后的降温点).

    采样点稀疏时这一步是必需的: 满负载下 BMC (ipmitool/KCS) 响应会变慢,
    实际采样间隔可能从 10s 退化成 2 分钟以上, 1 小时只剩 20~30 个点;
    此时首尾各 1 个空载点就能把平均值拉低 5~10 个百分点, 把一次满载通过
    的压测判成 "CPU/内存未达标"。

    只裁首尾, 不裁中间的掉载 —— 中间掉负载是真实问题, 必须保留在统计里。
    返回 (稳态行, 头部裁剪数, 尾部裁剪数); 找不到满载点或点数不足时原样返回。
    """
    n = len(rows)
    if n < 3:
        return rows, 0, 0
    hits = [i for i, r in enumerate(rows)
            if (to_num(r.get(cpu_key)) or 0.0) >= low_pct]
    if len(hits) < 2:
        return rows, 0, 0
    first, last = hits[0], hits[-1]
    if first == 0 and last == n - 1:
        return rows, 0, 0
    return rows[first:last + 1], first, n - 1 - last


def parse_stress_log(path):
    """从 stress-ng 运行日志提取执行结果 (stressor 并发数 / bogo ops / 通过失败计数).

    报告原来只有 monitor 侧的宿主指标, 缺 "压测引擎自己跑成了什么样" 的证据链;
    补上后 bogo ops 可作为同机型横向对比的吞吐基线。
    """
    info = {"stressors": None, "metrics": [], "passed": None, "failed": None,
            "skipped": None, "completed": None}
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.rstrip("\n")
                m = re.search(r"dispatching hogs:\s*(.+)$", line)
                if m and not info["stressors"]:
                    info["stressors"] = m.group(1).strip()
                m = re.match(
                    r"^stress-ng: metrc:\s+\[\d+\]\s+(\w+)\s+(\d+)\s+"
                    r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", line)
                if m:
                    info["metrics"].append({
                        "name": m.group(1),
                        "bogo": int(m.group(2)),
                        "real": float(m.group(3)),
                        "usr": float(m.group(4)),
                        "sys": float(m.group(5)),
                        "rate": float(m.group(6)),
                    })
                m = re.search(r"\bpassed:\s*(.+)", line)
                if m:
                    info["passed"] = m.group(1).strip()
                m = re.search(r"\bfailed:\s*(\d+)", line)
                if m:
                    info["failed"] = int(m.group(1))
                m = re.search(r"\bskipped:\s*(\d+)", line)
                if m:
                    info["skipped"] = int(m.group(1))
                m = re.search(r"successful run completed in (.+)$", line)
                if m:
                    info["completed"] = m.group(1).strip()
    except OSError:
        return None
    if not info["metrics"] and info["passed"] is None:
        return None
    return info


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>系统满负载压测报告</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
  :root { --bg:#f5f7fa; --card:#ffffff; --text:#1f2937; --muted:#6b7280;
          --accent:#2563eb; --border:#e5e7eb; --good:#059669; --warn:#d97706; --bad:#dc2626; }
  * { margin:0; padding:0; box-sizing:border-box; }
  body { background:var(--bg); color:var(--text); font-family:-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif; padding:24px; }
  .container { max-width:1200px; margin:0 auto; }
  h1 { font-size:26px; margin-bottom:4px; }
  .subtitle { color:var(--muted); font-size:14px; margin-bottom:24px; }
  .meta-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:16px; margin-bottom:24px; }
  .meta-card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:16px; }
  .meta-card h3 { font-size:13px; color:var(--muted); font-weight:500; margin-bottom:8px; }
  .meta-card .val { font-size:20px; font-weight:700; }
  .kpi-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:16px; margin-bottom:24px; }
  .kpi { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:16px; text-align:center; }
  .kpi .label { font-size:12px; color:var(--muted); margin-bottom:6px; }
  .kpi .num { font-size:24px; font-weight:700; }
  .kpi .range { font-size:12px; color:var(--muted); margin-top:4px; }
  .chart-card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:16px; margin-bottom:24px; }
  .chart-card h2 { font-size:16px; margin-bottom:12px; }
  .chart-wrap { position:relative; height:320px; }
  .table-card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:16px; margin-bottom:24px; overflow-x:auto; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th,td { padding:8px 12px; text-align:left; border-bottom:1px solid var(--border); }
  th { background:#f9fafb; font-weight:600; }
  .badge { display:inline-block; padding:2px 10px; border-radius:999px; font-size:12px; font-weight:600; }
  .badge.ok { background:#ecfdf5; color:var(--good); }
  .badge.warn { background:#fffbeb; color:var(--warn); }
  .badge.bad { background:#fef2f2; color:var(--bad); }
  footer { color:var(--muted); font-size:12px; text-align:center; margin-top:24px; }
</style>
</head>
<body>
<div class="container">
  <h1>系统满负载压力测试报告</h1>
  <div class="subtitle">@CPU_MODEL@ &nbsp;|&nbsp; SN: @SN@ &nbsp;|&nbsp; @OS_VER@ &nbsp;|&nbsp; 生成时间: @GEN@</div>

  <div class="meta-grid">
    <div class="meta-card"><h3>设备序列号 (SN)</h3><div class="val">@SN@</div></div>
    <div class="meta-card"><h3>测试开始</h3><div class="val">@START@</div></div>
    <div class="meta-card"><h3>测试结束</h3><div class="val">@END@</div></div>
    <div class="meta-card"><h3>采样点数</h3><div class="val">@COUNT@ 条</div><div style="font-size:12px;color:#6b7280;margin-top:4px">@STEADY_HINT@</div></div>
    <div class="meta-card"><h3>计划压测时长</h3><div class="val">@PLAN_DUR@ 小时</div></div>
    <div class="meta-card"><h3>监控采样时长</h3><div class="val">@DUR@ 小时</div></div>
  </div>

@NOTE_BLOCK@

  <div class="kpi-grid">
    <div class="kpi"><div class="label">CPU 平均使用率</div><div class="num">@CPU_AVG@%</div><div class="range">峰值 @CPU_MAX@%</div></div>
    <div class="kpi"><div class="label">内存平均使用率</div><div class="num">@MEM_AVG@%</div><div class="range">峰值 @MEM_MAX@%</div></div>
    <div class="kpi"><div class="label">内存已用</div><div class="num">@MEMGB_AVG@ GB</div><div class="range">峰值 @MEMGB_MAX@ GB</div></div>
    <div class="kpi"><div class="label">平均 CPU 频率</div><div class="num">@FREQ_AVG@ MHz</div><div class="range">峰值 @FREQ_MAX@ MHz</div></div>
    <div class="kpi"><div class="label">负载均值 1m</div><div class="num">@LOAD1_AVG@</div><div class="range">峰值 @LOAD1_MAX@</div></div>
    <div class="kpi"><div class="label">CPU 温度</div><div class="num">@TEMP_AVG@&deg;C</div><div class="range">峰值 @TEMP_MAX@&deg;C</div></div>
@EDAC_KPI@  </div>

  <div class="chart-card"><h2>CPU 使用率 (%)</h2><div class="chart-wrap"><canvas id="cpuChart"></canvas></div></div>
  <div class="chart-card"><h2>内存使用率 (%)</h2><div class="chart-wrap"><canvas id="memChart"></canvas></div></div>
  <div class="chart-card"><h2>CPU 温度 (&deg;C)</h2><div class="chart-wrap"><canvas id="tempChart"></canvas></div></div>
  <div class="chart-card"><h2>系统负载 (1/5/15 分钟)</h2><div class="chart-wrap"><canvas id="loadChart"></canvas></div></div>
  <div class="chart-card"><h2>CPU 频率 (MHz)</h2><div class="chart-wrap"><canvas id="freqChart"></canvas></div></div>
  <div class="chart-card"><h2>上下文切换 (次/秒)</h2><div class="chart-wrap"><canvas id="csChart"></canvas></div></div>
@EDAC_CHART_BLOCK@

  <div class="table-card">
    <h2>关键指标汇总</h2>
    <table>
      <thead><tr><th>指标</th><th>最小值</th><th>平均值</th><th>最大值</th></tr></thead>
      <tbody>
        <tr><td>CPU 使用率 (%)</td><td>@CPU_MIN@</td><td>@CPU_AVG@</td><td>@CPU_MAX@</td></tr>
        <tr><td>内存使用率 (%)</td><td>@MEM_MIN@</td><td>@MEM_AVG@</td><td>@MEM_MAX@</td></tr>
        <tr><td>内存已用 (GB)</td><td>@MEMGB_MIN@</td><td>@MEMGB_AVG@</td><td>@MEMGB_MAX@</td></tr>
        <tr><td>CPU 频率 (MHz)</td><td>@FREQ_MIN@</td><td>@FREQ_AVG@</td><td>@FREQ_MAX@</td></tr>
        <tr><td>负载 1 分钟</td><td>@LOAD1_MIN@</td><td>@LOAD1_AVG@</td><td>@LOAD1_MAX@</td></tr>
        <tr><td>负载 5 分钟</td><td>@LOAD5_MIN@</td><td>@LOAD5_AVG@</td><td>@LOAD5_MAX@</td></tr>
        <tr><td>负载 15 分钟</td><td>@LOAD15_MIN@</td><td>@LOAD15_AVG@</td><td>@LOAD15_MAX@</td></tr>
        <tr><td>CPU 温度 (&deg;C)</td><td>@TEMP_MIN@</td><td>@TEMP_AVG@</td><td>@TEMP_MAX@</td></tr>
        <tr><td>上下文切换 (次/秒)</td><td>@CS_MIN@</td><td>@CS_AVG@</td><td>@CS_MAX@</td></tr>
        <tr><td>功耗 (W)</td><td>@PWR_MIN@</td><td>@PWR_AVG@</td><td>@PWR_MAX@</td></tr>
@EDAC_SUMMARY_ROWS@      </tbody>
    </table>
  </div>

  <div class="table-card">
    <h2>稳定性判定</h2>
    <table>
      <thead><tr><th>检查项</th><th>结果</th><th>说明</th></tr></thead>
      <tbody>
        <tr><td>CPU 持续满载</td><td>@VERDICT_CPU@</td><td>平均 @CPU_AVG@%, 目标 &gt;= 90%（统计 @STEADY_TXT@）</td></tr>
        <tr><td>内存满载</td><td>@VERDICT_MEM@</td><td>平均 @MEM_AVG@%, 目标 &gt;= 90%（统计 @STEADY_TXT@）</td></tr>
        <tr><td>温度安全</td><td>@VERDICT_TEMP@</td><td>峰值 @TEMP_MAX@&deg;C, 通用 TjMax 安全线建议 &lt;= 95&deg;C</td></tr>
        <tr><td>无降频</td><td>@VERDICT_FREQ@</td><td>@FREQ_DETAIL@</td></tr>
        <tr><td>系统未崩溃</td><td>@VERDICT_RUN@</td><td>计划压测 @PLAN_DUR@ 小时, 实际采样 @DUR@ 小时, 采样 @COUNT@ 条, 压测退出码 @RC@</td></tr>
        <tr><td>内存无 UE（不可纠正 ECC）</td><td>@VERDICT_UE@</td><td>@UE_DETAIL@</td></tr>
        <tr><td>内存无 CE（可纠正 ECC）</td><td>@VERDICT_CE@</td><td>@CE_DETAIL@</td></tr>
      </tbody>
    </table>
  </div>
@STRESS_BLOCK@
@EDAC_LOC_BLOCK@

  <footer>数据源: @CSV@ &nbsp;|&nbsp; 由 stress-ng + monitor.sh 自动采集生成</footer>
</div>

<script>
const commonOpts = {
  responsive: true,
  maintainAspectRatio: false,
  plugins: { legend: { position: 'bottom' } },
  scales: {
    x: { ticks: { maxTicksLimit: 12, maxRotation: 45 } },
    y: { beginAtZero: true }
  }
};
function makeChart(id, cfg) {
  const el = document.getElementById(id);
  if (el) new Chart(el, cfg);
}
makeChart('cpuChart',  { type: 'line', data: @CPU_JSON@,  options: { ...commonOpts, scales: { x: commonOpts.scales.x, y: { beginAtZero: true, suggestedMax: 100 } } } });
makeChart('memChart',  { type: 'line', data: @MEM_JSON@,  options: { ...commonOpts, scales: { x: commonOpts.scales.x, y: { beginAtZero: true, suggestedMax: 100 } } } });
makeChart('tempChart', { type: 'line', data: @TEMP_JSON@, options: commonOpts });
makeChart('loadChart', { type: 'line', data: @LOAD_JSON@, options: commonOpts });
makeChart('freqChart', { type: 'line', data: @FREQ_JSON@, options: commonOpts });
makeChart('csChart',   { type: 'line', data: @CS_JSON@,   options: commonOpts });
makeChart('edacChart', { type: 'line', data: @EDAC_JSON@, options: { ...commonOpts, scales: { x: commonOpts.scales.x, y: { beginAtZero: true, ticks: { precision: 0 } } } } });
</script>
</body>
</html>
"""


def _parse_from_stress_log(csv_path, keyword):
    """从 CSV 同目录的 stress_*.log 中解析服务器信息 (本机/离线生成报告时兜底).
    日志由 stress_test.sh 记录, 形如: [时间]   CPU 型号: AMD EPYC 7763 ..."""
    if not csv_path:
        return None
    log_dir = os.path.dirname(os.path.abspath(csv_path))
    try:
        for fn in sorted(os.listdir(log_dir)):
            if fn.startswith("stress_") and fn.endswith(".log"):
                with open(os.path.join(log_dir, fn), "r",
                          encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        if keyword + ":" in line:
                            # 精确定位关键字位置, 避免行首时间戳(含冒号)干扰
                            idx = line.find(keyword + ":")
                            val = line[idx + len(keyword) + 1:].strip()
                            if val:
                                return val
    except Exception:
        pass
    return None


def get_cpu_model(csv_path=None):
    """动态读取 CPU 型号; 本机无 /proc 时回退解析压测日志."""
    try:
        with open("/proc/cpuinfo", "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except Exception:
        pass
    val = _parse_from_stress_log(csv_path, "CPU 型号")
    return val if val else "未知 CPU"


def get_cpu_base_freq():
    """动态读取 CPU 基础频率 (MHz), 优先 sysfs, 退回 lscpu."""
    try:
        for f in ("/sys/devices/system/cpu/cpu0/cpufreq/base_frequency",
                  "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq"):
            try:
                with open(f, "r") as fh:
                    v = int(fh.read().strip())
                    if v > 0:
                        return v // 1000
            except Exception:
                continue
    except Exception:
        pass
    try:
        out = os.popen("lscpu 2>/dev/null | grep -i 'CPU MHz'").read()
        m = re.search(r"([0-9.]+)", out)
        if m:
            return int(float(m.group(1)))
    except Exception:
        pass
    return None


def get_os_version(csv_path=None):
    """动态读取 OS 版本; 本机无 /etc 时回退解析压测日志."""
    try:
        with open("/etc/redhat-release", "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip()
    except Exception:
        pass
    try:
        with open("/etc/os-release", "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    val = _parse_from_stress_log(csv_path, "系统")
    return val if val else "未知 OS"


def get_serial_number(csv_path=None):
    """动态读取设备序列号(SN); 本机无 dmidecode/SMBIOS 时回退解析压测日志."""
    invalid = ("Not Specified", "None", "Unknown", "To Be Filled By O.E.M.",
               "System Serial Number", "Base Board Serial Number",
               "Chassis Serial Number")
    for key in ("system-serial-number", "baseboard-serial-number", "chassis-serial-number"):
        try:
            out = os.popen("dmidecode -s %s 2>/dev/null" % key).read().strip()
            if out and out not in invalid:
                return out
        except Exception:
            continue
    val = _parse_from_stress_log(csv_path, "设备序列号")
    return val if val else "N/A"


def render_html(rows, csv_path, plan_duration=None, stress_rc=None, metadata=None, note=None,
                steady=True, stress_log=None, base_freq_override=None):
    n = len(rows)

    # 稳态窗口 (v2.6): 默认剔除首尾非满载过渡样本后再做统计, 避免稀疏采样下平均值失真。
    # 图表仍画完整窗口 (能看到升载/降载过程), 但 min/avg/max 与判定都基于稳态行。
    if steady:
        steady_rows, cut_head, cut_tail = trim_transient(rows)
    else:
        steady_rows, cut_head, cut_tail = rows, 0, 0

    # 计划时长优先级: 命令行 --duration(秒) > CSV 元数据 plan_duration_hours > N/A
    if plan_duration is None and metadata:
        ph = metadata.get("plan_duration_hours")
        if ph:
            try:
                plan_duration = float(ph) * 3600.0
            except ValueError:
                plan_duration = None

    # 时长优先用首末时间戳差值计算, 更精确; 兜底按 10s 间隔估算
    try:
        ts_first = to_num(rows[0].get("timestamp"))
        ts_last = to_num(rows[-1].get("timestamp"))
        if ts_first and ts_last and ts_last > ts_first:
            duration_h = (ts_last - ts_first) / 3600.0
        else:
            duration_h = n * 10 / 3600.0
    except Exception:
        duration_h = n * 10 / 3600.0

    def s(key):
        return stats(steady_rows, key)

    cpu = s("cpu_usage_pct")
    mem = s("mem_usage_pct")
    mem_gb = s("mem_used_gb")
    freq = s("cpu_freq_mhz")
    load1 = s("load_1m")
    load5 = s("load_5m")
    load15 = s("load_15m")
    temp = s("cpu_temp_c")
    power = s("power_w")
    cs = s("context_switches")

    start_dt = rows[0].get("datetime", "")
    end_dt = rows[-1].get("datetime", "")

    # 图表采样 (最多 400 点, 避免标签过密)
    step = max(1, n // 400)
    sampled = rows[::step]

    colors = ["#2563eb", "#059669", "#d97706", "#dc2626", "#7c3aed", "#0891b2"]
    cpu_chart = build_chart_data(sampled, ["cpu_usage_pct"], colors)
    mem_chart = build_chart_data(sampled, ["mem_usage_pct"], colors)
    temp_chart = build_chart_data(sampled, ["cpu_temp_c"], colors)
    load_chart = build_chart_data(sampled, ["load_1m", "load_5m", "load_15m"], colors)
    freq_chart = build_chart_data(sampled, ["cpu_freq_mhz"], colors)
    cs_chart = build_chart_data(sampled, ["context_switches"], colors)

    def verdict(cond, ok_text, bad_text):
        return ('<span class="badge ok">%s</span>' % ok_text) if cond else ('<span class="badge warn">%s</span>' % bad_text)

    # 满载判定用平均值 (avg), 验收标准 CPU/内存均 >= 90%; 温度/频率安全判定用峰值 (max)
    verdict_cpu = verdict(cpu[1] is not None and cpu[1] >= 90, "通过", "未达标")
    verdict_mem = verdict(mem[1] is not None and mem[1] >= 90, "通过", "未达标")
    verdict_temp = verdict(temp[2] is not None and temp[2] <= 95, "安全", "超温")

    # 降频判定: 基准 = 系统读取的基础频率。
    # 离线生成报告 (没有 /proc、lscpu) 时读不到基准, 此时不再用 1500MHz 兜底硬判,
    # 而是明确标 "无法判定" 并提示用 --base-freq 指定 —— 拿错误的基准判"正常"是假阳性。
    base_freq = base_freq_override or get_cpu_base_freq()
    if base_freq is None:
        verdict_freq = '<span class="badge warn">无法判定</span>'
        freq_detail = ("峰值 %s MHz；基础频率未读取（离线生成报告时用 --base-freq 指定，"
                       "如 EPYC 7763 = 2450）" % fmt(freq[2], 0))
    else:
        verdict_freq = verdict(freq[2] is not None and freq[2] >= base_freq * 0.9,
                               "正常", "疑似降频")
        freq_detail = ("峰值 %s MHz / 平均 %s MHz，基础频率 %d MHz（阈值 = 90%% ≈ %d MHz）"
                       % (fmt(freq[2], 0), fmt(freq[1], 0), base_freq, int(base_freq * 0.9)))

    # 系统未崩溃判定: 按压测退出码与计划时长判断 (压测过程中未崩溃即为通过)
    # 1) 有压测退出码时: 0 = 正常结束(--timeout 到期, 未崩溃); 非 0 = 中途异常/被杀
    # 2) 无退出码时: 按实际采样时长 vs 计划时长(采样=压测*1.1) 判断是否完整跑满
    # 3) 完全无参考时: 不写死阈值, 视为通过
    if stress_rc is not None:
        if stress_rc == 0:
            verdict_run = '<span class="badge ok">通过</span>'
        else:
            verdict_run = '<span class="badge warn">压测异常退出(码 %d)</span>' % stress_rc
    elif plan_duration is not None and plan_duration > 0:
        expected_s = plan_duration * 1.1 * 0.9
        if duration_h * 3600 >= expected_s:
            verdict_run = '<span class="badge ok">通过</span>'
        else:
            verdict_run = '<span class="badge warn">仅 %.1f 小时</span>' % duration_h
    else:
        verdict_run = '<span class="badge ok">通过</span>'

    # ===== 内存 ECC (EDAC) 判定 =====
    # "压测跑满 24h" 只证明系统没挂, 不证明内存没出错。若 CE 持续增长而报告仍判定
    # "通过", 就会把正在劣化的内存条判成好件 —— v2.4 起把 ECC 计数纳入验收。
    #   UE (Uncorrectable) 不可纠正: 破坏数据完整性, 出现即判失败
    #   CE (Correctable)   可纠正:   单条内可纠, 但持续新增即为劣化信号, 判告警
    ce_stat = s("edac_ce_total")
    ue_stat = s("edac_ue_total")
    ce_delta_stat = s("edac_ce_delta")
    ue_delta_stat = s("edac_ue_delta")
    edac_collected = any(to_num(r.get("edac_ce_total")) is not None for r in rows)

    def _first_last(key):
        vals = [to_num(r.get(key)) for r in rows]
        vals = [v for v in vals if v is not None]
        return (vals[0], vals[-1]) if vals else (None, None)

    ce_first, ce_last = _first_last("edac_ce_total")
    ue_first, ue_last = _first_last("edac_ue_total")
    ce_inc = (ce_last - ce_first) if (ce_first is not None and ce_last is not None) else None
    ue_inc = (ue_last - ue_first) if (ue_first is not None and ue_last is not None) else None
    ce_per_h = (ce_inc / duration_h) if (ce_inc is not None and duration_h > 0) else None
    ue_per_h = (ue_inc / duration_h) if (ue_inc is not None and duration_h > 0) else None

    # 受影响位置: 取最后一条非空摘要 (形如 mc0/dimm3:1204;mc1/dimm5:16)
    edac_loc = None
    for r in reversed(rows):
        v = (r.get("edac_loc") or "").strip()
        if v and v not in ("-", "N/A"):
            edac_loc = v
            break

    def _int(v):
        return int(round(v)) if v is not None else None

    if not edac_collected:
        verdict_ue = '<span class="badge warn">未采集</span>'
        verdict_ce = '<span class="badge warn">未采集</span>'
        if (metadata or {}).get("edac_available") == "0":
            ce_detail = ("EDAC 不可用（驱动模块未加载或平台不支持），本次未采集 ECC 计数。"
                         "启用后可重跑：modprobe edac_mce_amd / skx_edac，并安装 rasdaemon")
        else:
            ce_detail = "该 CSV 无 EDAC 字段（旧版 monitor.sh 生成），无法判定内存 ECC 状态"
        ue_detail = ce_detail
    else:
        # UE: 绝对计数 >0 即判失败。
        # UE 计数器自开机累计, 压测窗口内读到 >0 说明本机已发生不可纠正错误;
        # 即便本次窗口内无新增 (历史遗留), 数据完整性风险依然存在, 不能判通过。
        if ue_last is not None and ue_last > 0:
            verdict_ue = '<span class="badge bad">%d 次</span>' % _int(ue_last)
            if ue_inc is not None and ue_inc > 0:
                ue_detail = ("累计 %d 次，本次新增 %d 次（约 %.2f 次/小时）。UE 已破坏数据完整性，"
                             "须立即定位并更换对应内存条/通道部件"
                             % (_int(ue_last), _int(ue_inc),
                                ue_per_h if ue_per_h is not None else 0.0))
            else:
                ue_detail = ("累计 %d 次，本次压测无新增（历史遗留）。UE 属不可纠正错误，"
                             "即使本次未复现，数据完整性风险仍在，建议优先排查并更换" % _int(ue_last))
        else:
            verdict_ue = '<span class="badge ok">0 次</span>'
            ue_detail = "全程 0 次（目标 = 0）"

        # CE: 以"本次新增"为判定依据 (历史累计 CE 可以是几个月前遗留, 不代表本次劣化)
        if ce_inc is not None and ce_inc > 0:
            verdict_ce = '<span class="badge warn">+%d 次</span>' % _int(ce_inc)
            ce_detail = ("累计 %d → %d，新增 %d 次（约 %.2f 次/小时）。CE 只增不减说明存在"
                         "持续劣化的内存条或通道，建议按下方 EDAC 定位结果做单条替换验证"
                         % (_int(ce_first), _int(ce_last), _int(ce_inc),
                            ce_per_h if ce_per_h is not None else 0.0))
        else:
            verdict_ce = '<span class="badge ok">0 次</span>'
            if ce_last is not None and ce_last > 0:
                ce_detail = ("本次无新增（累计 %d 次为历史遗留，建议确认已做过更换/隔离）"
                             % _int(ce_last))
            else:
                ce_detail = "全程 0 次，目标 = 0"

    # KPI / 图表 / 汇总行 / 定位卡片: 未采集时整体置空, 不污染既有版式
    if edac_collected:
        if ce_inc is None:
            kpi_inc = "N/A"
        else:
            kpi_inc = ("+%d" % _int(ce_inc)) if ce_inc > 0 else "0"
        edac_kpi = (
            '    <div class="kpi"><div class="label">内存 CE / UE 累计</div>'
            '<div class="num">%s / %s</div><div class="range">新增 CE %s 次</div></div>\n'
        ) % (fmt(ce_last, 0), fmt(ue_last, 0), kpi_inc)

        edac_chart_block = (
            '  <div class="chart-card"><h2>内存 ECC 错误累计 (EDAC)</h2>'
            '<div class="chart-wrap"><canvas id="edacChart"></canvas></div></div>\n'
        )
        edac_chart = build_chart_data(
            sampled, ["edac_ce_total", "edac_ue_total"],
            ["#d97706", "#dc2626"], ["CE 累计（可纠正）", "UE 累计（不可纠正）"])

        edac_summary_rows = (
            '        <tr><td>内存 CE 累计 (次)</td><td>%s</td><td>%s</td><td>%s</td></tr>\n'
            '        <tr><td>内存 UE 累计 (次)</td><td>%s</td><td>%s</td><td>%s</td></tr>\n'
            '        <tr><td>新增 CE (次/采样)</td><td>%s</td><td>%s</td><td>%s</td></tr>\n'
            '        <tr><td>新增 UE (次/采样)</td><td>%s</td><td>%s</td><td>%s</td></tr>\n'
        ) % (fmt(ce_stat[0], 0), fmt(ce_stat[1], 0), fmt(ce_stat[2], 0),
             fmt(ue_stat[0], 0), fmt(ue_stat[1], 0), fmt(ue_stat[2], 0),
             fmt(ce_delta_stat[0], 0), fmt(ce_delta_stat[1], 1), fmt(ce_delta_stat[2], 0),
             fmt(ue_delta_stat[0], 0), fmt(ue_delta_stat[1], 1), fmt(ue_delta_stat[2], 0))
    else:
        edac_kpi = ""
        edac_chart_block = ""
        edac_chart = {"labels": [], "datasets": []}
        edac_summary_rows = ""

    if edac_collected and edac_loc:
        loc_items = "".join(
            '<div style="padding:2px 0">%s</div>' % esc(x.strip())
            for x in edac_loc.split(";") if x.strip()
        )
        tip = ("格式为 控制器/DIMM:错误数（.ue 结尾表示该位置的不可纠正错误）。"
               "CE 集中在单个 DIMM → 优先怀疑该条内存；分散在同一控制器多个 DIMM → "
               "优先怀疑该侧 CPU 的通道/插槽。")
        if ce_inc is not None and ce_inc > 0:
            tip += " 本次压测新增 %d 次 CE，建议据定位结果先做单条替换复测。" % _int(ce_inc)
        edac_loc_block = (
            '  <div class="table-card">\n'
            '    <h2>ECC 错误定位（EDAC）</h2>\n'
            '    <div style="font-size:13px;line-height:1.9;font-family:ui-monospace,Consolas,monospace">%s</div>\n'
            '    <div style="color:#6b7280;font-size:12px;margin-top:10px;line-height:1.7">%s</div>\n'
            '  </div>\n' % (loc_items, esc(tip))
        )
    else:
        edac_loc_block = ""

    # 压测引擎执行结果 (--stress-log 可选): 把 bogo ops / passed / failed 作为证据链补进报告
    stress_info = parse_stress_log(stress_log)
    if stress_info:
        metric_rows = "".join(
            '        <tr><td>%s</td><td>%s</td><td>%.2f</td><td>%s</td></tr>\n'
            % (esc(m["name"]), "{:,}".format(m["bogo"]), m["real"],
               "{:,.0f}".format(m["rate"]))
            for m in stress_info["metrics"])
        bits = []
        if stress_info["stressors"]:
            bits.append("并发 hog: <b>%s</b>" % esc(stress_info["stressors"]))
        if stress_info["passed"] is not None:
            bits.append("passed: <b>%s</b>" % esc(stress_info["passed"]))
        if stress_info["failed"] is not None:
            if stress_info["failed"] == 0:
                bits.append('failed: <span class="badge ok">0</span>')
            else:
                bits.append('failed: <span class="badge bad">%d</span>' % stress_info["failed"])
        if stress_info["skipped"] is not None:
            bits.append("skipped: %d" % stress_info["skipped"])
        if stress_info["completed"]:
            bits.append("引擎自报完成用时: %s" % esc(stress_info["completed"]))
        stress_block = (
            '  <div class="table-card">\n'
            '    <h2>压测引擎执行结果（stress-ng）</h2>\n'
            '    <div style="font-size:13px;margin-bottom:10px;line-height:1.9">%s</div>\n'
            '    <table>\n'
            '      <thead><tr><th>Stressor</th><th>bogo ops</th><th>实际用时 (s)</th><th>bogo ops/s</th></tr></thead>\n'
            '      <tbody>\n%s      </tbody>\n'
            '    </table>\n'
            '    <div style="color:#6b7280;font-size:12px;margin-top:10px;line-height:1.7">'
            'bogo ops 是 stress-ng 自定义的运算量单位，只适合同机型、同参数的横向对比，'
            '不能跨平台直接比较；批次间 bogo ops/s 明显下降通常意味着降频、内存瓶颈或 NUMA 跨节点。</div>\n'
            '  </div>\n' % (" &nbsp;|&nbsp; ".join(bits), metric_rows)
        )
    else:
        stress_block = ""

    # 采样密度提示: 满负载下 BMC (ipmitool/KCS) 响应变慢会让采样间隔显著退化,
    # 这本身是个需要注意的现场问题, 直接写在报告里而不是藏着
    steady_count = len(steady_rows)
    try:
        ts_a = to_num(rows[0].get("timestamp"))
        ts_b = to_num(rows[-1].get("timestamp"))
        avg_interval = (ts_b - ts_a) / (n - 1) if (n > 1 and ts_a and ts_b) else None
    except Exception:
        avg_interval = None
    hint_parts = []
    if cut_head or cut_tail:
        hint_parts.append("有效 %d 条（剔除首尾 %d 条空载过渡）" % (steady_count, cut_head + cut_tail))
    else:
        hint_parts.append("全部计入统计")
    if avg_interval:
        hint_parts.append("平均间隔 %ds" % round(avg_interval))
    steady_hint = " · ".join(hint_parts)
    if cut_head or cut_tail:
        steady_txt = "稳态 %d 条, 已剔除首尾 %d 条空载过渡" % (steady_count, cut_head + cut_tail)
    else:
        steady_txt = "全部 %d 条" % steady_count

    # 优先用 CSV 元数据 (离线/本机生成报告都可靠), 缺失时回退本机 /proc、/etc 或 stress 日志
    cpu_model = (metadata.get("cpu_model") if metadata else None) or get_cpu_model(csv_path)
    os_ver = (metadata.get("os_version") if metadata else None) or get_os_version(csv_path)
    serial_number = (metadata.get("serial_number") if metadata else None) or get_serial_number(csv_path)

    # 备注/结论块: 未传 --note 时渲染为空, 不影响既有报告版式
    if note:
        lines = [esc(x) for x in str(note).replace("\\n", "\n").splitlines()]
        body = "<br>".join(x for x in lines if x.strip())
        note_block = (
            '  <div class="table-card" style="border-left:4px solid #f0ad4e">\n'
            '    <h2>备注 / 结论</h2>\n'
            '    <div style="line-height:1.8;font-size:14px">%s</div>\n'
            '  </div>\n' % body
        )
    else:
        note_block = ""

    repl = {
        "@NOTE_BLOCK@": note_block,
        "@GEN@": esc(datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
        "@CPU_MODEL@": esc(cpu_model),
        "@SN@": esc(serial_number),
        "@OS_VER@": esc(os_ver),
        "@BASE_FREQ@": str(base_freq) if base_freq else "N/A",
        "@START@": esc(start_dt),
        "@END@": esc(end_dt),
        "@COUNT@": str(n),
        "@STEADY_COUNT@": str(steady_count),
        "@STEADY_TXT@": esc(steady_txt),
        "@STEADY_HINT@": esc(steady_hint),
        "@STRESS_BLOCK@": stress_block,
        "@DUR@": "%.2f" % duration_h,
        "@PLAN_DUR@": ("%.2f" % (plan_duration / 3600.0)) if plan_duration else "N/A",
        "@RC@": str(stress_rc) if stress_rc is not None else "N/A",
        "@CPU_MIN@": fmt(cpu[0]), "@CPU_AVG@": fmt(cpu[1]), "@CPU_MAX@": fmt(cpu[2]),
        "@MEM_MIN@": fmt(mem[0]), "@MEM_AVG@": fmt(mem[1]), "@MEM_MAX@": fmt(mem[2]),
        "@MEMGB_MIN@": fmt(mem_gb[0]), "@MEMGB_AVG@": fmt(mem_gb[1]), "@MEMGB_MAX@": fmt(mem_gb[2]),
        "@FREQ_MIN@": fmt(freq[0], 0), "@FREQ_AVG@": fmt(freq[1], 0), "@FREQ_MAX@": fmt(freq[2], 0),
        "@LOAD1_MIN@": fmt(load1[0], 2), "@LOAD1_AVG@": fmt(load1[1], 2), "@LOAD1_MAX@": fmt(load1[2], 2),
        "@LOAD5_MIN@": fmt(load5[0], 2), "@LOAD5_AVG@": fmt(load5[1], 2), "@LOAD5_MAX@": fmt(load5[2], 2),
        "@LOAD15_MIN@": fmt(load15[0], 2), "@LOAD15_AVG@": fmt(load15[1], 2), "@LOAD15_MAX@": fmt(load15[2], 2),
        "@TEMP_MIN@": fmt(temp[0]), "@TEMP_AVG@": fmt(temp[1]), "@TEMP_MAX@": fmt(temp[2]),
        "@CS_MIN@": fmt(cs[0], 0), "@CS_AVG@": fmt(cs[1], 0), "@CS_MAX@": fmt(cs[2], 0),
        "@PWR_MIN@": fmt(power[0]), "@PWR_AVG@": fmt(power[1]), "@PWR_MAX@": fmt(power[2]),
        "@VERDICT_CPU@": verdict_cpu, "@VERDICT_MEM@": verdict_mem,
        "@VERDICT_TEMP@": verdict_temp, "@VERDICT_FREQ@": verdict_freq,
        "@FREQ_DETAIL@": esc(freq_detail),
        "@VERDICT_RUN@": verdict_run,
        "@VERDICT_CE@": verdict_ce, "@VERDICT_UE@": verdict_ue,
        "@CE_DETAIL@": esc(ce_detail), "@UE_DETAIL@": esc(ue_detail),
        "@EDAC_KPI@": edac_kpi,
        "@EDAC_CHART_BLOCK@": edac_chart_block,
        "@EDAC_SUMMARY_ROWS@": edac_summary_rows,
        "@EDAC_LOC_BLOCK@": edac_loc_block,
        "@CSV@": esc(os.path.basename(csv_path)),
        "@CPU_JSON@": json.dumps(cpu_chart, ensure_ascii=False),
        "@MEM_JSON@": json.dumps(mem_chart, ensure_ascii=False),
        "@TEMP_JSON@": json.dumps(temp_chart, ensure_ascii=False),
        "@LOAD_JSON@": json.dumps(load_chart, ensure_ascii=False),
        "@FREQ_JSON@": json.dumps(freq_chart, ensure_ascii=False),
        "@CS_JSON@": json.dumps(cs_chart, ensure_ascii=False),
        "@EDAC_JSON@": json.dumps(edac_chart, ensure_ascii=False),
    }

    html = HTML_TEMPLATE
    for k, v in repl.items():
        html = html.replace(k, v)
    return html


def main():
    if len(sys.argv) < 3:
        sys.exit("用法: python3 generate_report.py <monitor.csv> <输出.html> "
                 "[--duration 秒] [--rc 退出码] [--note 备注结论(支持 \\n 换行)] "
                 "[--stress-log stress-ng日志] [--base-freq 基础频率MHz] [--no-steady]")
    csv_path = sys.argv[1]
    out_path = sys.argv[2]

    # 可选参数: --duration 计划压测秒数, --rc 压测退出码 (用于"系统未崩溃"验收判定)
    #           --note 备注/结论 (写入报告顶部独立卡片, 支持 \n 换行)
    #           --stress-log stress-ng 运行日志 (抽取 bogo ops / passed / failed)
    #           --no-steady 不剔除首尾空载过渡样本 (默认剔除)
    plan_duration = None
    stress_rc = None
    note = None
    stress_log = None
    steady = True
    base_freq_override = None
    i = 3
    while i < len(sys.argv):
        arg = sys.argv[i]
        if arg == "--duration" and i + 1 < len(sys.argv):
            plan_duration = to_num(sys.argv[i + 1])
            i += 2
        elif arg == "--rc" and i + 1 < len(sys.argv):
            try:
                stress_rc = int(sys.argv[i + 1])
            except ValueError:
                stress_rc = None
            i += 2
        elif arg == "--note" and i + 1 < len(sys.argv):
            note = sys.argv[i + 1]
            i += 2
        elif arg == "--stress-log" and i + 1 < len(sys.argv):
            stress_log = sys.argv[i + 1]
            i += 2
        elif arg == "--base-freq" and i + 1 < len(sys.argv):
            base_freq_override = to_num(sys.argv[i + 1])
            i += 2
        elif arg == "--no-steady":
            steady = False
            i += 1
        else:
            i += 1

    metadata, rows = parse_csv(csv_path)
    html = render_html(rows, csv_path, plan_duration, stress_rc, metadata, note,
                       steady=steady, stress_log=stress_log,
                       base_freq_override=base_freq_override)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)
    print("[OK] 报告已生成: %s (共 %d 个采样点)" % (out_path, len(rows)))


if __name__ == "__main__":
    main()
