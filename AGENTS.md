# AGENTS.md — flashfox-lite-flake

闪狐云 Lite（机场代理客户端）的 Nix 打包仓库。闭源 deb vendor 进 `vendor/`，
纯 flake 构建。唯一权威事实来源：**TUN-RESEARCH.md §15（3.0.6 TUN 方案）与 §17
（3.2.1 升级复盘，以 §17 为准）**。本文件只讲"怎么动这个仓库"，机制细节一律
先读 TUN-RESEARCH.md 再动手。

## 硬性规则

- 不要手动跑 `nix build`/`nix flake check`/`nix eval` 对本仓库做构建验证：
  用户在自己机器上执行最终构建与切换；本仓改动后由用户 rebuild + 实测。
- 访问 GitHub 用 `gh`/`git`，禁止裸 `curl` 请求 GitHub API/raw。
- 注释用中文；改动保持现有结构（`package.nix` 单文件 + flake.nix 模块）。
- **闭源 deb**：所有行为推断必须基于解包/readelf/strings/运行时实测，禁止
  凭"应该如此"下结论。升级版本前先静态拆包对比（见下"升级 deb"）。

## 仓库结构

```
flake.nix        # 输出:packages / checks / overlays / nixosModules / homeModules
package.nix      # 打包:deb 解包 → /opt bundle → $out/share;wrapProgram 注入环境;tunSupport 布局
vendor/          # 官方 deb(版本泛化引用 FlashFoxLite-${version}-linux-amd64.deb)
README.md        # 用户向文档(快速开始/验证/升级步骤)
TUN-RESEARCH.md  # 调研与复盘:§15 3.0.6 最终方案、§17 3.2.1 升级复盘
AGENTS.md        # 本文件
```

## 关键机制（改动前必读对应章节）

### TUN 布局（tunSupport=true,供 nixosModules 使用）

- **执行链**：GUI fork `share/FlashFoxLite/FlashFoxLiteCore`（0755 跳板脚本）
  → `exec /run/wrappers/bin/flashfox-core`（NixOS security.wrappers 生成的
  setuid root wrapper）→ `FlashFoxLiteCore.bin`（真 mihomo 内核,root 运行）
- **免密**：NixOS 模块 `flashfox-core-mount.service` 把 wrapper
  `mount --bind` 到 Core 原路径，闪狐 lstat 该路径看到 root:root+rws 即免弹
  密码框（bind 在 suid-sgid-wrappers.service 之后）
- **假 sudo**：`libexec/flashfox-fake-sudo/sudo` 吞掉含 FlashFoxLiteCore 的
  chown/chmod（只读 store 上必然失败且是 no-op），其余 sudo 原样放行
- **fix-device**：`libexec/flashfox-fix-device` 在 GUI 每次启动前
  （wrapProgram `--run`）把 TUN 设备名幂等改为 `Meta`
  —— ⚠ 路径必须是 **`$HOME/.local/share/com.ffclient.app/shared_preferences.json`**
  （3.2.1 起目录从 `ffclient.app` 迁到 `com.ffclient.app`；写错目录曾引发
  设备名修正失效 + 系统残留 TUN + 系统代理 7892 国外全挂的连环故障，§17.2）
- NixOS 模块配套：`boot.kernelModules=["tun"]`、`security.wrappers`、
  防火墙 `trustedInterfaces=["Meta"]`、`checkReversePath="loose"`

### GUI 运行时环境（package.nix postFixup,职责划分勿乱删）

| 注入 | 用途 |
|---|---|
| PATH: glib.bin | `gsettings` 命令（设置系统代理） |
| PATH: xdg-user-dirs | `xdg-user-dir`（path_provider,缺失启动崩溃） |
| PATH: 假 sudo（tun） | 吞提权命令 |
| LD_LIBRARY_PATH | libsecret（3.2.1 deb Depends,dlopen 裸名）与 bundle lib 兜底 |
| FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR | **librust_api.so 加载**（flutter_rust_bridge 官方覆盖点;不加则 GUI 启动即崩,LD_LIBRARY_PATH 不够,§17.4） |
| GSETTINGS_SCHEMA_DIR | gsettings CLI 读 org.gnome.system.proxy（nixpkgs schema 目录已迁到 share/gsettings-schemas/<pkg>/glib-2.0/schemas;不加则"没有安装架构",§17.3） |

### 数据目录（排障第一查这里）

GUI/Core 运行时数据在 `~/.local/share/com.ffclient.app/`：
`shared_preferences.json`（明文,含 `flutter.config` 内嵌 JSON 字符串,
`patchClashConfig.tun.device` 是 fix-device 修正目标）、`config.yaml`（加密）、
`profiles/*.dat`（订阅,加密）、`system_proxy_active.marker`。
GUI 进程实际用的目录以 `/proc/<pid>/fd` 为准——**不要凭旧文档猜**。

## 升级 deb 流程（3.2.1 起不止改版本号）

1. 替换 `vendor/FlashFoxLite-<新版本>-linux-amd64.deb`，改 `package.nix` version
2. 静态拆包对比（新/旧都要）：`dpkg-deb -c/-I` 看 bundle 路径（3.0.6 在
   `usr/share/FlashFoxLite`，3.2.1 在 **`opt/FlashFoxLite`**）、插件 .so 列表、
   NEEDED（`readelf -d`）、depends
3. 新 dlopen 库（无 NEEDED）→ buildInputs + LD_LIBRARY_PATH；新裸名 dlopen
   （如 librust_api）→ 按 §17.4 机制处理
4. **核对数据目录是否再迁移**（看 desktop `StartupWMClass` / `~/.local/share`
   新目录）→ fix-device 路径同步
5. strings 对比 GUI 提权协议（`sudo`/`chown root:root`/`FlashFoxLiteCore`），
   变了要重新评估 §15 四件套
6. 用户 rebuild + 实测：系统代理单独、TUN 单独、两者同时，三条路径都要过

## 实测过的行为基线（3.2.1,2026-09-10）

- TUN 直连 google/baidu 200；7892 走 google 302/youtube 200/baidu 200
- 系统代理与 TUN **可同时开**，互不干扰（前提:无残留 TUN 状态）
- Core 以 root 跑（Uid 1000/0/0/0）、`FlashFoxLiteCore` 路径
  `root:root -rws--x--x`、开 TUN 免密
- 7892 走国外全挂时先查:残留 `Meta` 接口/2022 路由表/9000-9010 ip rule
  （清理:`ip link del Meta` + `ip rule del pref 900x...` + `ip route flush table 2022`）
