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

# 版本号比较: $1 >= $2 返回 0, 否则返回 1 (三段式, 前导零安全)
version_ge() {
    local a b i x y
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2; do
        x=${a[$i]:-0}; y=${b[$i]:-0}
        (( 10#$x > 10#$y )) && return 0
        (( 10#$x < 10#$y )) && return 1
    done
    return 0
}

# 从本地 rpms/ 目录离线安装依赖 (内网/离线环境优先; stress-ng 单独处理, 默认源码编译 0.20.01)
install_from_offline() {
    local RPM_DIR="${SCRIPT_DIR}/rpms"
    [ -d "$RPM_DIR" ] || return 1
    # 排除 stress-ng RPM (默认走源码编译 0.20.01, 见 ensure_stress_ng)
    local rpms=()
    local f
    for f in "${RPM_DIR}"/*.rpm; do
        case "$f" in
            *stress-ng*) continue ;;
        esac
        rpms+=("$f")
    done
    [ "${#rpms[@]}" -gt 0 ] || return 1

    log "==> 检测到离线 RPM 包 (${#rpms[@]} 个, 已排除 stress-ng), 优先离线安装..."

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

# 源码编译安装 stress-ng 0.20.01 (默认版本; 编译仅需 gcc + make, 可选库缺失只禁用对应 stressor)
install_stress_ng_source() {
    local tgz="$1"
    local build_dir
    build_dir=$(mktemp -d /tmp/stress-ng-build.XXXXXX) || return 1
    log "==> 源码编译安装 stress-ng 0.20.01 (默认版本)..."
    log "    依赖: gcc + make (构建工具); libaio/judy/sctp 等为可选增强, 缺失不影响 CPU/内存压测"

    tar -xzf "$tgz" -C "$build_dir" || { rm -rf "$build_dir"; return 1; }
    local src_dir
    src_dir=$(find "$build_dir" -maxdepth 1 -type d -name 'stress-ng-*' | head -1)
    [ -n "$src_dir" ] || { rm -rf "$build_dir"; return 1; }

    if ! (cd "$src_dir" && make -j"$(nproc)" >/dev/null 2>&1); then
        log "[WARN] stress-ng 编译失败 (make), 构建日志目录: ${build_dir}"
        rm -rf "$build_dir"
        return 1
    fi
    # 直接安装编译产物 (单文件二进制), 不依赖 Makefile 的 install 目标细节
    if ! install -m 755 "${src_dir}/stress-ng" /usr/bin/stress-ng 2>/dev/null; then
        log "[WARN] stress-ng 安装失败 (install 到 /usr/bin)"
        rm -rf "$build_dir"
        return 1
    fi

    rm -rf "$build_dir"
    if command -v stress-ng &>/dev/null; then
        log "==> stress-ng 编译安装完成: $(stress-ng --version 2>/dev/null | head -1)"
        return 0
    fi
    return 1
}

# 安装 stress-ng: 默认源码编译 0.20.01, 失败回退离线 0.15.00 RPM, 再回退 GNU stress / 在线源
ensure_stress_ng() {
    local SRC_TGZ="${SCRIPT_DIR}/src/stress-ng-0.20.01.tar.gz"
    local RPM_015="${SCRIPT_DIR}/rpms/stress-ng-0.15.00-1.el8.x86_64.rpm"

    # 1. 已装且版本 >= 0.20 → 直接使用
    if command -v stress-ng &>/dev/null; then
        local cur_ver
        cur_ver=$(stress-ng --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log "stress-ng 已安装: $(stress-ng --version 2>/dev/null | head -1)"
        if [ -n "$cur_ver" ] && version_ge "$cur_ver" "0.20.00"; then
            return 0
        fi
        log "[提示] 当前 stress-ng 版本 (${cur_ver:-未知}) < 0.20, 尝试升级到 0.20.01 ..."
    fi

    # 2. 默认: 源码编译安装 0.20.01 (需要 gcc + make)
    if [ -f "$SRC_TGZ" ]; then
        if command -v gcc &>/dev/null && command -v make &>/dev/null; then
            if install_stress_ng_source "$SRC_TGZ"; then
                return 0
            fi
            log "[WARN] 源码编译 0.20.01 失败, 回退离线 RPM 0.15.00 ..."
        else
            log "[提示] 未检测到 gcc/make, 无法源码编译 0.20.01, 回退离线 RPM 0.15.00"
        fi
    fi

    # 3. 回退: 离线 RPM 0.15.00 (老版, 功能完整但部分新参数缺失)
    if [ -f "$RPM_015" ]; then
        if dnf install -y "$RPM_015" &>/dev/null \
           || yum install -y "$RPM_015" &>/dev/null \
           || rpm -Uvh --replacepkgs "$RPM_015" &>/dev/null; then
            log "已安装 stress-ng 0.15.00 (离线 RPM 回退)"
            return 0
        fi
    fi

    # 4. 回退引擎: GNU stress (stress_test.sh 会自动选择)
    if command -v stress &>/dev/null; then
        log "stress-ng 不可用, 使用已就绪的 GNU stress ($(stress --version 2>/dev/null | head -1)) 作为回退引擎"
        return 0
    fi

    # 5. 在线兜底 (RHEL 8 默认仓库无 stress-ng, 需 EPEL)
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
    log "        优先: 源码编译 0.20.01 (需 gcc/make):"
    log "          tar -xzf src/stress-ng-0.20.01.tar.gz && cd stress-ng-0.20.01 && make -j\$(nproc) && make install"
    log "        备选: 有外网装 EPEL 后:"
    log "          dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm"
    log "          dnf install -y stress-ng"
    exit 1
}

install_deps() {
    log "==> 检查/安装依赖 (stress-ng, sysstat, lm_sensors, ipmitool, dmidecode)..."

    # 离线优先: 同目录存在 rpms/ 离线包且依赖未满足时, 先离线安装
    local need_offline=0
    { command -v stress-ng &>/dev/null || command -v stress &>/dev/null; } || need_offline=1
    command -v mpstat &>/dev/null || need_offline=1
    command -v sensors &>/dev/null || need_offline=1
    command -v ipmitool &>/dev/null || need_offline=1
    command -v dmidecode &>/dev/null || need_offline=1
    if [ "$need_offline" -eq 1 ] && [ -d "${SCRIPT_DIR}/rpms" ] && ls "${SCRIPT_DIR}"/rpms/*.rpm &>/dev/null; then
        install_from_offline
    fi

    # 在线兜底: 离线装完仍缺失的, 走在线源 (EPEL)
    ensure_stress_ng
    if ! command -v mpstat &>/dev/null; then
        log "安装 sysstat ..."
        dnf install -y sysstat || yum install -y sysstat || true
    fi
    # 温度/功耗/序列号工具可选, 安装失败不阻断
    command -v sensors &>/dev/null || { log "安装 lm_sensors ..."; dnf install -y lm_sensors || true; }
    command -v ipmitool &>/dev/null || { log "安装 ipmitool ..."; dnf install -y ipmitool || true; }
    command -v dmidecode &>/dev/null || { log "安装 dmidecode ..."; dnf install -y dmidecode || true; }

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

    # 采样时间延长: 压测结束后继续采样压测时长的 10%, 观察系统恢复情况
    local cooldown_sec=$(( DURATION_SEC / 10 ))
    [ "$cooldown_sec" -lt 10 ] && cooldown_sec=10
    log "压测结束, 继续采样 ${cooldown_sec} 秒 (压测时长的 10%), 观察系统恢复..."
    sleep "$cooldown_sec"

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

    # 生成报告 (传入计划压测时长与压测退出码, 用于"系统未崩溃"验收判定)
    local ts=$(date +%Y%m%d_%H%M%S)
    local html="${REPORT_DIR}/stress_report_${ts}.html"
    log "生成报告: ${html}"
    python3 "${SCRIPT_DIR}/generate_report.py" "${LATEST_CSV}" "${html}" \
        --duration "${DURATION_SEC}" --rc "${STRESS_RC}"

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
