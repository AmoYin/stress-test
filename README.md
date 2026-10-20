# 系统满负载压测工具链（脚本 + 离线软件包 融合版）

> 适用：任意 x86_64 服务器 / RHEL 8.x / Rocky Linux 8.x / AlmaLinux 8
> 打包日期：2026-09-04　|　最近更新：2026-10-20（v2.4 新增内存 ECC / EDAC 采集与判定）

---

## 一、目录结构

```
stress_test_full/
├── run_all.sh              # 一键主控：装依赖 → 环境检查 → 压测+监控 → 出报告
├── stress_test.sh          # 压测核心（stress-ng 优先，自动回退 GNU stress）
├── monitor.sh              # 监控（每 10s 采集 CPU/内存/温度/功耗/ECC 计数 → CSV）
├── generate_report.py      # 报告生成（纯标准库，输出 HTML 图表报告）
├── rpms/                   # 25 个离线 RPM（编译工具链 + 全部依赖，内网可用；stress-ng 仅作兜底）
├── src/
│   └── stress-ng-0.20.01.tar.gz   # 源码包（默认版本，安装时自动编译）
└── SHA256SUMS.txt          # 全部文件 SHA-256 校验清单
```

---

## 二、快速开始

```bash
tar xzf stress_test_full.tar.gz      # 解包后得到 stress_test_full/ 目录
cd stress_test_full
sudo bash run_all.sh          # 回车默认 24h，也可输入 12h / 30m / 2d 或秒数
```

> 若拿到的是**旧版扁平包**（解包后脚本直接铺在当前目录，没有 `stress_test_full/`），
> 不要 `cd stress_test_full`，直接 `sudo bash run_all.sh` 即可 ——
> 脚本用自身所在路径定位 `rpms/` 与 `src/`，与解包位置无关。

`run_all.sh` 启动时**自动先安装依赖**，安装策略如下：

1. **stress-ng 源码优先编译 0.20.01**：同目录存在 `src/stress-ng-0.20.01.tar.gz` → 用 `make -j$(nproc)` 多核编译安装；gcc/make 缺失时脚本先自动补装工具链（离线包优先），多核失败自动降级单核重试
2. **离线 RPM 兜底**：源码编译确实失败 → 回退 `rpms/` 里的 `stress-ng-0.15.00` RPM（其余依赖包仍离线安装）
3. **GNU stress 兜底**：再不行用 `stress` 1.0.4 作为压测引擎
4. **在线兜底**：离线包缺失或安装失败 → 自动尝试在线源（RHEL 8 会先装 EPEL）

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

内存配额取 `MemAvailable - 4GB`，在空闲机器上 `MemAvailable ≈ MemTotal`，即占用物理内存 **99.8%**。
由此触发 `global OOM`：

```
Out of memory: Killed process 86838 (stress-ng-vm) anon-rss:259081616kB, oom_score_adj:1000
```

关键在 `oom_score_adj`：stress-ng 给 **vm worker 设 +1000**、cpu worker 设 **−1000**，
内存一旦触顶，OOM Killer 必然优先杀 vm worker；vm worker 死亡后 stress-ng 判定不可恢复，
整个 24h 计划随之作废。实测单个 vm worker `anon-rss` = 247 GiB，与
`(MemAvailable-4GB) ÷ 8 workers = 248.9 GiB` 完全吻合，佐证上述推算。

### 当前策略（v2.2）

| 项 | v2.0（旧） | v2.2（新） |
|---|---|---|
| 配额基准 | `MemAvailable`（空闲时≈MemTotal） | **一律 `MemTotal`** |
| 内存配额 | `MemAvailable - 4GB`（≈99.8%） | `min(MemTotal × 90%, MemAvailable - 8GB)` |
| 单 worker 分配上限 | 256 GB | 128 GB（单次 mmap 更小，成功率更高） |
| OOM 规避 | 无 | 自动追加 `--oom-avoid`（版本支持时） |
| OOM 预算核算 | 无 | 启动时按 `配额 × 1.09` 估算峰值并预警 |
| 提前退出 | 直接终止，24h 计划作废 | 自动降配 5% 重启，直至跑满计划时长 |

**为什么默认 90% 而不是 95%：** 实测单 vm worker 的 `anon-rss` 比理论配额高约 **9%**（额外 `calloc`、页表、`vm_swap` 开销）。以 2003 GiB 机器为例：

| VM_MEM_PCT | 配额 | 峰值估算（×1.09） | 是否安全 |
|---|---|---|---|
| 99.8（旧） | 1999 GB | 2179 GB | ❌ global OOM，vm worker 被 kill |
| 95 | 1903 GB | 2075 GB | ⚠️ 需吃掉全部 128 GB swap 才不 OOM |
| **90（默认）** | **1803 GB** | **1965 GB** | ✅ 留在物理内存内，余 38 GB + swap 兜底 |
| 85（保守） | 1703 GB | 1855 GB | ✅ 余 148 GB，内存硬件可疑时推荐 |

> 不建议依赖 swap 兜底：换页抖动会显著拖慢 `--vm-method` 的访问速率，使"满载"失真。
> 纯内存稳定性压测建议压测前 `swapoff -a` 并配合 `VM_MEM_PCT=85`。

自愈流程：某轮未跑满即退出 → 清理残留进程 → 内存配额 −5% → 10 秒后重启下一轮，
配额降至 70% 下限仍失败则停止并报错（提示检查内存硬件 / EDAC）。

### 可调环境变量

```bash
VM_MEM_PCT=90         # 占用物理内存比例上限 (%)，默认 90，建议范围 85~90
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

### 单独/补生成报告

CSV 内嵌了 CPU 型号、SN、OS、计划时长等元数据，因此**脱离服务器也能重新出报告**，
不会显示 "未知 CPU / N/A"：

```bash
python3 generate_report.py /var/log/stress_test/monitor_20260915_150556.csv report.html \
    --duration 86400      # 计划压测秒数（缺省时读 CSV 元数据 plan_duration_hours）
    --rc 1                # 压测退出码（0=正常跑满；非 0 标记"压测异常退出"）
    --note "备注结论，支持 \n 换行"   # 可选，渲染为报告顶部的"备注/结论"卡片
    --stress-log stress_20260915_150556.log   # 可选，抽取 bogo ops / passed / failed 进报告
    --base-freq 2450      # 可选，离线生成报告时指定基础频率(MHz)，用于降频判定
```

报告端统计口径（v2.6 起）：默认**剔除首尾空载过渡样本**后计算 min/avg/max 与判定
（压测启动前的空闲点、结束后的降温点）。采样点稀疏时（见 9.6）这两个点足以把
平均值拉低 5~10 个百分点，把一次满载通过的压测误判成 "未达标"；图表仍画完整窗口，
`--no-steady` 可恢复旧行为（不剔除）。被压测机上没装 python3 时，把 CSV 拷回
办公机执行即可 —— 纯标准库，无第三方依赖。

---

## 七、完整性校验

```bash
cd stress_test_full
sha256sum -c SHA256SUMS.txt   # 全部 OK 即文件完整
```

---

## 八、默认且优先：源码编译 stress-ng 0.20.01

`run_all.sh` 的 stress-ng 安装优先级（源码优先，逐级回退）：

| 优先级 | 路径 | 触发条件 |
|---|---|---|
| 1 | **源码编译 0.20.01**（`make -j$(nproc)`） | 存在 `src/stress-ng-0.20.01.tar.gz`；gcc/make 缺失时脚本会先自动补装工具链 |
| 2 | 离线 RPM `stress-ng-0.15.00` | 源码编译失败，或工具链确实装不上 |
| 3 | GNU `stress` 1.0.4 | 上述都不可用 |
| 4 | 在线源 / EPEL | 有外网时兜底 |

> 0.20.01 无 EL8 官方 rpm，只能源码编译，因此**源码路径即默认路径**；已装版本 ≥ 0.20 时跳过编译。

### 编译细节

- **多核加速**：`make -j$(nproc)`（256 核机器上约 1–2 分钟内完成）
- **并发度可调**：`MAKE_JOBS=4 bash run_all.sh 24 -d`（小内存机器避免编译期 OOM）
- **强制重编译**：`FORCE_SOURCE=1 bash run_all.sh 24 -d`（已装 ≥0.20 也重新编译）
- **失败自动降级**：`make -j$(nproc)` 失败 → 自动 `make clean && make -j1` 单核重试（排除并发 race / 编译期内存不足）
- **日志落盘**：`/var/log/stress_test/build_stress_ng.log`；失败时终端打印尾部 25 行报错，源码目录保留供排查
- **源码目录定位（v2.5 修复）**：解压到临时目录后按「含 `Makefile` 的顶层目录」识别源码根，
  不依赖目录名与压缩包名一致；解压后找不到 `Makefile` 会打印顶层内容并明确报错，
  不再静默回退 RPM。启动日志会打印 `源码目录: ...` 与 `构建步骤: cd ... && make -jN`，
  可直接确认到底进了哪个目录。

前置条件：`gcc` + `make`（**已含在 `rpms/` 离线包里，脚本会自动离线安装**）。若离线包缺失且系统无编译工具，脚本自动回退到 `rpms/` 里的 0.15.00 RPM。

手动编译（可选）：

```bash
tar -xzf src/stress-ng-0.20.01.tar.gz
cd stress-ng-0.20.01 && make -j$(nproc) && make install
```

> 核心压测（CPU/内存）编译仅需 gcc + make；缺失可选库会自动禁用对应 stressor，不影响 `--cpu` / `--vm`。

---

## 九、常见现场问题

### 9.1 系统时间不对（日志显示 2018 年等）

**现象**：`tar` 解包刷屏 `time stamp ... is ... s in the future`；压测日志、CSV、HTML 报告的时间全部错误。

**原因**：CMOS 电池失效或未配置 NTP，系统时钟回退到出厂年份。

**处理**（压测前务必先做）：

```bash
date                                  # 确认当前时间
date -s "2026-09-22 14:00:00"         # 手动对时
chronyc -a makestep                   # 或走 chrony
ntpdate -u 192.168.1.1                # 或走 ntpdate
hwclock -w                            # 写回硬件时钟，重启不丢
```

脚本已在环境检查阶段增加时钟校验，年份 < 2020 会打印 `[WARN]` 与对时建议。

> 若暂不能对时，解包时加 `-m` 可消除时间戳告警（用当前时间代替包内 mtime）：
> `tar -zxf stress_test_full.tar.gz -m`

### 9.2 gcc 离线装不上（libgcc / libgomp 版本冲突）

**现象**：

```
error: Failed dependencies:
        libgcc >= 8.5.0-28.el8_10 is needed by gcc-8.5.0-28.el8_10.x86_64
        libgomp = 8.5.0-28.el8_10 is needed by gcc-8.5.0-28.el8_10.x86_64
```

**根因**：系统已装 `libgcc/libgomp-8.5.0-21.el8`，离线包是 `8.5.0-28.el8_10`。
旧版脚本只要 `rpm -q <name>` 命中就跳过，导致低版本库原地不动，gcc 的依赖永远无法满足。
另：`rpm -ivh` 是"安装"，遇到同包旧版本会报文件冲突，必须用 `-Uvh`（升级）。

**v2.3 已修复**：同名包只在「版本-发行号完全一致」时才跳过，否则走 `-Uvh --replacepkgs` 升级；
并对互依赖包（`libgcc` + `libgomp` 需同事务升级）增加批量升级兜底。

**手工解法**（老版本脚本）：

```bash
cd rpms
rpm -Uvh --replacepkgs libgcc-8.5.0-28.el8_10.x86_64.rpm libgomp-8.5.0-28.el8_10.x86_64.rpm
rpm -Uvh gcc-8.5.0-28.el8_10.x86_64.rpm
gcc --version
```

### 9.3 judy-fk / stress-ng-0.15.00 依赖 libJudy.so.1 未满足

`dnf` 报 `nothing provides libJudy.so.1()(64bit)`，导致 0.15.00 RPM 装不上。
**不影响**：只要 `gcc` + `make` 就位，脚本会走**源码编译 0.20.01**（默认路径），
`libJudy` 属可选增强，缺失只禁用对应 stressor，CPU/内存满载压测不受影响。

### 9.4 EDAC 计数全是 N/A（没采到 ECC）

**现象**：`monitor.sh` 启动时打印 `[WARN] 未检测到 EDAC (...)`，报告里“内存无 CE / UE”显示 `未采集`。

**原因**：内核未加载 EDAC 驱动，或该平台上 EDAC 只暴露在 `rasdaemon` 侧。

**处理**：

```bash
ls /sys/devices/system/edac/mc/            # 空 = 未加载
modprobe edac_mce_amd                      # AMD EPYC
modprobe skx_edac                          # Intel Skylake-SP 及以后
rasdaemon -r -d                            # 兜底：rasdaemon 记录机制
ls /sys/devices/system/edac/mc/mc0/        # 应出现 ce_count / ue_count / dimm*
```

> 建议写入 `/etc/modules-load.d/edac.conf` 永久生效。
> EDAC 不可用时脚本只降级为 N/A，其余指标采集与压测不受影响。

### 9.5 源码包明明在，却装成了 RPM 0.15.00

**现象**：`src/stress-ng-0.20.01.tar.gz` 存在、`gcc`/`make` 也在，但日志里出现
`[WARN] stress-ng 编译失败` 后紧接着 `已安装 stress-ng 0.15.00 (离线 RPM 回退)`；
`build_stress_ng.log` 内容只有一行 `### ... make -jN (源码: /tmp/stress-ng-build.xxxx)`，
报错是 `make: *** No targets specified and no makefile found.  Stop.`

**根因（v2.3 及更早）**：定位源码目录用的是
`find "$build_dir" -maxdepth 1 -type d -name 'stress-ng-*' | head -1`，
而构建目录本身由 `mktemp -d /tmp/stress-ng-build.XXXXXX` 创建，**目录名就匹配 `stress-ng-*`**。
`find` 会把起始目录按 depth 0 参与匹配并**先**输出它，`head -1` 取到的就是空的构建目录，
于是 `make` 在没有 Makefile 的目录里跑，必然失败并回退 RPM。

**v2.5 修复**：`-mindepth 1` 排除起始目录；构建目录改名 `sng-build.XXXXXX`；
源码根改为「含 `Makefile` 的顶层目录」判定；找不到 Makefile 时打印顶层内容并报错退出。

**现场自证**（无需重装即可判断走的是哪条路）：

```bash
grep -n "源码目录\|构建步骤" /var/log/stress_test/build_stress_ng.log
stress-ng --version                     # 期望 0.20.01；若为 0.15.00 说明走的 RPM 回退
ls -d /tmp/stress-ng-build.* 2>/dev/null # v2.3 遗留的失败构建目录
rpm -q stress-ng                        # 若装着 0.15.00 且 /usr/bin/stress-ng 是 0.20.01, 属正常覆盖
```

强制走源码重编译：

```bash
FORCE_SOURCE=1 sudo bash run_all.sh 24 -d
```

### 9.6 采样间隔从 10s 退化到 2 分钟以上（满负载下才出现）—— v2.6 已修复

**现象**：CSV 实际采样间隔远大于配置的 10s（如 1 小时只有 20~30 个点），
`monitor_console.log` 里两行输出相隔 2 分钟以上。**只在 CPU 满载时出现**，
空载复测间隔正常。2026-10-20 在 R4950 G5 上实测：10s → 平均 139s，1 小时仅 27 个点。

**根因**：`get_power()` 用 `ipmitool sensor` 拉取**全量传感器表**（双路机器数百项：
128 个 Ecore 能量、全部 DIMM 温度、风扇等）。满负载下 BMC 的 KCS 接口与 OS 争抢 CPU，
`ipmitool sensor` 从空载的 ~1s 退化到 1~2 分钟，整个采样循环被这一条命令拖住。

**v2.6 修复**（`monitor.sh`，四个层次）：

| 改动 | 作用 |
|---|---|
| 功耗改走 `ipmitool dcmi power reading` | 单次 IPMI 请求，毫秒级；DCMI 不支持才回退全量 `sensor` |
| 每条采集命令加硬超时 `_tmo`（`CMD_TIMEOUT`，默认 10s，`-s KILL`） | 任何一条命令挂死都不再阻塞整轮 |
| 采集方式缓存到 `$LOG_DIR/.power_method` | 探测只做一次；失败即降级 N/A，不再每轮重试 |
| 每轮记录采集耗时，超阈值告警并指名慢环节 | 现场自证，不用再猜 |

顺带修掉一个被间隔退化放大的统计错误：`cs_rate` 原来用固定 `INTERVAL` 做除数，
间隔被拉长到 139s 时算出的 CS/s **虚高 14 倍**（实测把 1.8k 报成了 24.9k），
现改为按相邻两个采样点的真实时间差计算。

**验证方法**（跑起来看这三处）：

```bash
head -3 /var/log/stress_test/monitor_console.log
# 期望: 功耗采集方式: ipmitool dcmi power reading (单次请求, 毫秒级)

grep '采集耗时' /var/log/stress_test/monitor_console.log | head -3
# 期望: 采集耗时: 十几~几十 ms (而不是 120000ms 级别)

awk -F, 'NR>7{print $1-p; p=$1}' monitor_*.csv | sort -n | tail -1
# 期望: 实际间隔 ≈ 配置的 10s
```

**老版本（v2.5 及之前）的临时规避**：`POWER_METHOD=none` 环境变量直接跳过功耗采集
（CSV 功耗列记 N/A，其余指标照常），或手工把 `get_power()` 里的 `ipmitool sensor`
换成 `ipmitool dcmi power reading`。若 `dcmi` 也不可用，用单点读取加超时：

```bash
ipmitool -N 2 -R 1 sensor get "PSU1 Pwr"
```

---

## 十、内存 ECC（EDAC）采集与判定（v2.4 新增）

### 10.1 为什么要把 ECC 纳入验收

“24h 跑满、系统没挂”只证明**系统没有崩溃**，不证明**内存没有出错**。
持续发生的 ECC 可纠正错误（CE）可以在不影响业务的前提下存在一整晚，
一份判定“通过”的报告会把正在劣化的内存条判成好件，装回客户机器上继续用。

典型现场：H3C R4950 G5（双路 EPYC 7763 + 2TB）在 24h 内存压测中，
`CPU0 channel5（CFD1 槽位）`持续以约 13.5 CE/小时 的速度增长，而 CPU/内存利用率曲线
全程漂亮、无 OOM、无宕机 —— 若只看利用率与温度，这台机器会被判“通过”。

### 10.2 采集来源

| 层级 | sysfs 路径 | 用途 |
|---|---|---|
| 控制器 | `mc/mc*/ce_count`、`mc*/ue_count` | 总量统计（CSV 主字段） |
| DIMM | `mc*/dimm*/dimm_ce_count`、`dimm_ue_count`（新驱动） | 精确定位到具体内存条 |
| 行/通道 | `mc*/csrow*/ce_count`（老驱动兜底） | 无 DIMM 视图时的替代定位 |

新增 CSV 字段（追加在末尾，**向后兼容旧报告**）：

| 字段 | 含义 |
|---|---|
| `edac_ce_total` | CE 累计计数（全控制器求和） |
| `edac_ue_total` | UE 累计计数 |
| `edac_ce_delta` | 本次采样新增 CE（首个采样点为 N/A） |
| `edac_ue_delta` | 本次采样新增 UE |
| `edac_loc` | 受影响位置摘要，按 CE 降序取前 3，如 `mc0/dimm3:1204;mc1/dimm5:16` |

CSV 元数据同时写入 `# edac_available: 0/1` 与 `# edac_mc_count`，
报告据此区分“**0 次错误**”与“**根本没采到**”——这两者在验收上天差地别，不能混为一谈。

### 10.3 判定口径

| 检查项 | 通过 | 告警 | 失败 |
|---|---|---|---|
| 内存无 UE（不可纠正） | 绝对计数 = 0 | — | 绝对计数 ≥ 1（含历史遗留） |
| 内存无 CE（可纠正） | 本次新增 = 0 | 本次新增 ≥ 1 | — |

- **UE 按绝对计数判失败**：UE 计数器自开机累计，压测窗口内读到 >0 就说明本机已发生过
  不可纠正错误。即使本次 24h 无新增（历史遗留），数据完整性风险仍在，不判通过。
- **CE 按增量判告警**：历史累计 CE 可能是几个月前遗留、已做过更换或隔离，不构成本次劣化；
  “本轮只增不减”才是现行问题。绝对值仅作提示文案出现。
- **未采集**：显示灰色 `未采集`，不判通过（不允许“没测”被当成“通过”）。

报告中的呈现：KPI 卡片 `内存 CE / UE 累计`、独立曲线图 `内存 ECC 错误累计 (EDAC)`、
关键指标汇总 4 行（CE/UE 累计与新增的 min/avg/max）、稳定性判定 2 行、以及
`ECC 错误定位（EDAC）` 卡片（列出 CE 最集中的控制器/DIMM）。

### 10.4 怎么读定位结果

| 定位形态 | 优先怀疑 |
|---|---|
| CE 集中在单个 `dimm*` | 该条内存（直接替换复测） |
| 分散在同一 `mc*` 的多个 DIMM | 该侧 CPU 的内存通道 / 插槽 |
| 多个 `mc*` 同时持续增长 | 内存批次、散热或供电（VDIMM/PMIC） |
| CE 与温度峰值在时间上同步 | 散热/风道问题，而非颗粒本身 |

> 判定“CE 集中”要看**增量**而不是累计值：累计 1200 次但 24h 内增量为 0，说明是历史遗留、
> 已被替换或隔离过，本次不算劣化；累计 0 但增量 800，才是本次压测抓到的现行问题。

---

## 十一、版本记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v2.0 | 2026-09-04 | 首个融合版：离线 RPM + 源码包 + 监控 + HTML 报告 |
| v2.1 | 2026-09-16 | 修复长跑提前退出（内存配额改为 `min(MemTotal×PCT, MemAvailable-RESERVE)`）；新增自愈降配重试 |
| v2.2 | 2026-09-16 | 依 hpc13 现场 OOM 证据把默认配额由 95% 下调至 90%，新增 OOM 预算核算与四档安全对比 |
| v2.3 | 2026-09-22 | 同名 RPM 按「版本-发行号」判定是否跳过，修复 gcc 依赖永远无法满足；新增 `--note` 报告备注卡片 |
| v2.4 | 2026-10-20 | 新增内存 ECC（EDAC）采集与报告判定（CE/UE 曲线、定位卡片、判定 2 行） |
| v2.5 | 2026-10-20 | **修复源码安装目录定位 bug**：`mktemp` 构建目录名匹配 `stress-ng-*`，`find` 把起始目录自己当成源码目录 → 在空目录 `make` 失败 → 静默回退 RPM 0.15.00。改为 `-mindepth 1` + 按 `Makefile` 判定 + 明确报错；`SHA256SUMS.txt` 改为覆盖全部文件（含 rpms/src）并统一 LF |
| v2.6 | 2026-10-20 | **修复采样间隔退化（10s → 139s）**：功耗改走 `ipmitool dcmi power reading`（单请求）+ 每条采集命令硬超时 `_tmo`（`-s KILL`）+ 采集方式落盘缓存 + 每轮采集耗时告警并指名慢环节。顺带修复 `cs_rate` 用固定 `INTERVAL` 做除数导致间隔退化时虚高 14 倍。报告端新增：稳态窗口统计（剔除首尾空载点，`--no-steady` 可关）、`--stress-log` 抽取 bogo ops / passed / failed 成卡片、`--base-freq` 及读不到基频时改判「无法判定」 |

### v2.6 新增环境变量（monitor.sh）

| 变量 | 默认 | 说明 |
|---|---|---|
| `CMD_TIMEOUT` | 10 | 单条采集命令硬超时（秒），超时即杀并降级 |
| `POWER_METHOD` | auto | `auto` / `dcmi` / `sensor` / `none`，置 `none` 完全跳过功耗采集 |
| `SLOW_WARN_MS` | 5000 | 单轮采集耗时告警阈值（毫秒） |
| `INTERVAL` | 10 | 采样间隔（秒），仍是第 1 个位置参数 |

