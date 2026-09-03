#!/bin/bash
#=============================================================================
# stress_test.sh — 系统 CPU + 内存满负载压测 (参数全部运行时动态获取)
# 适用: 任意 x86_64 服务器 / RHEL 8.x (通用, 不写死硬件规格)
# 依赖: stress-ng 优先, 缺失时自动回退 GNU stress (由 run_all.sh 自动安装/选择)
#=============================================================================

set -euo pipefail

#------------------------------- 配置区 ---------------------------------------
# 以下全部为运行时动态获取, 不写死任何硬件参数
DURATION_SEC=${1:-86400}          # 默认 24 小时 = 86400 秒
CPU_CORES=$(nproc)                # 动态读取逻辑核心数
# 内存: 基于系统实际"可用内存"动态计算, 保留 4GB 给系统, 其余全部压测
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
AVAIL_MEM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
RESERVE_KB=$((4 * 1024 * 1024))   # 保留 4GB 给系统
STRESS_MEM_KB=$((AVAIL_MEM_KB - RESERVE_KB))
# 兜底: 若计算异常, 至少压测可用内存的一半
if [ "$STRESS_MEM_KB" -lt $((1 * 1024 * 1024)) ]; then
    STRESS_MEM_KB=$((AVAIL_MEM_KB / 2))
fi
# 转成 stress-ng 可读的内存量 (bytes)
STRESS_MEM_B=$((STRESS_MEM_KB * 1024))
# 动态计算 vm worker 数: 每个 worker 最多分配 256GB, 规避单进程地址空间/ulimit 限制
VM_WORKERS=$(( (STRESS_MEM_KB / 1024 / 1024 / 256) + 1 ))
# 每个 worker 分配的内存量 (KB): worker数 × 单worker = 压测总量
VM_BYTES_PER_WORKER=$(( STRESS_MEM_KB / VM_WORKERS ))

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

LOG_DIR="/var/log/stress_test"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/stress_$(date +%Y%m%d_%H%M%S).log"
PID_FILE="${LOG_DIR}/stress_ng.pid"

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
    log "  内存: 压测 ~$(( STRESS_MEM_KB / 1024 / 1024 )) GB / 可用 $(( AVAIL_MEM_KB / 1024 / 1024 )) GB / 总 $(( TOTAL_MEM_KB / 1024 / 1024 )) GB (保留 4GB)"
    log "  内存 worker 数: ${VM_WORKERS} (动态计算)"
    log "  系统: $(cat /etc/redhat-release 2>/dev/null || echo '未知')"
    log "  设备序列号: $(get_serial_number)"
    log "  持续时间: ${DURATION_SEC} 秒 ($(( DURATION_SEC / 3600 )) 小时)"
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
    log "本次压测将占用内存: ~$(( STRESS_MEM_KB / 1024 / 1024 )) GB"
}

# 检测 stress-ng 是否支持某参数 (老版本如 0.15.00 不支持 --vm-stride 等)
stress_ng_supports() {
    "$ENGINE" --help 2>&1 | grep -q -- "$1"
}

start_stress() {
    log "启动 ${ENGINE} 压测..."

    # CPU 满载: --cpu 使用全部逻辑核(动态), stress-ng 额外用 --cpu-method all 轮换算法
    # 内存满载: --vm ${VM_WORKERS} 个 worker(动态), 每 worker 分配 VM_BYTES_PER_WORKER
    #           (worker数 × 单worker = 压测内存总量)
    #           stress-ng 用 --vm-keep 保持占用; GNU stress 用 --vm-hang 保持占用
    # 兼容性: 逐个探测参数支持情况, 老版本不支持的参数自动跳过, 不影响满载效果
    # --timeout 控制运行时长
    if [ "$ENGINE" = "stress-ng" ]; then
        local -a SNG_ARGS=()
        SNG_ARGS+=(--cpu "$CPU_CORES")
        SNG_ARGS+=(--cpu-method all)
        SNG_ARGS+=(--cpu-load 100)
        SNG_ARGS+=(--vm "$VM_WORKERS")
        SNG_ARGS+=(--vm-bytes "$(( VM_BYTES_PER_WORKER * 1024 ))"B)
        SNG_ARGS+=(--vm-keep)
        if stress_ng_supports "vm-stride"; then
            SNG_ARGS+=(--vm-stride 4096)
        else
            log "[提示] 当前 stress-ng 版本不支持 --vm-stride, 已自动跳过 (不影响内存满载)"
        fi
        SNG_ARGS+=(--metrics-brief)
        SNG_ARGS+=(--timeout "$DURATION_SEC")
        if stress_ng_supports "temp-path"; then
            SNG_ARGS+=(--temp-path "$LOG_DIR")
        fi
        SNG_ARGS+=(--log-file "$LOG_FILE")
        # --verbose 老版本是纯开关, 新版本可带 level, 统一探测后按支持形式追加
        if stress_ng_supports "verbose"; then
            if stress_ng_supports "verbose="; then
                SNG_ARGS+=(--verbose=1)
            else
                SNG_ARGS+=(--verbose)
            fi
        fi
        stress-ng "${SNG_ARGS[@]}" &
    else
        # GNU stress 1.0.4 参数: --vm-hang 让 worker 分配后挂起 60s, 保持内存占用
        stress \
            --cpu "$CPU_CORES" \
            --vm "$VM_WORKERS" \
            --vm-bytes "${VM_BYTES_PER_WORKER}"K \
            --vm-hang 60 \
            --timeout "$DURATION_SEC" &
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
        exit 1
    fi
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
    log "温度传感器 (如可用):"
    sensors 2>/dev/null | tee -a "$LOG_FILE" || log "(sensors 未安装, 跳过温度读取)"
}

#------------------------------- 信号处理 -------------------------------------
trap 'log "收到中断信号, 停止压测..."; stop_stress; show_summary; exit 130' SIGINT SIGTERM

#------------------------------- 主流程 ---------------------------------------
main() {
    show_header
    check_prerequisites
    start_stress

    log "压测运行中, 预计 ${DURATION_SEC} 秒后自动结束..."
    log "如需手动停止: bash stress_test.sh --stop  或  kill -TERM \$(cat ${PID_FILE})"

    # 等待压测结束 (stress-ng --timeout 会自动退出)
    local pid=$(cat "$PID_FILE")
    wait "$pid" 2>/dev/null || true

    log "${ENGINE} 进程已退出"
    show_summary
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
        echo "用法: bash stress_test.sh [持续时间秒数]"
        echo "  默认: 86400 (24小时)"
        echo "  --stop   停止压测"
        echo "  --status 查看状态"
        ;;
    *)
        main
        ;;
esac
