# AGENTS.md — flashfox-lite-flake

闪狐云 Lite（机场代理客户端）的 Nix 打包仓库。闭源 deb vendor 进 `vendor/`，纯 flake
构建。**本文件是仓库日常维护的唯一入口**：机制原理、版本差异、排障命令、升级流程都在
这里，改代码/排障先读本文件。
（完整历史调研档案见 [TUN-RESEARCH.md](./TUN-RESEARCH.md)：3.0.6 时代全部尝试过程、
原始诊断数据、被推翻的假设。日常不需要读它；只有遇到新版本/新问题、需要对照"以前
见过的现象"时再翻。两文件的重复信息以本文件为准。）

## 硬性规则

- 不要手动跑 `nix build`/`nix flake check`/`nix eval` 对本仓库做构建验证：
  用户在自己机器上执行最终构建与切换；本仓改动后由用户 rebuild + 实测。
- 访问 GitHub 用 `gh`/`git`，禁止裸 `curl` 请求 GitHub API/raw。
- 注释用中文；改动保持现有结构（`package.nix` 单文件 + flake.nix 模块）。
- **闭源 deb**：所有行为推断必须基于解包/readelf/strings/运行时实测，禁止凭
  "应该如此"下结论。升级版本前先静态拆包对比（见下"升级 deb"）。
- **排障铁律**：GUI 进程实际用的数据目录以 `/proc/<pid>/fd` 为准，不要凭旧文档
  或旧记忆猜（3.0.6→3.2.1 就发生过目录迁移引发的连环故障，见下）。

## 仓库结构

```
flake.nix        # 输出:packages / checks / overlays / nixosModules / homeModules
package.nix      # 打包:deb 解包 → /opt bundle → $out/share;wrapProgram 注入环境;tunSupport 布局
vendor/          # 官方 deb(版本泛化引用 FlashFoxLite-${version}-linux-amd64.deb)
README.md        # 用户向文档(快速开始/验证/升级步骤)
AGENTS.md        # 维护入口(机制/原理/排障/版本史,日常读这个)
TUN-RESEARCH.md  # 历史调研档案(3.0.6 排障全程原始记录,可选查阅)
```

## 应用架构（闭源,基于解包+strings+运行时推断）

- Flutter GUI（`FlashFoxLite`,25KB 动态 ELF）+ mihomo Core（`FlashFoxLiteCore`,
  3.2.1 为 61MB 静态 Go ELF）。本质是 FlClash fork,`version.json` 里 app_name 是
  `fl_clash`。
- GUI 与 Core 走 **Unix socket**：`/tmp/FlashFoxLiteSocket_XXXX.sock`（XXXX 随机,
  GUI 创建、权限 755、orion 属主;Core fork 时收到 socket 路径作唯一 argv）。
- Core 监听 **mixed-port 127.0.0.1:7892**（HTTP/SOCKS5 合一）。TUN 接口
  `Meta`(198.18.0.1/30),fake-ip 段 198.18.0.0/16,路由表 2022。
- 3.2.1 bundle 目录:`opt/FlashFoxLite/{FlashFoxLite,FlashFoxLiteCore,lib/,data/}`
  （3.0.6 在 `usr/share/FlashFoxLite`）。Flutter 引擎按 `/proc/self/exe` 所在目录
  相对找 lib/、data/、icudtl.dat → 整个 bundle 必须同目录,`bin/` 只放 symlink。
- 桌面文件 `StartupWMClass=com.ffclient.app` 是 app id 线索,数据目录跟着它走。

## 数据目录（排障第一查这里）

3.2.1 起:**`~/.local/share/com.ffclient.app/`**（3.0.6 是 `ffclient.app`,已被新版本
弃用——GUI 完全不读老目录;老目录残留可删但别指望它生效）。内容:
`shared_preferences.json`（明文,`flutter.config` 是**内嵌 JSON 字符串**,
含 `patchClashConfig.tun.device`）、`config.yaml`（**二进制加密**,无法直读）、
`profiles/*.dat`（订阅,加密）、`system_proxy_active.marker`（系统代理激活标记）、
`database.sqlite`（连接/流量记录）、GeoIP 数据文件。日志只进 journalctl
（`journalctl | grep flashfox`）。

## 关键机制

### TUN 适配（tunSupport=true,供 nixosModules 使用）

闪狐原生提权协议（Arch/Ubuntu）:GUI 对 Core 路径 `sudo chown root:root && chmod +sx`
后 fork,期待 setuid root 运行。与 NixOS 只读 nosuid store 冲突,四件套适配:

1. **设备名修正（fix-device）**：闪狐把 TUN 设备名硬编码中文「闪狐云_Lite」,创建
   接口时做 ASCII 化（实际 `__________Lite`）但加 ip rule 时用中文原名 → 规则
   `[detached]` → 出站防环规则失效 → 全断网。`libexec/flashfox-fix-device` 在 GUI
   每次启动前（wrapProgram `--run`）把 `patchClashConfig.tun.device` 幂等改为
   `Meta`（jq 变换,只处理 `flutter.config` 为字符串的情况,仅值不同才写文件）。
   ⚠ 路径必须指向**当前版本**数据目录（见上）。
2. **setuid wrapper（提权）**：Core 本体改名 `FlashFoxLiteCore.bin`;
   NixOS `security.wrappers.flashfox-core`（setuid root,`permissions=u+rwx,g+x,o+x`
   使 stat 呈现 rws——默认 u+rx 只有 r-s,过不了闪狐检查）。
3. **免密码框（bind-mount）**：闪狐开 TUN 前对 Core 路径 lstat,要求 root:root+suid。
   构建沙箱不能设 suid 位 → `flashfox-core-mount.service`（在
   `suid-sgid-wrappers.service` 之后）把真 wrapper `mount --bind` 到 Core 原路径,
   检查直接看到 wrapper 本体 → 永不弹框。Core 原路径放 0755 跳板脚本
   （`exec /run/wrappers/bin/flashfox-core "$@"`）作挂载点 + 挂载缺失兜底。
4. **假 sudo**：`libexec/flashfox-fake-sudo/sudo` 吞掉含 FlashFoxLiteCore 的
   chown/chmod（只读 store 必然失败且本布局是 no-op）,其余 sudo 原样放行。

NixOS 模块配套:`boot.kernelModules=["tun"]`、防火墙
`trustedInterfaces=["Meta"]`（mihomo tun2socks 桥接把改写 SYN 从 TUN 接口送回
本机 198.18.0.1:<随机端口>,不信任则握手全断——这是 3.0.6 时代"fake-ip 入站不
转发"假说的真凶,实际是防火墙）、`checkReversePath="loose"`（防非对称回包被
rp_filter 丢）。

### GUI 运行时环境（package.nix postFixup,职责划分勿乱删）

| 注入 | 用途 |
|---|---|
| PATH: glib.bin | `gsettings` 命令（设置系统代理;NixOS 系统 PATH 无此命令） |
| PATH: xdg-user-dirs | `xdg-user-dir`（path_provider 查用户目录,缺失启动崩溃） |
| PATH: 假 sudo（tun） | 吞提权命令（PATH 最前） |
| LD_LIBRARY_PATH | libsecret（3.2.1 deb 新增 Depends,无 NEEDED、dlopen 裸名）;bundle lib/ 兜底 |
| FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR | **librust_api.so 加载**。flutter_rust_bridge 在 Linux 按可执行文件相对目录找库 open 全路径,裸名 dlopen 不可靠（实测 LD_LIBRARY_PATH 不够,仍崩）;设 bundle lib/ 目录后确定性加载 |
| GSETTINGS_SCHEMA_DIR | gsettings CLI 读 org.gnome.system.proxy（见下 schema 迁移;`--set` 覆盖环境值,闪狐只依赖此 schema,可接受） |

### 两个 nixpkgs 生态适配点（2026-09 升级时踩的,后续升级先检查是否仍适用）

1. **gsettings schema 目录迁移**:当前 nixpkgs 的 glib setup-hook 把 schema 从
   `share/glib-2.0/schemas` 迁到 `share/gsettings-schemas/<pkg>/glib-2.0/schemas`
   （旧的 glib-2.0/schemas 是空壳）。`gsettings` CLI 只认 `GSETTINGS_SCHEMA_DIR`
   指向**最终 schemas 目录**,或 `XDG_DATA_DIRS` 含 `share/gsettings-schemas/<pkg>`。
   只把 gsettings-desktop-schemas 装进 systemPackages 已不够（实测"没有安装架构"）。
   package.nix 用 `.name` 拼路径:`${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}/glib-2.0/schemas`。
2. **flutter_rust_bridge（3.2.1 新引入）**:librust_api.so 取代旧 libflutter_js_plugin,
   用 `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` 定向加载（见上表）。

## 排障命令速查（3.2.1 现状,全部实测过）

```bash
# 1. 进程与身份
ps -eo pid,args | grep -i FlashFoxLite      # GUI 是 .flashfox-lite-wrapped_,Core 是 FlashFoxLiteCore.bin
grep -E '^(Uid|Gid|CapEff)' /proc/$(pgrep -f FlashFoxLiteCore.bin)/status   # 应 root: 1000/0/0/0

# 2. GUI 实际数据目录(铁律:以 fd 为准,别猜)
ls -l /proc/$(pgrep -f wrapped_)/fd | grep -E 'ffclient|com\.' | head

# 3. 配置与开关(3.2.1 用 com.ffclient.app)
python3 -c "import json;d=json.load(open('$HOME/.local/share/com.ffclient.app/shared_preferences.json'));fc=json.loads(d['flutter.config']) if isinstance(d['flutter.config'],str) else d['flutter.config'];print(fc['networkProps']['systemProxy'],fc['patchClashConfig']['tun'])"
stat -c '%y' ~/.local/share/com.ffclient.app/shared_preferences.json   # 时间戳若停更=GUI 没写这个文件(目录错了?)

# 4. TUN 状态
ip -br addr | grep -i meta                  # 接口(应为 Meta)
ip rule | grep -E '^900|^9010'              # 9001 的 iif Meta 不应 [detached]
ip route show table 2022                    # default via 198.18.0.2 dev Meta
stat -c '%U:%G %A' "$(readlink -f /run/current-system/sw/bin/flashfox-lite | xargs dirname | xargs dirname)/share/FlashFoxLite/FlashFoxLiteCore"
#   应 root:root -rws--x--x(注意:不是 /run/current-system/sw/share/... 路径,3.2.1 不存在)
systemctl status flashfox-core-mount --no-pager

# 5. 系统代理
ss -tlnp | grep 7892
# gsettings 不在系统 PATH;用 wrapper 注入的 schema dir 测(路径从 wrapper 里取)
GSDIR=$(grep -oE "export GSETTINGS_SCHEMA_DIR='([^']*)'" "$(readlink -f /run/current-system/sw/bin/flashfox-lite)" | sed "s/export GSETTINGS_SCHEMA_DIR='//;s/'//")
GSETTINGS_SCHEMA_DIR="$GSDIR" /nix/store/*glib-2.88.3-bin*/bin/gsettings get org.gnome.system.proxy mode   # 应 'manual'
curl -x http://127.0.0.1:7892 https://www.google.com   # 纯系统代理模式应通

# 6. 连通性(区分 TUN 直连 vs 7892)
curl -s -o /dev/null -w '%{http_code}\n' https://www.google.com          # TUN 直连
curl -s -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:7892 https://www.google.com  # 7892

# 7. 残留 TUN 清理(GUI 关 TUN 后 Core 残留会留着接口/规则/路由表 → 7892 国外全挂)
sudo pkill -f FlashFoxLiteCore.bin
sudo ip rule del pref 9000; sudo ip rule del pref 9001; sudo ip rule del pref 9001
sudo ip rule del pref 9002; sudo ip rule del pref 9002; sudo ip rule del pref 9002
sudo ip rule del pref 9010; sudo ip route flush table 2022; sudo ip link del Meta
```

## 版本差异（3.0.6 → 3.2.1,2026-09 升级）

| 项 | 3.0.6 | 3.2.1 |
|---|---|---|
| deb 体积 | 51M | 43M（删离线地图 map_tiles） |
| bundle 路径 | `usr/share/FlashFoxLite` | **`opt/FlashFoxLite`** |
| 数据目录 | `~/.local/share/ffclient.app` | **`~/.local/share/com.ffclient.app`** |
| 订阅 profile | `profiles/999999.yaml` | `profiles/<hash>.dat` |
| 插件 | libtray_manager_plugin、libflutter_js_plugin、libsqlite3_flutter_libs_plugin | libtray_plugin、**librust_api.so（新,dlopen）**、libsqlite3.so;新增 libwifi_ssid_plugin |
| Core | 35M,Go 1.24,sing-tun v0.4.17 | 61M,Go 1.26.5,sing-tun v0.4.22（加 tailscale 等） |
| deb Depends | 无 libsecret | **+libsecret-1-0**（无 NEEDED,dlopen） |
| desktop | 无 StartupWMClass | `StartupWMClass=com.ffclient.app` |
| mixed-port / tun.device / 提权协议 | 7892 / 中文硬编码 / sudo+chmod+sx | 不变（四件套原样有效） |

升级 deb 时先静态拆包对比此表再动代码。

## 升级 deb 流程（3.2.1 起不止改版本号）

1. 替换 `vendor/FlashFoxLite-<新版本>-linux-amd64.deb`,改 `package.nix` version。
2. 静态拆包对比（新/旧都要）:`dpkg-deb -c/-I` 看 bundle 路径、插件 .so 列表、
   NEEDED（`readelf -d`）、depends——对照上表逐项核。
3. 新 dlopen 库（无 NEEDED）→ buildInputs + LD_LIBRARY_PATH;新裸名 dlopen
   （如 librust_api）→ 按 flutter_rust_bridge 机制处理。
4. **核对数据目录是否再迁移**（desktop `StartupWMClass` / `~/.local/share` 新目录
   是线索）→ fix-device 路径同步。
5. strings 对比 GUI 提权协议（`sudo`/`chown root:root`/`FlashFoxLiteCore`），
   变了要重新评估四件套。
6. 用户 rebuild + 实测三条路径:系统代理单独、TUN 单独、两者同时,都要过;
   无残留接口/规则/路由表。

## 实测过的行为基线（3.2.1,2026-09-10）

- TUN 直连 google/baidu 200/302;7892 走 google 302/youtube 200/baidu 200
- **TUN 与系统代理可同时开,互不影响**（干净状态下实测 7892 走国外正常、
  TUN 直连正常）——不存在"必须二选一"的固有冲突
- **正常关 TUN 闪狐会自清理**（接口 persist off 随 Core 关 fd 自动消失,
  9000-9010 规则/2022 表同步清除,已实测）
- **异常路径会残留**:Core 被强杀/GUI 崩溃/升级切换时,内核只回收 persist off
  接口,不回收用户态 ip rule/路由表 → 残留有粘性(新 Core 不清别人的残留) →
  系统代理 7892 走国外全挂。模块的 flashfox-tun-cleanup 服务(15s 周期)兜底
  自动清理,并写 journal 日志便于观测
- ⚠ 残留的**确切触发条件尚未 100% 钉死**（曾见 GUI 正常关闭后仍有残留的个案,
  也可能混有更早遗留的状态）;cleanup 服务加日志后可持续积累数据,再决定去留
- Core 以 root 跑（Uid 1000/0/0/0）、Core 路径 `root:root -rws--x--x`、开 TUN 免密
- TUN 开启时 mihomo 的 dns.listen(1053)不监听、无 iptables REDIRECT 属正常现象
  （DNS 劫持走 TUN 内 `dns-hijack: any:53`）,不是故障
- 7892 走国外全挂时的排查顺序:①残留 TUN（Meta/2022/9000-9010,等 cleanup
  服务或手动清）→ ②数据目录（GUI 是否真在写 com.ffclient.app）→ ③gsettings
  schema → ④节点本身
