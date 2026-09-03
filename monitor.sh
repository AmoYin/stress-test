#!/bin/bash
#=============================================================================
# monitor.sh — 压测期间系统资源监控
# 每 10 秒采集一次: CPU使用率/内存/系统负载/温度/功耗/上下文切换
# 输出 CSV 文件供 generate_report.py 生成报告
# 适用: 任意 x86_64 服务器 / RHEL 8.x (所有指标动态读取, 不写死硬件参数)
#=============================================================================

set -euo pipefail

#------------------------------- 配置区 ---------------------------------------
INTERVAL=${1:-10}                  # 采样间隔 (秒), 默认 10
LOG_DIR="/var/log/stress_test"
mkdir -p "$LOG_DIR"
CSV_FILE="${LOG_DIR}/monitor_$(date +%Y%m%d_%H%M%S).csv"

#------------------------------- 函数区 ---------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# 获取 CPU 使用率 (总体)
get_cpu_usage() {
    local idle=$(top -bn1 | grep "^%Cpu" | awk -F',' '{print $4}' | grep -oP '[0-9.]+')
    if [ -z "$idle" ]; then
        idle=$(top -bn1 | grep "^%Cpu" | awk '{print $8}' | grep -oP '[0-9.]+')
    fi
    if [ -z "$idle" ]; then
        echo "0.0"
        return
    fi
    awk "BEGIN {printf \"%.1f\", 100 - ${idle}}"
}

# 获取内存使用
get_mem_info() {
    local total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    local used_kb=$((total_kb - avail_kb))
    local used_pct=$(awk "BEGIN {printf \"%.1f\", ${used_kb} / ${total_kb} * 100}")
    echo "${used_kb}|${total_kb}|${used_pct}"
}

# 获取系统负载
get_loadavg() {
    cat /proc/loadavg | awk '{printf "%.2f,%.2f,%.2f", $1, $2, $3}'
}

# 获取 CPU 温度
get_cpu_temp() {
    if command -v sensors &>/dev/null; then
        local temp=$(sensors 2>/dev/null | grep -iE "Tdie|Tctl|Package|Core" | head -1 | grep -oP '\+[0-9.]+' | head -1 | tr -d '+')
        if [ -n "$temp" ]; then
            echo "$temp"
            return
        fi
    fi
    for tz in /sys/class/thermal/thermal_zone*/temp; do
        if [ -r "$tz" ]; then
            local t=$(cat "$tz" 2>/dev/null)
            if [ -n "$t" ]; then
                awk "BEGIN {printf \"%.1f\", ${t} / 1000}"
                return
            fi
        fi
    done
    if command -v ipmitool &>/dev/null; then
        local temp=$(ipmitool sensor 2>/dev/null | grep -iE "CPU.*Temp|Temp.*CPU" | head -1 | awk -F'|' '{print $2}' | grep -oP '[0-9.]+')
        if [ -n "$temp" ]; then
            echo "$temp"
            return
        fi
    fi
    echo "N/A"
}

# 获取 CPU 功耗
get_power() {
    if command -v ipmitool &>/dev/null; then
        local pwr=$(ipmitool sensor 2>/dev/null | grep -iE "Power|Pwr" | grep -i "Watt\|W" | head -1 | awk -F'|' '{print $2}' | grep -oP '[0-9.]+')
        if [ -n "$pwr" ]; then
            echo "$pwr"
            return
        fi
    fi
    echo "N/A"
}

# 获取 CPU 频率
get_cpu_freq() {
    local freq=$(cat /proc/cpuinfo | grep -E "^cpu MHz" | head -1 | awk '{printf "%.0f", $3}')
    if [ -z "$freq" ] || [ "$freq" = "0" ]; then
        freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
        if [ -n "$freq" ]; then
            freq=$(awk "BEGIN {printf \"%.0f\", ${freq} / 1000}")
        fi
    fi
    echo "${freq:-N/A}"
}

# 获取上下文切换
get_context_switches() {
    grep "ctxt" /proc/stat | awk '{print $2}'
}

# 获取进程数
get_process_count() {
    grep -c "^proc" /proc/stat
}

#------------------------------- CSV 初始化 ----------------------------------
init_csv() {
    log "初始化 CSV: ${CSV_FILE}"
    cat > "$CSV_FILE" << 'EOF'
timestamp,datetime,cpu_usage_pct,cpu_freq_mhz,mem_used_gb,mem_total_gb,mem_usage_pct,load_1m,load_5m,load_15m,cpu_temp_c,power_w,context_switches,processes
EOF
    log "CSV 表头已写入, 开始监控 (间隔 ${INTERVAL}s)..."
    log "按 Ctrl+C 停止监控"
}

#------------------------------- 主循环 ---------------------------------------
main() {
    init_csv
    local prev_cs=""

    while true; do
        local ts=$(date +%s)
        local dt=$(date '+%Y-%m-%d %H:%M:%S')

        local cpu_usage=$(get_cpu_usage)
        local cpu_freq=$(get_cpu_freq)

        local mem_info=$(get_mem_info)
        local mem_used_kb=$(echo "$mem_info" | cut -d'|' -f1)
        local mem_total_kb=$(echo "$mem_info" | cut -d'|' -f2)
        local mem_pct=$(echo "$mem_info" | cut -d'|' -f3)
        local mem_used_gb=$(awk "BEGIN {printf \"%.2f\", ${mem_used_kb} / 1024 / 1024}")
        local mem_total_gb=$(awk "BEGIN {printf \"%.2f\", ${mem_total_kb} / 1024 / 1024}")

        local loadavg=$(get_loadavg)
        local temp=$(get_cpu_temp)
        local power=$(get_power)
        local cs=$(get_context_switches)
        local procs=$(get_process_count)

        # 上下文切换速率
        local cs_rate="N/A"
        if [ -n "$prev_cs" ] && [ -n "$cs" ]; then
            cs_rate=$(awk "BEGIN {printf \"%.0f\", (${cs} - ${prev_cs}) / ${INTERVAL}}")
        fi
        prev_cs="$cs"

        # 写入 CSV
        echo "${ts},${dt},${cpu_usage},${cpu_freq},${mem_used_gb},${mem_total_gb},${mem_pct},${loadavg},${temp},${power},${cs_rate},${procs}" >> "$CSV_FILE"

        # 实时输出到 stderr
        log "CPU: ${cpu_usage}% | MEM: ${mem_used_gb}/${mem_total_gb} GB (${mem_pct}%) | Load: ${loadavg} | Temp: ${temp}C | Power: ${power}W | CS/s: ${cs_rate}"

        sleep "$INTERVAL"
    done
}

#------------------------------- 信号处理 -------------------------------------
trap 'log "监控已停止, CSV 文件: ${CSV_FILE}"; exit 0' SIGINT SIGTERM

#------------------------------- 入口 -----------------------------------------
main "$@"
