#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#=============================================================================
# generate_report.py — 压测数据汇总, 生成 HTML 报告
# 用法: python3 generate_report.py <monitor.csv> <输出.html>
# 依赖: 无第三方库 (纯标准库), 图表使用内嵌 Chart.js CDN
# 适用: 任意 x86_64 服务器 / RHEL 8.x (CPU 型号/频率/OS 动态读取, 不写死)
#=============================================================================

import csv
import os
import sys
import json
from datetime import datetime


def parse_csv(path):
    """读取监控 CSV, 返回数据行列表(字典)."""
    rows = []
    numeric_fields = ("cpu_usage_pct", "cpu_freq_mhz", "mem_used_gb",
                      "mem_total_gb", "mem_usage_pct", "load_1m",
                      "load_5m", "load_15m", "cpu_temp_c", "power_w",
                      "context_switches", "processes")
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
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
    return rows


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


def build_chart_data(rows, fields, colors):
    """把行数据转成 Chart.js 数据集."""
    labels = [r.get("datetime", "") for r in rows]
    datasets = []
    for field, color in zip(fields, colors):
        data = [r.get(field) if r.get(field) is not None else None for r in rows]
        datasets.append({
            "label": field,
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
  <div class="subtitle">@CPU_MODEL@ &nbsp;|&nbsp; @OS_VER@ &nbsp;|&nbsp; 生成时间: @GEN@</div>

  <div class="meta-grid">
    <div class="meta-card"><h3>测试开始</h3><div class="val">@START@</div></div>
    <div class="meta-card"><h3>测试结束</h3><div class="val">@END@</div></div>
    <div class="meta-card"><h3>采样点数</h3><div class="val">@COUNT@ 条</div></div>
    <div class="meta-card"><h3>压测时长</h3><div class="val">@DUR@ 小时</div></div>
  </div>

  <div class="kpi-grid">
    <div class="kpi"><div class="label">CPU 平均使用率</div><div class="num">@CPU_AVG@%</div><div class="range">峰值 @CPU_MAX@%</div></div>
    <div class="kpi"><div class="label">内存平均使用率</div><div class="num">@MEM_AVG@%</div><div class="range">峰值 @MEM_MAX@%</div></div>
    <div class="kpi"><div class="label">内存已用</div><div class="num">@MEMGB_AVG@ GB</div><div class="range">峰值 @MEMGB_MAX@ GB</div></div>
    <div class="kpi"><div class="label">平均 CPU 频率</div><div class="num">@FREQ_AVG@ MHz</div><div class="range">峰值 @FREQ_MAX@ MHz</div></div>
    <div class="kpi"><div class="label">负载均值 1m</div><div class="num">@LOAD1_AVG@</div><div class="range">峰值 @LOAD1_MAX@</div></div>
    <div class="kpi"><div class="label">CPU 温度</div><div class="num">@TEMP_AVG@&deg;C</div><div class="range">峰值 @TEMP_MAX@&deg;C</div></div>
  </div>

  <div class="chart-card"><h2>CPU 使用率 (%)</h2><div class="chart-wrap"><canvas id="cpuChart"></canvas></div></div>
  <div class="chart-card"><h2>内存使用率 (%)</h2><div class="chart-wrap"><canvas id="memChart"></canvas></div></div>
  <div class="chart-card"><h2>CPU 温度 (&deg;C)</h2><div class="chart-wrap"><canvas id="tempChart"></canvas></div></div>
  <div class="chart-card"><h2>系统负载 (1/5/15 分钟)</h2><div class="chart-wrap"><canvas id="loadChart"></canvas></div></div>
  <div class="chart-card"><h2>CPU 频率 (MHz)</h2><div class="chart-wrap"><canvas id="freqChart"></canvas></div></div>
  <div class="chart-card"><h2>上下文切换 (次/秒)</h2><div class="chart-wrap"><canvas id="csChart"></canvas></div></div>

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
      </tbody>
    </table>
  </div>

  <div class="table-card">
    <h2>稳定性判定</h2>
    <table>
      <thead><tr><th>检查项</th><th>结果</th><th>说明</th></tr></thead>
      <tbody>
        <tr><td>CPU 持续满载</td><td>@VERDICT_CPU@</td><td>平均 @CPU_AVG@%, 目标 >= 95%</td></tr>
        <tr><td>内存满载</td><td>@VERDICT_MEM@</td><td>平均 @MEM_AVG@%, 目标 >= 90%</td></tr>
        <tr><td>温度安全</td><td>@VERDICT_TEMP@</td><td>峰值 @TEMP_MAX@&deg;C, 通用 TjMax 安全线建议 &lt;= 95&deg;C</td></tr>
        <tr><td>无降频</td><td>@VERDICT_FREQ@</td><td>平均 @FREQ_AVG@ MHz, 基础频率 @BASE_FREQ@ MHz (动态读取)</td></tr>
        <tr><td>系统未崩溃</td><td>@VERDICT_RUN@</td><td>压测时长 @DUR@ 小时 (目标 24 小时), 采样 @COUNT@ 条</td></tr>
      </tbody>
    </table>
  </div>

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


def render_html(rows, csv_path):
    n = len(rows)
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
        return stats(rows, key)

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

    # 满载判定用平均值 (avg), 温度/频率安全判定用峰值 (max)
    verdict_cpu = verdict(cpu[1] is not None and cpu[1] >= 95, "通过", "未达标")
    verdict_mem = verdict(mem[1] is not None and mem[1] >= 90, "通过", "未达标")
    verdict_temp = verdict(temp[2] is not None and temp[2] <= 95, "安全", "超温")

    # 降频判定: 动态基准 = 系统读取的基础频率 (读不到时退回 1.5GHz 兜底)
    # 用峰值频率接近基准来判断是否存在降频
    base_freq = get_cpu_base_freq()
    if base_freq is None:
        base_freq = 1500
    verdict_freq = verdict(freq[2] is not None and freq[2] >= base_freq * 0.9,
                           "正常", "疑似降频")

    # 运行完整性: 按实际压测时长判断 (>=23h 视为跑满 24h 周期)
    if duration_h >= 23:
        verdict_run = '<span class="badge ok">通过</span>'
    else:
        verdict_run = '<span class="badge warn">仅 %.1f 小时</span>' % duration_h

    cpu_model = get_cpu_model(csv_path)
    os_ver = get_os_version(csv_path)

    repl = {
        "@GEN@": esc(datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
        "@CPU_MODEL@": esc(cpu_model),
        "@OS_VER@": esc(os_ver),
        "@BASE_FREQ@": str(base_freq),
        "@START@": esc(start_dt),
        "@END@": esc(end_dt),
        "@COUNT@": str(n),
        "@DUR@": "%.2f" % duration_h,
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
        "@VERDICT_RUN@": verdict_run,
        "@CSV@": esc(os.path.basename(csv_path)),
        "@CPU_JSON@": json.dumps(cpu_chart, ensure_ascii=False),
        "@MEM_JSON@": json.dumps(mem_chart, ensure_ascii=False),
        "@TEMP_JSON@": json.dumps(temp_chart, ensure_ascii=False),
        "@LOAD_JSON@": json.dumps(load_chart, ensure_ascii=False),
        "@FREQ_JSON@": json.dumps(freq_chart, ensure_ascii=False),
        "@CS_JSON@": json.dumps(cs_chart, ensure_ascii=False),
    }

    html = HTML_TEMPLATE
    for k, v in repl.items():
        html = html.replace(k, v)
    return html


def main():
    if len(sys.argv) < 3:
        sys.exit("用法: python3 generate_report.py <monitor.csv> <输出.html>")
    csv_path = sys.argv[1]
    out_path = sys.argv[2]
    rows = parse_csv(csv_path)
    html = render_html(rows, csv_path)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)
    print("[OK] 报告已生成: %s (共 %d 个采样点)" % (out_path, len(rows)))


if __name__ == "__main__":
    main()
