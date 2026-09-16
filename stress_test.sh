#!/bin/bash
#=============================================================================
# stress_test.sh — 系统 CPU + 内存满负载压测 (参数全部运行时动态获取)
# 适用: 任意 x86_64 服务器 / RHEL 8.x (通用, 不写死硬件规格)
# 依赖: stress-ng 优先, 缺失时自动回退 GNU stress (由 run_all.sh 自动安装/选择)
#
# 版本变更:
#   v2.1 (2026-09-16) 修复"跑不满计划时长"问题
#        现象: stress-ng 报 "vm: calloc failed on vm_swap" /
#              "vm: gave up trying to mmap, no available memory" 后
#              "WARNING: finished prematurely after 2h35m" 提前终止 (计划 24h)
#        根因: 内存配额 = MemAvailable - 4GB ≈ 物理内存 99.8%,
#              内核 slab/页缓存/THP/监控进程/stress-ng 自身额外 calloc 无余量可用
#        修复: 1) 配额改为 min(MemTotal*95%, MemAvailable-8GB) 双上限
#              2) 单 worker 分配上限 256GB -> 128GB, 降低单次 mmap 失败概率
#              3) 启用 --oom-avoid, 由 stress-ng 主动规避 OOM
#              4) 新增提前退出自愈: 自动降配 5% 重启, 直至跑满计划时长
#=============================================================================

set -euo pipefail

#------------------------------- 配置区 ---------------------------------------
# 以下全部为运行时动态获取, 不写死任何硬件参数
DURATION_HOURS=${1:-24}          # 默认 24 小时 (统一按小时输入, 范围 0.1 ~ 48, 支持小数)

# 校验: 0.1 ~ 48 小时, 支持小数 (如 0.1 / 1.5 / 24 / 48, 可带 h 后缀), 并做单位转化 (小时 -> 秒)
DURATION_HOURS=$(echo "$DURATION_HOURS" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
DURATION_HOURS="${DURATION_HOURS%h}"
if [[ ! "$DURATION_HOURS" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
   || ! awk -v v="$DURATION_HOURS" 'BEGIN{ exit !(v >= 0.1 && v <= 48.0) }'; then
    echo "[ERROR] 无效的压测时长: '${1:-24}' (请输入 0.1 ~ 48 小时, 支持小数)" >&2
    exit 1
fi
DURATION_SEC=$(awk -v v="$DURATION_HOURS" 'BEGIN{ printf "%.0f", v*3600 }')

CPU_CORES=$(nproc)                # 动态读取逻辑核心数

# 日志目录需在任何可能报错的分支之前定义 (set -u 下引用未定义变量会直接退出)
LOG_DIR="/var/log/stress_test"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/stress_$(date +%Y%m%d_%H%M%S).log"
PID_FILE="${LOG_DIR}/stress_ng.pid"

#------------------- 内存配额策略 (可用环境变量覆盖) ---------------------------
# VM_MEM_PCT      : 占用物理内存的比例上限, 默认 95 (%)
# RESERVE_GB      : 至少保留给系统/内核的内存, 默认 8 (GB)
# VM_WORKER_MAX_GB: 单个 vm worker 最大分配量, 默认 128 (GB)
# VM_MEM_PCT_MIN  : 自愈降配下限, 低于此值不再重启, 默认 70 (%)
# VM_MEM_PCT_STEP : 每轮自愈降配步长, 默认 5 (%)
# AUTO_RETRY      : 提前退出是否自动降配重启 (1=启用, 0=禁用), 默认 1
VM_MEM_PCT=${VM_MEM_PCT:-95}
RESERVE_GB=${RESERVE_GB:-8}
VM_WORKER_MAX_GB=${VM_WORKER_MAX_GB:-128}
VM_MEM_PCT_MIN=${VM_MEM_PCT_MIN:-70}
VM_MEM_PCT_STEP=${VM_MEM_PCT_STEP:-5}
AUTO_RETRY=${AUTO_RETRY:-1}
VM_METHOD=${VM_METHOD:-}          # 留空 = stress-ng 默认 (all 轮换)

TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
AVAIL_MEM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
RESERVE_KB=$(( RESERVE_GB * 1024 * 1024 ))

# 按当前"占用比例"计算内存配额 (KB): 取 MemTotal*PCT% 与 MemAvailable-RESERVE 的较小值
compute_stress_mem_kb() {
    local pct="$1"
    local total_kb avail_kb by_pct by_avail
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    by_pct=$(( total_kb * pct / 100 ))
    by_avail=$(( avail_kb - RESERVE_KB ))
    if [ "$by_avail" -lt "$by_pct" ]; then
        echo "$by_avail"
    else
        echo "$by_pct"
    fi
}

STRESS_MEM_KB=$(compute_stress_mem_kb "$VM_MEM_PCT")
# 兜底: 若计算异常, 至少压测可用内存的一半
if [ "$STRESS_MEM_KB" -lt $((1 * 1024 * 1024)) ]; then
    STRESS_MEM_KB=$((AVAIL_MEM_KB / 2))
fi

# 动态计算 vm worker 数: 每个 worker 最多分配 VM_WORKER_MAX_GB,
# 规避单进程地址空间/ulimit/单次 mmap 过大失败的风险
calc_vm_workers() {
    local mem_kb="$1"
    local n=$(( mem_kb / 1024 / 1024 / VM_WORKER_MAX_GB + 1 ))
    [ "$n" -lt 1 ] && n=1
    echo "$n"
}
VM_WORKERS=$(calc_vm_workers "$STRESS_MEM_KB")

#---------------- 压测引擎选择 -----------------------------------------------
# 优先 stress-ng; 若无则回退 GNU stress (两者参数语法不同, 分别构造)
if command -v stress-ng &>/dev/null; then
    ENGINE="stress-ng"
elif command -v stress &>/dev/null; then
    ENGINE="stress"
else
    echo "[ERROR] 未找到 stress-ng 或 stress 压测工具, 请先安装: dnf install -y stress-ng" | tee -a "$LOG_FILE" 2>/dev/null
    exit 1
fi

#------------------------------- 函数区 ---------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# 动态读取 CPU 型号
get_cpu_model() {
    grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//' || echo "未知 CPU"
}

# 读取设备序列号 (SN): 优先系统序列号, 回退主板/机箱序列号, 均无则 N/A
get_serial_number() {
    local sn=""
    for key in system-serial-number baseboard-serial-number chassis-serial-number; do
        sn=$(dmidecode -s "$key" 2>/dev/null | tr -d '\n' | sed 's/^[ \t]*//;s/[ \t]*$//')
        case "$sn" in
            ""|"Not Specified"|"None"|"Unknown"|"To Be Filled By O.E.M."|"System Serial Number"|"Base Board Serial Number"|"Chassis Serial Number")
                continue ;;
            *)
                echo "$sn"; return ;;
        esac
    done
    echo "N/A"
}

show_header() {
    log "============================================================"
    log "  系统满负载压力测试 — ${ENGINE}"
    log "  CPU 型号: $(get_cpu_model)"
    log "  CPU 逻辑核心: ${CPU_CORES} (动态读取)"
    log "  内存: 压测 ~$(( STRESS_MEM_KB / 1024 / 1024 )) GB / 可用 $(( AVAIL_MEM_KB / 1024 / 1024 )) GB / 总 $(( TOTAL_MEM_KB / 1024 / 1024 )) GB"
    log "  内存配额策略: min(MemTotal*${VM_MEM_PCT}%, MemAvailable-${RESERVE_GB}GB)"
    log "  内存 worker 数: ${VM_WORKERS} (单 worker 上限 ${VM_WORKER_MAX_GB} GB, 动态计算)"
    log "  系统: $(cat /etc/redhat-release 2>/dev/null || echo '未知')"
    log "  设备序列号: $(get_serial_number)"
    log "  持续时间: ${DURATION_HOURS} 小时 (${DURATION_SEC} 秒)"
    log "  开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log "============================================================"
}

check_prerequisites() {
    log "压测引擎: ${ENGINE} ($(command -v "$ENGINE"))"

    # 动态检查 CPU 核心数 (不做任何硬件假设)
    log "检测到 CPU 逻辑核心数: ${CPU_CORES}"
    if [ "$CPU_CORES" -lt 2 ]; then
        log "[WARN] 逻辑核心数异常(< 2), 请检查 CPU/超线程状态"
    fi

    # 动态检查可用内存
    log "总内存: $(( TOTAL_MEM_KB / 1024 / 1024 )) GB, 可用: $(( AVAIL_MEM_KB / 1024 / 1024 )) GB"
    log "本次压测将占用内存: ~$(( STRESS_MEM_KB / 1024 / 1024 )) GB (留 $(( (TOTAL_MEM_KB - STRESS_MEM_KB) / 1024 / 1024 )) GB 余量)"

    # 输出 overcommit / swap 相关内核参数, 便于事后分析 mmap 失败
    local oc mf sw
    oc=$(sysctl -n vm.overcommit_memory 2>/dev/null || echo "?")
    mf=$(sysctl -n vm.min_free_kbytes 2>/dev/null || echo "?")
    sw=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "?")
    log "内核参数: vm.overcommit_memory=${oc}, vm.min_free_kbytes=${mf} kB, SwapTotal=${sw} kB"
}

# 检测 stress-ng 是否支持某参数 (老版本如 0.15.00 不支持 --vm-stride 等)
stress_ng_supports() {
    "$ENGINE" --help 2>&1 | grep -q -- "$1"
}

# 启动压测: $1 = 本轮运行时长(秒), $2 = 本轮内存占用比例(%)
start_stress() {
    local run_sec="$1"
    local pct="$2"

    STRESS_MEM_KB=$(compute_stress_mem_kb "$pct")
    VM_WORKERS=$(calc_vm_workers "$STRESS_MEM_KB")
    local mem_b=$(( STRESS_MEM_KB * 1024 ))
    local vm_bytes_per_worker_kb=$(( STRESS_MEM_KB / VM_WORKERS ))

    log "启动 ${ENGINE} 压测 (本轮 ${run_sec}s, 内存配额 ${pct}% ≈ $(( STRESS_MEM_KB / 1024 / 1024 )) GB, ${VM_WORKERS} workers)..."

    # CPU 满载: --cpu 使用全部逻辑核(动态), stress-ng 额外用 --cpu-method all 轮换算法
    # 内存满载: --vm ${VM_WORKERS} 个 worker(动态) + --vm-bytes 传总量
    #           (stress-ng 把总量均分给各 worker; 切勿传"每 worker 量"否则内存压不满)
    #           stress-ng 用 --vm-keep 保持占用; GNU stress 用 --vm-hang 保持占用
    # --oom-avoid: 让 stress-ng 主动规避 OOM, 防止 vm worker 因分配失败提前退出
    # --timeout: 控制本轮运行时长
    if [ "$ENGINE" = "stress-ng" ]; then
        local -a SNG_ARGS=()
        SNG_ARGS+=(--cpu "$CPU_CORES")
        SNG_ARGS+=(--cpu-method all)
        SNG_ARGS+=(--cpu-load 100)
        SNG_ARGS+=(--vm "$VM_WORKERS")
        SNG_ARGS+=(--vm-bytes "${mem_b}"B)
        SNG_ARGS+=(--vm-keep)
        if stress_ng_supports "oom-avoid"; then
            SNG_ARGS+=(--oom-avoid)
        fi
        if [ -n "$VM_METHOD" ] && stress_ng_supports "vm-method"; then
            SNG_ARGS+=(--vm-method "$VM_METHOD")
        fi
        if stress_ng_supports "vm-stride"; then
            SNG_ARGS+=(--vm-stride 4096)
        else
            log "[提示] 当前 stress-ng 版本不支持 --vm-stride, 已自动跳过 (不影响内存满载)"
        fi
        SNG_ARGS+=(--metrics-brief)
        SNG_ARGS+=(--timeout "$run_sec")
        if stress_ng_supports "temp-path"; then
            SNG_ARGS+=(--temp-path "$LOG_DIR")
        fi
        SNG_ARGS+=(--log-file "$LOG_FILE")
        # 屏蔽 stress-ng 的 info 级别日志刷屏 (如 256 个 cpu worker 因 --cpu-method all
        # 各打印一条提示), 仅保留 warn/error 与最终 metrics;
        # 完整日志 (含 info 与 metrics) 已由 --log-file 写入文件, 不影响事后排查
        stress-ng "${SNG_ARGS[@]}" 2> >(grep --line-buffered -v 'stress-ng: info:' >&2) &
    else
        # GNU stress 1.0.4 参数: --vm-hang 让 worker 分配后挂起 60s, 保持内存占用
        stress \
            --cpu "$CPU_CORES" \
            --vm "$VM_WORKERS" \
            --vm-bytes "${vm_bytes_per_worker_kb}"K \
            --vm-hang 60 \
            --timeout "$run_sec" &
    fi

    local pid=$!
    echo "$pid" > "$PID_FILE"
    log "${ENGINE} 已启动, PID: ${pid}"
    log "PID 文件: ${PID_FILE}"

    # 等待几秒确认进程存活
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        log "${ENGINE} 进程运行正常"
    else
        log "[ERROR] ${ENGINE} 启动失败! 请检查日志: ${LOG_FILE}"
        return 1
    fi
    return 0
}

stop_stress() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "停止 ${ENGINE} (PID: ${pid})..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$pid" 2>/dev/null || true
            log "${ENGINE} 已停止"
        else
            log "${ENGINE} 进程已不存在"
        fi
        rm -f "$PID_FILE"
    fi

    # 兜底: 杀死所有残留压测进程 (兼容 stress-ng 与 GNU stress)
    pkill -f "stress-ng.*--cpu" 2>/dev/null || true
    pkill -f "stress --cpu" 2>/dev/null || true
    log "清理完成"
}

show_summary() {
    log "============================================================"
    log "  压测结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log "  详细日志: ${LOG_FILE}"
    log "============================================================"

    # 输出系统状态快照
    log "--- 系统状态快照 ---"
    log "CPU 使用率:"
    top -bn1 | head -5 | tee -a "$LOG_FILE"
    log "内存使用:"
    free -h | tee -a "$LOG_FILE"
    log "系统负载:"
    cat /proc/loadavg | tee -a "$LOG_FILE"

    # OOM / 分配失败排查线索
    log "--- OOM / 内存分配失败线索 ---"
    local oom_hit=0
    if dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -20 | tee -a "$LOG_FILE"; then
        oom_hit=1
    fi
    if [ "$oom_hit" = "0" ]; then
        log "(dmesg 中未检索到 OOM 记录, 或当前无 dmesg 权限)"
    fi
    log "温度传感器 (如可用):"
    sensors 2>/dev/null | tee -a "$LOG_FILE" || log "(sensors 未安装, 跳过温度读取)"
}

#------------------------------- 信号处理 -------------------------------------
trap 'log "收到中断信号, 停止压测..."; stop_stress; show_summary; exit 130' SIGINT SIGTERM

#------------------------------- 主流程 ---------------------------------------
# 循环守护: stress-ng 若因内存分配失败提前退出 (finished prematurely),
# 自动降配 5% 后重启, 直到累计跑满计划时长; 避免因一次失败导致 24h 压测作废
main() {
    show_header
    check_prerequisites

    local deadline=$(( $(date +%s) + DURATION_SEC ))
    local attempt=0
    local pct=$VM_MEM_PCT
    local rc=0

    while :; do
        local now remain
        now=$(date +%s)
        remain=$(( deadline - now ))
        if [ "$remain" -le 0 ]; then break; fi

        attempt=$(( attempt + 1 ))
        log "===== 第 ${attempt} 轮压测: 计划剩余 ${remain}s, 内存配额 ${pct}% ====="

        if ! start_stress "$remain" "$pct"; then
            log "[ERROR] 第 ${attempt} 轮启动失败, 终止"
            rc=1
            break
        fi

        local pid
        pid=$(cat "$PID_FILE")
        wait "$pid" 2>/dev/null || true

        remain=$(( deadline - $(date +%s) ))
        if [ "$remain" -le 15 ]; then
            log "第 ${attempt} 轮正常结束, 已跑满计划时长 ${DURATION_HOURS} 小时"
            break
        fi

        log "[WARN] ${ENGINE} 第 ${attempt} 轮提前退出 (距计划结束还剩 ${remain}s)"
        log "[WARN] 若上方出现 'calloc failed on vm_swap' / 'gave up trying to mmap', 即为内存配额过高"
        stop_stress

        if [ "$AUTO_RETRY" != "1" ]; then
            log "[ERROR] AUTO_RETRY=0, 不自动重启; 未跑满计划时长即终止"
            rc=1
            break
        fi
        local next_pct=$(( pct - VM_MEM_PCT_STEP ))
        if [ "$next_pct" -lt "$VM_MEM_PCT_MIN" ]; then
            log "[ERROR] 内存配额已降至下限 ${VM_MEM_PCT_MIN}% 仍无法维持, 停止重试 (请检查内存硬件/EDAC)"
            rc=1
            break
        fi
        pct=$next_pct
        log "[INFO] 10 秒后以 ${pct}% 内存配额重启第 $((attempt+1)) 轮压测..."
        sleep 10
    done

    rm -f "$PID_FILE"
    show_summary
    return $rc
}

#------------------------------- 入口 -----------------------------------------
case "${1:-}" in
    --stop)
        stop_stress
        ;;
    --status)
        if [ -f "$PID_FILE" ]; then
            pid=$(cat "$PID_FILE")
            if kill -0 "$pid" 2>/dev/null; then
                echo "${ENGINE} 运行中, PID: ${pid}"
                ps -p "$pid" -o pid,etime,%cpu,%mem,cmd --no-headers
                exit 0
            fi
        fi
        echo "${ENGINE} 未运行"
        exit 1
        ;;
    --help|-h)
        echo "用法: bash stress_test.sh [持续时间小时数, 0.1~48, 支持小数]"
        echo "  默认: 24 (24小时)"
        echo "  --stop   停止压测"
        echo "  --status 查看状态"
        echo ""
        echo "可用环境变量 (内存配额调优):"
        echo "  VM_MEM_PCT=95        占用物理内存比例上限 (%)"
        echo "  RESERVE_GB=8         至少保留给系统的内存 (GB)"
        echo "  VM_WORKER_MAX_GB=128 单个 vm worker 最大分配量 (GB)"
        echo "  VM_MEM_PCT_MIN=70    自愈降配下限 (%)"
        echo "  VM_MEM_PCT_STEP=5    每轮自愈降配步长 (%)"
        echo "  AUTO_RETRY=1         提前退出是否自动降配重启 (1/0)"
        echo "  VM_METHOD=           指定 stress-ng --vm-method (留空=默认 all)"
        ;;
    *)
        main
        ;;
esac
