# 系统满负载压测工具链

> 适用：任意 x86_64 服务器 / RHEL 8.x / Rocky Linux 8.x / AlmaLinux 8
> 打包日期：2026-09-03

> **本仓库说明**：GitHub 仓库仅托管脚本代码。离线 RPM 包（`rpms/`）与源码包（`src/stress-ng-0.20.01.tar.gz`）为二进制文件，未随代码入库。`run_all.sh` 启动时若找不到离线包，会自动走在线源兜底安装；需要离线包时请从原始交付包 `stress_test_full.tar.gz` 获取。

---

## 一、目录结构

```
├── run_all.sh              # 一键主控：装依赖 → 环境检查 → 压测+监控 → 出报告
├── stress_test.sh          # 压测核心（stress-ng 优先，自动回退 GNU stress）
├── monitor.sh              # 监控（每 10s 采集 CPU/内存/温度/功耗 → CSV）
├── generate_report.py      # 报告生成（纯标准库，输出 HTML 图表报告）
├── rpms/                   # 11 个离线 RPM（含全部依赖，内网可用）— 不在本仓库
├── src/
│   └── stress-ng-0.20.01.tar.gz   # 源码包（可选，需 0.20.01 时编译）— 不在本仓库
└── SHA256SUMS.txt          # 代码文件 SHA-256 校验清单
```

---

## 二、快速开始

```bash
# 方式一：仅代码（本仓库），依赖自动在线安装
git clone https://github.com/AmoYin/stress-test.git
cd stress-test
sudo bash run_all.sh          # 回车默认 24h，也可输入 12h / 30m / 2d 或秒数

# 方式二：完整离线包（含 RPM + 源码，内网可用）
tar xzf stress_test_full.tar.gz
cd stress_test_full
sudo bash run_all.sh
```

`run_all.sh` 启动时**自动先安装依赖**，安装策略如下：

1. **离线优先**：同目录存在 `rpms/` 离线包 → 先用它安装（`dnf` 本地装，失败回退 `rpm -Uvh`）
2. **在线兜底**：离线包缺失或安装失败 → 自动尝试在线源（RHEL 8 会先装 EPEL）

> 无需任何手动装包步骤，内网/离线环境也能直接跑。

---

## 三、依赖包清单（完整离线包内 11 个）

| 包 | 作用 | 是否必需 |
|---|---|---|
| `stress-ng-0.15.00` | 压测引擎（首选） | 必需 |
| `stress-1.0.4` | 压测引擎（回退） | 必需（二选一） |
| `judy-fk` | stress-ng 依赖 `libJudy.so.1`（**关键**） | 必需 |
| `libaio` | stress-ng 依赖 | 必需 |
| `libatomic` | stress-ng 依赖 | 必需 |
| `lksctp-tools` | stress-ng 依赖 | 必需 |
| `sysstat` | mpstat/sar 监控 | 可选 |
| `lm_sensors` + `lm_sensors-libs` | 温度监控 | 可选 |
| `ipmitool` | 功耗/温度（BMC） | 可选 |
| `dmidecode` | lm_sensors 依赖 | 可选 |

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
sha256sum -c SHA256SUMS.txt   # 全部 OK 即文件完整
```

---

## 七、可选：源码编译 stress-ng 0.20.01

如需新版（0.20.01 无 EL8 官方 rpm，仅源码）：

```bash
dnf groupinstall -y "Development Tools"      # gcc / make
tar -xzf src/stress-ng-0.20.01.tar.gz
cd stress-ng-0.20.01 && make -j$(nproc) && make install
```

> 核心压测（CPU/内存）编译仅需 gcc + make；缺失可选库会自动禁用对应 stressor，不影响 `--cpu` / `--vm`。
