#!/bin/bash
#=============================================================================
# run_all.sh — 一键执行: 依赖安装 -> 环境检查 -> 压测 + 监控 -> 报告生成
# 用法:
#   bash run_all.sh                 # 交互输入压测时长, 回车默认 24h
#   bash run_all.sh 43200           # 指定秒数 (12 小时)
#   bash run_all.sh 12h             # 指定小时 (也支持 30m / 2d)
# 适用: 任意 x86_64 服务器 / RHEL 8.x (需 root 或 sudo)
# 压测规模 (CPU 核心数/内存总量) 全部运行时动态获取
#
# 依赖安装策略 (离线优先):
#   1) 若同目录存在 rpms/ 离线包, 先用其安装 stress-ng/stress/sysstat/lm_sensors/ipmitool
#   2) 离线包缺失或安装失败, 自动回退在线源 (EPEL) 兜底
#=============================================================================

set -euo pipefail

#------------------------------- 配置区 ---------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/stress_test"
mkdir -p "$LOG_DIR"

REPORT_DIR="${SCRIPT_DIR}/report"
mkdir -p "$REPORT_DIR"

#------------------------------- 函数区 ---------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# 解析时长: 支持纯秒数 / 2d / 12h / 30m, 返回秒数; 非法返回 -1
parse_duration() {
    local val="$1"
    val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
    elif [[ "$val" =~ ^([0-9]+)d$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 86400 ))
    elif [[ "$val" =~ ^([0-9]+)h$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$val" =~ ^([0-9]+)m$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 60 ))
    else
        echo "-1"
    fi
}

# 压测时长: 命令行参数优先, 否则交互输入 (回车默认 24h)
prompt_duration() {
    if [ $# -gt 0 ]; then
        DURATION_SEC=$(parse_duration "$1")
        if [ "$DURATION_SEC" -le 0 ]; then
            log "[ERROR] 无效的压测时长: $1 (支持秒数 / 2d / 12h / 30m)"
            exit 1
        fi
        log "压测时长 (命令行参数): $1 = ${DURATION_SEC} 秒"
        return
    fi

    while true; do
        if ! read -r -p "请输入压测时长 [回车=24小时, 支持格式: 86400(秒) / 12h / 30m / 2d]: " input; then
            # 非交互环境 (nohup 后台 / SSH 断开 / stdin 关闭) 自动默认 24h, 不阻塞
            log "[提示] 非交互环境, 自动使用默认时长 24 小时"
            DURATION_SEC=86400
            break
        fi
        input=${input:-24h}
        DURATION_SEC=$(parse_duration "$input")
        if [ "$DURATION_SEC" -le 0 ]; then
            echo "[ERROR] 无效输入 '$input', 请重新输入 (支持秒数 / 2d / 12h / 30m)"
            continue
        fi
        local hours=$(( DURATION_SEC / 3600 ))
        local mins=$(( (DURATION_SEC % 3600) / 60 ))
        if [ "$mins" -eq 0 ]; then
            log "压测时长: ${hours} 小时 (${DURATION_SEC} 秒)"
        else
            log "压测时长: ${hours} 小时 ${mins} 分 (${DURATION_SEC} 秒)"
        fi
        break
    done
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "[ERROR] 请使用 root 运行: sudo bash run_all.sh"
        exit 1
    fi
}

# 从本地 rpms/ 目录离线安装依赖 (内网/离线环境优先)
install_from_offline() {
    local RPM_DIR="${SCRIPT_DIR}/rpms"
    [ -d "$RPM_DIR" ] || return 1
    local rpms=("${RPM_DIR}"/*.rpm)
    [ "${#rpms[@]}" -gt 0 ] || return 1

    log "==> 检测到离线 RPM 包 (${#rpms[@]} 个), 优先离线安装..."

    # 1) 优先 dnf/yum 本地安装 (自动解析依赖, 已装包自动跳过)
    if command -v dnf &>/dev/null; then
        if dnf install -y "${rpms[@]}" 2>/dev/null; then
            log "离线安装完成 (dnf)"
            return 0
        fi
        log "[WARN] dnf 离线安装失败, 回退 rpm 直接安装..."
    elif command -v yum &>/dev/null; then
        if yum install -y "${rpms[@]}" 2>/dev/null; then
            log "离线安装完成 (yum)"
            return 0
        fi
        log "[WARN] yum 离线安装失败, 回退 rpm 直接安装..."
    fi

    # 2) 回退 rpm: 逐个安装, 跳过已装包; 依赖包字母序先于主包, 顺序安全
    local failed=0
    local f pkgname
    for f in "${rpms[@]}"; do
        pkgname=$(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null)
        rpm -q "$pkgname" &>/dev/null && continue
        if rpm -Uvh "$f" 2>/dev/null; then
            log "  已安装: $(basename "$f")"
        else
            log "[WARN] 安装失败: $(basename "$f")"
            failed=1
        fi
    done
    return "$failed"
}

# 安装 stress-ng (RHEL 8 默认仓库无此包, 需要 EPEL 仓库)
ensure_stress_ng() {
    if command -v stress-ng &>/dev/null; then
        log "stress-ng 已安装: $(stress-ng --version 2>/dev/null | head -1)"
        return 0
    fi
    # 回退引擎: GNU stress 也能满足压测需求 (stress_test.sh 会自动选择)
    if command -v stress &>/dev/null; then
        log "stress-ng 未安装, 使用已就绪的 GNU stress ($(stress --version 2>/dev/null | head -1)) 作为压测引擎"
        return 0
    fi

    log "安装 stress-ng ..."
    if dnf install -y stress-ng &>/dev/null; then
        return 0
    fi

    log "[提示] RHEL 8 官方仓库 (BaseOS/AppStream) 不含 stress-ng, 尝试安装 EPEL 仓库..."
    if dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm &>/dev/null \
       || dnf install -y https://mirrors.aliyun.com/epel/epel-release-latest-8.noarch.rpm &>/dev/null; then
        log "EPEL 仓库安装成功, 重试安装 stress-ng ..."
        if dnf install -y stress-ng; then
            return 0
        fi
    fi

    log "[ERROR] stress-ng / stress 安装失败!"
    log "        原因: RHEL 8 默认仓库不含这两个压测包, 必须使用 EPEL 仓库"
    log "        请手动处理 (任选其一) 后重新运行本脚本:"
    log "          1) 有外网: dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm"
    log "                     dnf install -y stress-ng"
    log "          2) 内网:   配置内网 EPEL 镜像源后重试"
    log "          3) 离线:   在可联网机器下载 RPM 上传后: dnf install ./stress*.rpm"
    exit 1
}

install_deps() {
    log "==> 检查/安装依赖 (stress-ng, sysstat, lm_sensors, ipmitool)..."

    # 离线优先: 同目录存在 rpms/ 离线包且依赖未满足时, 先离线安装
    local need_offline=0
    { command -v stress-ng &>/dev/null || command -v stress &>/dev/null; } || need_offline=1
    command -v mpstat &>/dev/null || need_offline=1
    command -v sensors &>/dev/null || need_offline=1
    command -v ipmitool &>/dev/null || need_offline=1
    if [ "$need_offline" -eq 1 ] && [ -d "${SCRIPT_DIR}/rpms" ] && ls "${SCRIPT_DIR}"/rpms/*.rpm &>/dev/null; then
        install_from_offline
    fi

    # 在线兜底: 离线装完仍缺失的, 走在线源 (EPEL)
    ensure_stress_ng
    if ! command -v mpstat &>/dev/null; then
        log "安装 sysstat ..."
        dnf install -y sysstat || yum install -y sysstat || true
    fi
    # 温度/功耗工具可选, 安装失败不阻断
    command -v sensors &>/dev/null || { log "安装 lm_sensors ..."; dnf install -y lm_sensors || true; }
    command -v ipmitool &>/dev/null || { log "安装 ipmitool ..."; dnf install -y ipmitool || true; }

    if command -v stress-ng &>/dev/null; then
        log "压测引擎: $(stress-ng --version 2>/dev/null | head -1)"
    elif command -v stress &>/dev/null; then
        log "压测引擎: $(stress --version 2>/dev/null | head -1)"
    else
        log "[WARN] 未检测到压测引擎 (stress-ng / stress), 压测将失败!"
    fi
    log "依赖检查完成"
}

check_env() {
    log "==> 环境检查..."
    local cores=$(nproc)
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_gb=$((mem_kb / 1024 / 1024))
    local cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')

    log "CPU 型号: ${cpu_model}"
    log "CPU 逻辑核心: ${cores}"
    log "物理内存: ${mem_gb} GB"
    log "压测将按系统实际资源动态满载: CPU ${cores} 核 / 内存约 $(( mem_gb - 4 )) GB (保留 4GB)"

    # 兜底: 内存过小 (< 8GB) 时提醒, 避免 OOM 影响生产
    if [ "$mem_gb" -lt 8 ]; then
        log "[WARN] 检测到内存仅 ${mem_gb} GB, 满载压测风险较高, 请确认!"
        read -r -p "是否继续? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { log "已取消"; exit 1; }
    fi

    # 磁盘空间检查 (报告/日志落盘)
    local avail_gb=$(df -BG "${SCRIPT_DIR}" | awk 'NR==2 {print $4}' | tr -d 'G')
    log "工作目录剩余空间: ${avail_gb} GB"
    if [ "${avail_gb%G}" -lt 5 ]; then
        log "[ERROR] 剩余空间不足 5GB!"
        exit 1
    fi

    # 电源/散热提醒
    log "[提示] 请确认机房散热与供电充足 (双路 7763 满载功耗约 600~900W)"
}

run_stress_and_monitor() {
    log "==> 启动压测 (${DURATION_SEC}s) 与监控..."

    # 清理可能残留的旧监控进程 (上次运行失败时可能遗留)
    pkill -f "monitor.sh" 2>/dev/null || true
    sleep 1

    # 先启动监控 (后台)
    bash "${SCRIPT_DIR}/monitor.sh" 10 > "${LOG_DIR}/monitor_console.log" 2>&1 &
    MONITOR_PID=$!
    log "监控已启动, PID: ${MONITOR_PID}, 日志: ${LOG_DIR}/monitor_console.log"
    sleep 2

    # 再启动压测 (前台阻塞, --timeout 自动结束)
    # 通过 --log-file 让 stress-ng 写详细日志
    bash "${SCRIPT_DIR}/stress_test.sh" "${DURATION_SEC}"

    STRESS_RC=$?
    log "压测进程结束, 退出码: ${STRESS_RC}"

    # 压测异常退出时提示检查, 但继续收集已有数据
    if [ "$STRESS_RC" -ne 0 ]; then
        log "[WARN] 压测进程退出码非 0, 请检查上方日志!"
        log "       常见原因: stress-ng 参数不兼容 / 内存不足 / 被外部 kill"
        log "       若为参数问题, 请确认已使用最新版 stress_test.sh (含参数兼容探测)"
    fi

    # 停止监控
    log "停止监控 (PID: ${MONITOR_PID})..."
    kill -TERM "${MONITOR_PID}" 2>/dev/null || true
    sleep 2
    # 兜底清理
    pkill -f "monitor.sh" 2>/dev/null || true

    # 找最新 CSV
    LATEST_CSV=$(ls -t "${LOG_DIR}"/monitor_*.csv 2>/dev/null | head -1)
    if [ -z "$LATEST_CSV" ]; then
        log "[ERROR] 未找到监控 CSV!"
        exit 1
    fi
    log "监控数据: ${LATEST_CSV}"

    # 生成报告
    local ts=$(date +%Y%m%d_%H%M%S)
    local html="${REPORT_DIR}/stress_report_${ts}.html"
    log "生成报告: ${html}"
    python3 "${SCRIPT_DIR}/generate_report.py" "${LATEST_CSV}" "${html}"

    # 收集 stress-ng 汇总
    local stress_log=$(ls -t "${LOG_DIR}"/stress_*.log 2>/dev/null | grep -v monitor | head -1)
    if [ -n "$stress_log" ]; then
        log "stress-ng 详细日志: ${stress_log}"
    fi

    log "=================================================="
    log "  全部完成!"
    log "  HTML 报告: ${html}"
    log "  监控 CSV:  ${LATEST_CSV}"
    log "  stress-ng 日志: ${stress_log:-N/A}"
    log "=================================================="
}

#------------------------------- 入口 -----------------------------------------
main() {
    need_root
    prompt_duration "$@"
    log "==> 系统满负载压测 (stress-ng + 监控 + 报告)"
    log "压测时长: ${DURATION_SEC} 秒 ($(( DURATION_SEC / 3600 )) 小时)"
    install_deps
    check_env

    # 再次确认 (生产服务器操作提醒); 非交互环境自动跳过确认
    local dur_h=$(( DURATION_SEC / 3600 ))
    local dur_m=$(( (DURATION_SEC % 3600) / 60 ))
    local dur_txt="${dur_h} 小时"
    [ "$dur_m" -gt 0 ] && dur_txt="${dur_h} 小时 ${dur_m} 分"
    log ""
    log "即将对服务器施加 ${dur_txt} 满负载压力, 期间 CPU 100% / 内存 95%+ 占用!"
    if read -r -p "确认开始压测? 输入 YES 继续: " ans && [ "$ans" = "YES" ]; then
        :
    elif [ -t 0 ]; then
        log "已取消"
        exit 1
    else
        log "[提示] 非交互环境, 自动跳过确认, 直接开始压测"
    fi

    run_stress_and_monitor
}

main "$@"
