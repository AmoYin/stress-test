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

## 四、压测时长

| 方式 | 示例 | 说明 |
|---|---|---|
| 交互回车 | 直接回车 | 默认 24 小时 |
| 交互输入 | `12h` / `90m` / `2d` / `86400` | 小时/分钟/天/秒 |
| 命令行参数 | `./run_all.sh 12h` | 非交互场景 |

非交互环境（`nohup` 后台 / SSH 断开）自动用默认 24h，不卡住。

---

## 五、产物位置

| 产物 | 路径 |
|---|---|
| 监控 CSV / 压测日志 | `/var/log/stress_test/` |
| HTML 报告 | `report/stress_report_<时间戳>.html` |

---

## 六、完整性校验

```bash
cd stress_test_full
sha256sum -c SHA256SUMS.txt   # 全部 OK 即文件完整
```

---

## 七、默认：源码编译 stress-ng 0.20.01

`run_all.sh` 默认自动从 `src/stress-ng-0.20.01.tar.gz` 编译安装 0.20.01（0.20.01 无 EL8 官方 rpm，仅源码）。

前置条件：`gcc` + `make`（**已含在 `rpms/` 离线包里，脚本会自动离线安装**）。若离线包缺失且系统无编译工具，脚本自动回退到 `rpms/` 里的 0.15.00 RPM。

手动编译（可选）：

```bash
tar -xzf src/stress-ng-0.20.01.tar.gz
cd stress-ng-0.20.01 && make -j$(nproc) && make install
```

> 核心压测（CPU/内存）编译仅需 gcc + make；缺失可选库会自动禁用对应 stressor，不影响 `--cpu` / `--vm`。
