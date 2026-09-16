# 系统满负载压测工具链（脚本 + 离线软件包 融合版）

> 适用：任意 x86_64 服务器 / RHEL 8.x / Rocky Linux 8.x / AlmaLinux 8
> 打包日期：2026-09-04

---

## 一、目录结构

```
stress_test_full/
├── run_all.sh              # 一键主控：装依赖 → 环境检查 → 压测+监控 → 出报告
├── stress_test.sh          # 压测核心（stress-ng 优先，自动回退 GNU stress）
├── monitor.sh              # 监控（每 10s 采集 CPU/内存/温度/功耗 → CSV）
├── generate_report.py      # 报告生成（纯标准库，输出 HTML 图表报告）
├── rpms/                   # 25 个离线 RPM（编译工具链 + 全部依赖，内网可用；stress-ng 仅作兜底）
├── src/
│   └── stress-ng-0.20.01.tar.gz   # 源码包（默认版本，安装时自动编译）
└── SHA256SUMS.txt          # 全部文件 SHA-256 校验清单
```

---

## 二、快速开始

```bash
tar xzf stress_test_full.tar.gz
cd stress_test_full
sudo bash run_all.sh          # 回车默认 24h，也可输入 12h / 30m / 2d 或秒数
```

`run_all.sh` 启动时**自动先安装依赖**，安装策略如下：

1. **stress-ng 默认编译 0.20.01**：同目录存在 `src/stress-ng-0.20.01.tar.gz` 且系统有 gcc/make → 自动源码编译安装
2. **离线 RPM 兜底**：编译失败或无 gcc/make → 回退 `rpms/` 里的 `stress-ng-0.15.00` RPM（其余依赖包仍离线安装）
3. **在线兜底**：离线包缺失或安装失败 → 自动尝试在线源（RHEL 8 会先装 EPEL）

> 无需任何手动装包步骤，内网/离线环境也能直接跑。

---

## 三、依赖包清单（rpms/ 内 25 个）

### 编译工具链（源码编译 stress-ng 0.20.01 必需，14 个）

| 包 | 作用 |
|---|---|
| `gcc-8.5.0` + `cpp-8.5.0` | C 编译器 + 预处理器 |
| `make-4.2.1` | 构建工具 |
| `binutils-2.30` | 汇编器 / 链接器 |
| `libgcc-8.5.0` + `libgomp-8.5.0` | gcc 运行库 |
| `libmpc` + `mpfr` + `gmp` + `isl` | gcc 编译数学库依赖 |
| `glibc-devel` + `glibc-headers` | C 头文件 + 链接脚本（编译必需） |
| `kernel-headers` | 内核头文件（编译必需） |
| `libxcrypt-devel` | glibc-devel 依赖 |

> 开发头文件包（glibc-devel / glibc-headers / libxcrypt-devel）精确依赖同版本 glibc 主包；脚本用 `--nodeps` 兜底安装（编译用头文件在 glibc 2.28 各小版本间 ABI 兼容），**不会升级系统 glibc 主包**。

### 压测引擎与监控（11 个）

| 包 | 作用 | 是否必需 |
|---|---|---|
| `stress-ng-0.15.00` | 压测引擎（离线 RPM 兜底；默认用源码编译 0.20.01） | 二选一 |
| `stress-1.0.4` | 压测引擎（最终回退） | 二选一 |
| `judy-fk` | stress-ng 依赖 `libJudy.so.1`（**关键**） | 必需 |
| `libaio` | stress-ng 依赖 | 必需 |
| `libatomic` | stress-ng 依赖 | 必需 |
| `lksctp-tools` | stress-ng 依赖 | 必需 |
| `sysstat` | mpstat/sar 监控 | 可选 |
| `lm_sensors` + `lm_sensors-libs` | 温度监控 | 可选 |
| `ipmitool` | 功耗/温度（BMC） | 可选 |
| `dmidecode` | 序列号读取 / lm_sensors 依赖 | 可选 |

> `generate_report.py` 纯标准库，无三方依赖；`top/free/nproc/awk` 系统自带。

---

## 四、压测时长与后台运行

时长统一按**小时**输入，范围 **0.1 ~ 48 小时**（支持小数，如 `0.5` = 30 分钟）。

| 方式 | 命令 | 行为 |
|---|---|---|
| 交互输入 | `sudo bash run_all.sh` | 提示输入时长（回车默认 24），需键入 `y` 确认 |
| 指定时长 | `sudo bash run_all.sh 24` | 直接开始 24 小时，**跳过确认**（视为显式意图） |
| 后台守护 | `sudo bash run_all.sh 24 -d` | 脱离 SSH 会话后台运行，**断开终端不中断**（推荐） |

### 后台守护模式（`-d` / `--daemon`）

以 `setsid` + `nohup` 重启自身并脱离当前终端会话，父进程立即返回，
SSH 断开、网络闪断均不影响压测继续。

```bash
sudo bash run_all.sh 24 -d        # 后台跑 24 小时，立即回到命令提示符
```

常用命令：

```bash
tail -f /var/log/stress_test/run_all_daemon.log    # 实时查看进度
cat /var/log/stress_test/run_all.pid               # 查看守护进程 PID
kill $(cat /var/log/stress_test/run_all.pid)       # 停止压测
# 强制清理
pkill -f run_all.sh; pkill -f monitor.sh; pkill -f stress-ng
```

> 说明：带时长参数时视为显式意图，不再二次确认；非交互环境（无终端）同样跳过确认。
> 因此 `nohup` / 定时任务 / 自动化调用都不会因「默认 n 取消」而空跑退出。

---

## 五、内存配额策略（防止 vm worker 提前退出）

### 现象（v2.0 及更早版本）

```
stress-ng: fail:  [86833] vm: calloc failed on vm_swap
stress-ng: error: [98379] vm: gave up trying to mmap, no available memory
stress-ng: warn:  [86826] vm: WARNING: finished prematurely after just 9321.15s (2 hours, 35 mins, 21.15 secs)
```

### 根因

内存配额取 `MemAvailable - 4GB`，在 2TB 机器上相当于占用物理内存 **99.8%**。
压测持续数小时后，内核 slab、页缓存、THP、监控进程以及 stress-ng 自身的
额外 `calloc`（`vm_swap` 等）已无余量可用，vm worker 的 `mmap` 返回 `ENOMEM`，
stress-ng 判定为不可恢复错误后提前终止整个压测进程。

### 当前策略（v2.1）

| 项 | v2.0（旧） | v2.1（新） |
|---|---|---|
| 内存配额 | `MemAvailable - 4GB`（≈99.8%） | `min(MemTotal × 95%, MemAvailable - 8GB)` |
| 单 worker 分配上限 | 256 GB | 128 GB（单次 mmap 更小，成功率更高） |
| OOM 规避 | 无 | 自动追加 `--oom-avoid`（版本支持时） |
| 提前退出 | 直接终止，24h 计划作废 | 自动降配 5% 重启，直至跑满计划时长 |

自愈流程：某轮未跑满即退出 → 清理残留进程 → 内存配额 −5% → 10 秒后重启下一轮，
配额降至 70% 下限仍失败则停止并报错（提示检查内存硬件 / EDAC）。

### 可调环境变量

```bash
VM_MEM_PCT=95         # 占用物理内存比例上限 (%)，默认 95
RESERVE_GB=8          # 至少保留给系统的内存 (GB)，默认 8
VM_WORKER_MAX_GB=128  # 单个 vm worker 最大分配量 (GB)，默认 128
VM_MEM_PCT_MIN=70     # 自愈降配下限 (%)，默认 70
VM_MEM_PCT_STEP=5     # 每轮自愈降配步长 (%)，默认 5
AUTO_RETRY=1          # 提前退出是否自动降配重启 (1/0)，默认 1
VM_METHOD=            # 指定 stress-ng --vm-method，留空为默认 all

# 示例：内存硬件可疑、需要更保守的场合
sudo VM_MEM_PCT=85 AUTO_RETRY=1 bash run_all.sh 24 -d
```

---

## 六、产物位置

| 产物 | 路径 |
|---|---|
| 监控 CSV / 压测日志 | `/var/log/stress_test/` |
| 守护模式运行日志 | `/var/log/stress_test/run_all_daemon.log` |
| 守护进程 PID 文件 | `/var/log/stress_test/run_all.pid` |
| HTML 报告 | `report/stress_report_<时间戳>.html` |

---

## 七、完整性校验

```bash
cd stress_test_full
sha256sum -c SHA256SUMS.txt   # 全部 OK 即文件完整
```

---

## 八、默认：源码编译 stress-ng 0.20.01

`run_all.sh` 默认自动从 `src/stress-ng-0.20.01.tar.gz` 编译安装 0.20.01（0.20.01 无 EL8 官方 rpm，仅源码）。

前置条件：`gcc` + `make`（**已含在 `rpms/` 离线包里，脚本会自动离线安装**）。若离线包缺失且系统无编译工具，脚本自动回退到 `rpms/` 里的 0.15.00 RPM。

手动编译（可选）：

```bash
tar -xzf src/stress-ng-0.20.01.tar.gz
cd stress-ng-0.20.01 && make -j$(nproc) && make install
```

> 核心压测（CPU/内存）编译仅需 gcc + make；缺失可选库会自动禁用对应 stressor，不影响 `--cpu` / `--vm`。
