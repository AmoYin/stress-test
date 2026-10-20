#!/bin/bash
#=============================================================================
# monitor.sh — 压测期间系统资源监控
# 每 10 秒采集一次: CPU使用率/内存/系统负载/温度/功耗/上下文切换/内存ECC计数
# 输出 CSV 文件供 generate_report.py 生成报告
# 适用: 任意 x86_64 服务器 / RHEL 8.x (所有指标动态读取, 不写死硬件参数)
#
# v2.4 (2026-10-20) 新增内存 ECC (EDAC) 采集
#   动机: "压测跑满 24h" 不等于 "内存无错"。只有 CPU/内存利用率无法发现持续发生的
#         ECC 可纠正错误 (CE), 一份判定"通过"的报告可能掩盖了正在劣化的内存条。
#   采集: /sys/devices/system/edac/mc/mc*/{ce_count,ue_count}
#         以及 dimm*/dimm_ce_count、csrow*/ce_count (细粒度定位到具体 DIMM/通道)
#   CE = Correctable Error   可纠正, 单条/多次发生即为劣化信号
#   UE = Uncorrectable Error 不可纠正, 必然影响数据完整性, 出现即判失败
#   EDAC 不可用时降级为 N/A, 不影响其余指标采集
#
# v2.6 (2026-10-20) 修复采样间隔退化 (10s -> 139s)
#   现场: R4950 G5 满载 1 小时只有 27 个采样点, 间隔 10s 退化为平均 139s。
#   根因: get_power() 用 `ipmitool sensor` 拉全量传感器表 (双路机器数百项),
#         满载下 BMC 的 KCS 接口响应从 ~1s 退化到 1~2 分钟, 整个循环被一条命令拖住。
#   修复: ① 功耗优先走 `ipmitool dcmi power reading` (单次请求, 毫秒级);
#         ② 每条采集命令加硬超时 (_tmo), 任何一条挂死都不再阻塞整轮;
#         ③ 采集方法首次成功后缓存到 $LOG_DIR/.power_method, 失败即降级 N/A 不再重试;
#         ④ 顺带修复 cs_rate 用固定 INTERVAL 做除数的错误 (间隔变长时虚高 14 倍),
#            改为按相邻两个采样点的真实时间差计算;
#         ⑤ 每轮记录采集耗时, 超过采样间隔时告警, 现场一眼能看出是哪个环节慢。
#=============================================================================

set -euo pipefail

#------------------------------- 配置区 ---------------------------------------
INTERVAL=${1:-10}                  # 采样间隔 (秒), 默认 10
DURATION_HOURS=${2:-}              # 计划压测时长(小时), 可选, 写入 CSV 元数据供报告使用
LOG_DIR="${LOG_DIR:-/var/log/stress_test}"   # 可覆盖: 非 root 自测时指向临时目录
mkdir -p "$LOG_DIR"
CSV_FILE="${LOG_DIR}/monitor_$(date +%Y%m%d_%H%M%S).csv"

# 单条采集命令的硬超时 (秒)。满负载下 BMC/传感器命令可能挂死数分钟,
# 没有超时会拖垮整个采样循环 —— 这是 v2.4 采样间隔退化的直接原因。
CMD_TIMEOUT=${CMD_TIMEOUT:-10}
# 功耗采集方式: auto(先 DCMI 后 sensor) | dcmi | sensor | none
POWER_METHOD=${POWER_METHOD:-auto}
# 采集耗时告警阈值 (毫秒): 超过则每轮都提示, 便于发现新的慢环节
SLOW_WARN_MS=${SLOW_WARN_MS:-5000}

# EDAC sysfs 根目录: 可覆盖, 便于用伪造目录做单元测试
EDAC_ROOT="${EDAC_ROOT:-/sys/devices/system/edac/mc}"

#------------------------------- 函数区 ---------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# 当前时间戳 (毫秒), 用于统计每轮采集耗时
_now_ms() {
    local ns
    ns=$(date +%s%N 2>/dev/null || true)
    case "$ns" in
        ''|*[!0-9]*) echo $(( $(date +%s) * 1000 )) ;;
        *)           echo $(( ns / 1000000 )) ;;
    esac
}

# 带硬超时的命令执行: _tmo <秒> <命令...>
# BMC (ipmitool)、sensors 这类硬件采集在满负载下会长时间无响应,
# 必须给每条命令兜一个上限, 否则一条命令就能吃掉整个采样周期。
_tmo() {
    local secs="$1"; shift
    # shell 函数无法交给 timeout 执行 (timeout 只认可执行文件), 测试桩走直调分支
    if command -v timeout >/dev/null 2>&1 && ! declare -F "$1" >/dev/null 2>&1; then
        # -s KILL: 到点直接杀。默认 TERM 对挂死在 BMC 等待上的进程不一定生效,
        # 残留进程会继续持有 stdout, 让命令替换一直等下去, 超时等于没设。
        local rc=0
        timeout -s KILL "$secs" "$@" || rc=$?
        # timeout -s KILL 超时返回 137, 默认信号返回 124, 统一成 124 供上层判断
        if [ "$rc" -eq 137 ] || [ "$rc" -eq 124 ]; then
            return 124
        fi
        return "$rc"
    fi
    "$@"
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
        local temp=$(_tmo "$CMD_TIMEOUT" sensors 2>/dev/null | grep -iE "Tdie|Tctl|Package|Core" | head -1 | grep -oP '\+[0-9.]+' | head -1 | tr -d '+')
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
        local temp=$(_tmo "$CMD_TIMEOUT" ipmitool -N 1 -R 1 sensor 2>/dev/null | grep -iE "CPU.*Temp|Temp.*CPU" | head -1 | awk -F'|' '{print $2}' | grep -oP '[0-9.]+')
        if [ -n "$temp" ]; then
            echo "$temp"
            return
        fi
    fi
    echo "N/A"
}

#------------------------------- 功耗采集 (v2.5 重写) -------------------------
# 采集方式缓存: get_power 在 $(...) 子 shell 里执行, 变量无法回传,
# 因此把 "哪种方式可用" 落到文件里, 避免每轮都重新探测 (探测本身就是慢操作)。
_power_method_get() {
    local m
    m=$(cat "${LOG_DIR}/.power_method" 2>/dev/null || true)
    [ -n "$m" ] || m="$POWER_METHOD"
    echo "$m"
}
_power_method_set() {
    printf '%s\n' "$1" > "${LOG_DIR}/.power_method" 2>/dev/null || true
}

# 方式 A: DCMI 整机功耗 (单次 IPMI 请求, 毫秒级) —— 首选
_power_via_dcmi() {
    local out w
    out=$(_tmo "$CMD_TIMEOUT" ipmitool -N 1 -R 1 dcmi power reading 2>/dev/null) || return $?
    w=$(printf '%s\n' "$out" | grep -i 'instantaneous power' | head -1 | grep -oE '[0-9]+' | head -1)
    [ -n "$w" ] || return 1
    echo "$w"
}

# 方式 B: 全量传感器表 (数百项, 满载下可能几十秒) —— 仅在 DCMI 不可用时兜底
_power_via_sensor() {
    local out w
    out=$(_tmo "$CMD_TIMEOUT" ipmitool -N 1 -R 1 sensor 2>/dev/null) || return $?
    w=$(printf '%s\n' "$out" | grep -iE 'power|pwr' \
        | awk -F'|' 'NF>2 { gsub(/[^0-9.]/,"",$2); if ($2 ~ /^[0-9.]+$/) print $2 }' \
        | head -1)
    [ -n "$w" ] || return 1
    echo "$w"
}

# 获取整机功耗 (W)。任一方式失败即永久降级为 N/A, 不再每轮重试拖慢采样。
get_power() {
    if ! command -v ipmitool >/dev/null 2>&1; then
        echo "N/A"
        return
    fi
    local m w
    m=$(_power_method_get)
    case "$m" in
        none)
            echo "N/A" ;;
        dcmi)
            if w=$(_power_via_dcmi); then echo "$w";
            else _power_method_set none; log "[WARN] DCMI 读功耗失败, 已停用功耗采集 (CSV 记 N/A)"; echo "N/A"; fi ;;
        sensor)
            if w=$(_power_via_sensor); then echo "$w";
            else _power_method_set none; log "[WARN] ipmitool sensor 读功耗失败, 已停用功耗采集 (CSV 记 N/A)"; echo "N/A"; fi ;;
        *)
            # auto: 先试最快的 DCMI, 再退全量 sensor。
            # 若 DCMI 是"超时"(rc=124) 而不是"不支持", 说明 BMC 本身已经不响应,
            # 此时再去拉全量传感器表只会再等一个超时, 直接停用省掉这一轮的时间。
            local rc=0
            w=$(_power_via_dcmi) || rc=$?
            if [ "$rc" -eq 0 ]; then
                _power_method_set dcmi
                log "功耗采集方式: ipmitool dcmi power reading (单次请求, 毫秒级)"
                echo "$w"
                return
            fi
            if [ "$rc" -eq 124 ]; then
                _power_method_set none
                log "[WARN] BMC 在 ${CMD_TIMEOUT}s 内未响应 DCMI 查询, 已停用功耗采集 (CSV 记 N/A)"
                echo "N/A"
                return
            fi
            rc=0
            w=$(_power_via_sensor) || rc=$?
            if [ "$rc" -eq 0 ]; then
                _power_method_set sensor
                log "[WARN] DCMI 不支持, 回退 ipmitool sensor 全量读取 (较慢)"
                echo "$w"
                return
            fi
            _power_method_set none
            log "[WARN] 功耗采集不可用 (DCMI 与 sensor 均失败), CSV 记 N/A"
            echo "N/A" ;;
    esac
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

# 获取 CPU 型号 (写入 CSV 元数据, 供离线生成报告)
get_cpu_model() {
    grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//' || echo "未知 CPU"
}

# 获取设备序列号 (SN): 三级回退, 均无则 N/A
get_serial_number() {
    local sn=""
    for key in system-serial-number baseboard-serial-number chassis-serial-number; do
        # dmidecode 缺失或非 root 时该管道会失败, 必须 || true, 否则 set -e 会直接终止监控
        sn=$(dmidecode -s "$key" 2>/dev/null | tr -d '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' || true)
        case "$sn" in
            ""|"Not Specified"|"None"|"Unknown"|"To Be Filled By O.E.M."|"System Serial Number"|"Base Board Serial Number"|"Chassis Serial Number")
                continue ;;
            *) echo "$sn"; return ;;
        esac
    done
    echo "N/A"
}

# 获取 OS 版本
get_os_version() {
    cat /etc/redhat-release 2>/dev/null \
        || { grep "^PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'; } \
        || echo "未知 OS"
}

#------------------------------- 内存 ECC (EDAC) -------------------------------
# 读一个 sysfs 计数文件, 去掉空白; 文件不存在或无权限时返回空 (不报错不中断)
_rd() {
    cat "$1" 2>/dev/null | tr -d '[:space:]' || true
}

# EDAC 是否可用 (存在且至少有一个 MC 的 ce_count)
edac_available() {
    [ -d "$EDAC_ROOT" ] || return 1
    ls "${EDAC_ROOT}"/mc*/ce_count >/dev/null 2>&1 || return 1
    return 0
}

# 归一化为非负整数, 非法值一律按 0 处理
_to_int() {
    case "${1:-}" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

# 采集 ECC 计数: 输出 "CE总数|UE总数|受影响位置摘要"
# 位置摘要按 CE 计数降序最多保留 3 项, 形如 "mc0/dimm3:1204;mc1/dimm7:12"
# 细粒度来源优先级: dimm*/dimm_ce_count (新驱动) -> csrow*/ce_count (老驱动)
get_edac() {
    if ! edac_available; then
        echo "N/A|N/A|N/A"
        return 0
    fi

    local ce_total=0 ue_total=0 detail="" mc_dir mc ce ue f label cnt base
    for mc_dir in "${EDAC_ROOT}"/mc*; do
        [ -d "$mc_dir" ] || continue
        mc=$(basename "$mc_dir")

        ce=$(_to_int "$(_rd "${mc_dir}/ce_count")")
        ue=$(_to_int "$(_rd "${mc_dir}/ue_count")")
        ce_total=$(( ce_total + ce ))
        ue_total=$(( ue_total + ue ))

        for f in "${mc_dir}"/dimm*/dimm_ce_count \
                 "${mc_dir}"/dimm*/dimm_ue_count \
                 "${mc_dir}"/csrow*/ce_count; do
            [ -r "$f" ] || continue
            cnt=$(_to_int "$(_rd "$f")")
            [ "$cnt" -gt 0 ] || continue
            base=$(basename "$(dirname "$f")")
            label="${mc}/${base}"
            case "$f" in
                *dimm_ue_count) label="${label}.ue" ;;
            esac
            detail="${detail}${label}:${cnt} "
        done
    done

    if [ -n "$detail" ]; then
        detail=$(printf '%s\n' $detail \
                 | awk -F: '{print $2"\t"$0}' \
                 | sort -rn \
                 | head -3 \
                 | cut -f2 \
                 | paste -sd';' -)
    fi
    [ -n "$detail" ] || detail="-"

    echo "${ce_total}|${ue_total}|${detail}"
}

#------------------------------- CSV 初始化 ----------------------------------
init_csv() {
    log "初始化 CSV: ${CSV_FILE}"
    # EDAC 可用性写入元数据: 报告据此区分 "0 次错误" 与 "根本没采到"
    local edac_avail=0 mc_n=0
    if edac_available; then
        edac_avail=1
        mc_n=$(ls -d "${EDAC_ROOT}"/mc* 2>/dev/null | wc -l | tr -d ' ')
    fi
    # 顶部写入元数据注释行 (以 # 开头, 供 generate_report.py 离线解析 CPU/SN/OS/计划时长/EDAC)
    {
        echo "# cpu_model: $(get_cpu_model)"
        echo "# serial_number: $(get_serial_number)"
        echo "# os_version: $(get_os_version)"
        if [ -n "$DURATION_HOURS" ]; then
            echo "# plan_duration_hours: ${DURATION_HOURS}"
        fi
        echo "# edac_available: ${edac_avail}"
        echo "# edac_mc_count: ${mc_n}"
        echo "timestamp,datetime,cpu_usage_pct,cpu_freq_mhz,mem_used_gb,mem_total_gb,mem_usage_pct,load_1m,load_5m,load_15m,cpu_temp_c,power_w,context_switches,processes,edac_ce_total,edac_ue_total,edac_ce_delta,edac_ue_delta,edac_loc"
    } > "$CSV_FILE"
    if [ "$edac_avail" -eq 1 ]; then
        log "EDAC 已启用: ${mc_n} 个内存控制器, 将采集 CE/UE 计数"
    else
        log "[WARN] 未检测到 EDAC (${EDAC_ROOT}), ECC 计数记为 N/A"
        log "       如需采集内存 ECC 错误: modprobe edac_mce_amd / skx_edac (视平台), 并确认 rasdaemon 已装"
    fi
    log "CSV 元数据与表头已写入, 开始监控 (间隔 ${INTERVAL}s)..."
    log "按 Ctrl+C 停止监控"
}

#------------------------------- 主循环 ---------------------------------------
main() {
    init_csv
    local prev_cs=""
    local prev_ts=""
    local prev_ce="" prev_ue=""

    while true; do
        local t_begin=$(_now_ms)
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
        local t_power=$(_now_ms)
        local power=$(get_power)
        local power_ms=$(( $(_now_ms) - t_power ))
        local cs=$(get_context_switches)
        local procs=$(get_process_count)

        # 内存 ECC: CE/UE 累计计数 + 本次采样新增 (delta)
        local edac=$(get_edac)
        local edac_ce=$(echo "$edac" | cut -d'|' -f1)
        local edac_ue=$(echo "$edac" | cut -d'|' -f2)
        local edac_loc=$(echo "$edac" | cut -d'|' -f3)
        local edac_ce_delta="N/A" edac_ue_delta="N/A"
        if [ "$edac_ce" != "N/A" ]; then
            if [ -n "$prev_ce" ] && [ "$prev_ce" != "N/A" ]; then
                edac_ce_delta=$(( edac_ce - prev_ce ))
                edac_ue_delta=$(( edac_ue - prev_ue ))
            fi
            prev_ce="$edac_ce"
            prev_ue="$edac_ue"
        fi

        # 上下文切换速率: 除数必须是"相邻两个采样点的真实时间差"。
        # v2.4 用固定 INTERVAL 做除数, 采样间隔一旦被拉长到 139s,
        # 算出的 CS/s 会虚高约 14 倍 (实测把 1.8k 报成了 24.9k)。
        local cs_rate="N/A"
        if [ -n "$prev_cs" ] && [ -n "$cs" ] && [ -n "$prev_ts" ]; then
            local dt_s=$(( ts - prev_ts ))
            [ "$dt_s" -gt 0 ] || dt_s=$INTERVAL
            cs_rate=$(awk "BEGIN {printf \"%.0f\", (${cs} - ${prev_cs}) / ${dt_s}}")
        fi
        prev_cs="$cs"
        prev_ts="$ts"

        # 写入 CSV
        echo "${ts},${dt},${cpu_usage},${cpu_freq},${mem_used_gb},${mem_total_gb},${mem_pct},${loadavg},${temp},${power},${cs_rate},${procs},${edac_ce},${edac_ue},${edac_ce_delta},${edac_ue_delta},${edac_loc}" >> "$CSV_FILE"

        # 采集耗时自检: 单轮采集超过采样间隔, 说明有环节被拖慢 (v2.5 就是靠这个定位到 ipmitool)
        local collect_ms=$(( $(_now_ms) - t_begin ))
        local slow_threshold=$(( INTERVAL * 1000 ))
        [ "$slow_threshold" -ge "$SLOW_WARN_MS" ] || slow_threshold=$SLOW_WARN_MS

        # 实时输出到 stderr
        log "CPU: ${cpu_usage}% | MEM: ${mem_used_gb}/${mem_total_gb} GB (${mem_pct}%) | Load: ${loadavg} | Temp: ${temp}C | Power: ${power}W | CS/s: ${cs_rate} | CE: ${edac_ce} (+${edac_ce_delta}) | UE: ${edac_ue} | 采集耗时: ${collect_ms}ms"

        if [ "$collect_ms" -gt "$slow_threshold" ]; then
            log "[WARN] 本轮采集耗时 ${collect_ms}ms (功耗环节 ${power_ms}ms) 超过阈值 ${slow_threshold}ms —— 实际采样间隔会被拉长, 详见 README 9.6"
            if [ "$power_ms" -gt $(( slow_threshold / 2 )) ]; then
                log "[WARN] 慢在功耗采集: ipmitool 在满载下响应退化, 建议 POWER_METHOD=dcmi 或 CMD_TIMEOUT=5"
            fi
        fi

        sleep "$INTERVAL"
    done
}

#------------------------------- 信号处理 -------------------------------------
trap 'log "监控已停止, CSV 文件: ${CSV_FILE}"; exit 0' SIGINT SIGTERM

#------------------------------- 入口 -----------------------------------------
# 仅在直接执行时进入主循环; 被 source 时只加载函数 (便于单元测试 get_edac 等)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
