# flashfox-lite-flake

闪狐云 Lite 机场代理客户端的 Nix 包。闭源 deb 直接 vendor 进仓库,纯 flake 构建,无外部下载。
**系统代理与 TUN 模式均已在 NixOS 上验证可用,且可同时开启互不干扰**
(nixos-unstable 2026-09,内核 6.18,闪狐 3.2.1)。

## 特性与限制

- **系统代理模式**:客户端经 `gsettings` 设系统代理(127.0.0.1:7892),浏览器自动走代理翻墙
- **TUN 模式**:全流量接管(免逐应用代理设置),国内直连 + 国外走节点,fake-ip DNS 劫持可用
- **两种模式可同时开启**(2026-09-10 实测:双开时 7892 与 TUN 直连均正常)
- **仅 x86_64-linux**(官方 deb 只有 amd64)
- **闭源**:需要 `allowUnfree`(deb 版权归闪狐,作者允许分发)

## 快速开始

```nix
# flake.nix(想锁定已验证版本可用 ".../v1.0.0")
inputs.flashfox-lite = {
  url = "github:liyinuo2006/flashfox-lite-flake";
  inputs.nixpkgs.follows = "nixpkgs";
};

# 任一配置文件(或 nixosConfigurations.modules 列表)
{ inputs, ... }: {
  imports = [ inputs.flashfox-lite.nixosModules.default ];
  nixpkgs.config.allowUnfree = true;   # 闭源 deb,必须允许 unfree
  programs.flashfox-lite = {
    enable = true;
    enableTun = true;   # TUN 模式(可选;不开则只有系统代理)
  };
}
```

```bash
nix flake update flashfox-lite
sudo nixos-rebuild switch --flake .#mynixos
```

## TUN 模式

**零手动配置**:与 clash-verge 的 `tunMode` 一样,`enableTun = true` 后 rebuild
即可使用,首次启动闪狐时包内包装器会自动完成设备名修正(见下)。

### 原理(模块自动完成)

闪狐有几个与 NixOS 冲突的设计,本模块的 `enableTun` 分别做了适配:

1. **TUN 设备名 bug(自动修复)** —— 闪狐把设备名硬编码为中文「闪狐云_Lite」,
   创建接口时对非 ASCII 字节做 ASCII 化(实际接口 `__________Lite`),加 ip rule
   时却用原始中文名 → 规则 `[detached]` → 流量死循环全断网。包内包装器
   `flashfox-fix-device` 在 GUI **每次启动前**把 `patchClashConfig.tun.device`
   幂等改为 `Meta`(只在值不同时写文件),接口名与规则名一致,规则正常挂载;
2. **提权(替代 chmod +sx)** —— 闪狐原生做法是给 core 文件 `chmod +sx` 后以
   setuid root 运行,与 NixOS 只读 nosuid store 冲突:
   - `security.wrappers.flashfox-core`:core 本体改名为 `FlashFoxLiteCore.bin`,
     由 NixOS 生成 setuid root wrapper;
   - core 原路径放 0755 跳板脚本(exec 上面的 wrapper),作为挂载点与兜底;
   - **免弹密码框**:闪狐开 TUN 前会 lstat core 文件,要求 root:root+suid 才免弹
     密码框;Nix 构建沙箱无法给 store 文件设 suid 位,因此
     `flashfox-core-mount.service` 把真 wrapper `mount --bind` 到 core 路径上,
     检查直接看到 wrapper 本体 → 和普通发行版一样**完全不弹密码框**;
   - **假 sudo 兜底**:若闪狐仍执行 `sudo chown/chmod`(打只读 store 必然失败),
     包内给 GUI 的 PATH 注入了只吞掉该命令的假 sudo,其余 sudo 不受影响;
3. **防火墙** —— `trustedInterfaces = [ "Meta" ]`:mihomo 的 tun2socks 桥接在
   `198.18.0.1:<随机端口>` 起监听并把改写后的 SYN 经 TUN 接口送回本机,
   NixOS 防火墙默认丢非信任接口入站包 → TUN 下所有 TCP 全断(Arch 无防火墙所以原生可用);
4. **rp_filter** —— `checkReversePath = "loose"`,防 TUN 非对称回包被丢弃;
5. `boot.kernelModules = [ "tun" ]`。

## 三种接入方式

> **nixosModules 与 homeModules 二选一,不要同时启用**(两者定义同名选项会冲突)。
> TUN 模式仅 nixosModules 支持(homeModules 没有 NixOS 的 security.wrappers 可用)。

| 方式 | 说明 |
|---|---|
| `nixosModules.default` | 系统级安装,全用户可见,含桌面入口(推荐,支持 TUN) |
| `homeModules.default` | 用户级安装(home.packages),standalone home-manager 也可用(仅系统代理) |
| `packages.x86_64-linux.flashfox-lite` | 纯系统代理布局,配合 `overlays.default` 注入 `pkgs.flashfox-lite` |
| `packages.x86_64-linux.flashfox-lite-tun` | TUN 布局(core.bin + 跳板 + 假 sudo),供自行配置 wrapper 的场合 |

## 选项

```nix
programs.flashfox-lite = {
  enable = true;                # 启用
  enableTun = true;             # TUN 模式(零手动步骤,详见上文原理)
  package = ...;                # 默认自动(按 enableTun 选布局),可 override 换版本
  enableGsettingsSchema = true; # 把 gsettings-desktop-schemas 装进系统(默认开)
};
```

注意:`enableGsettingsSchema` 只是"系统级可用"的额外保险。闪狐 GUI 读
`org.gnome.system.proxy` schema 的真正保障是包内 wrapper 注入的
`GSETTINGS_SCHEMA_DIR`(见 package.nix postFixup),两个开关互不依赖。

## 使用教程

1. 启动「闪狐云_Lite」(应用列表)
2. 导入订阅 → 连接节点
3. 系统代理模式:确认「系统代理」已开启(默认开)
4. TUN 模式:打开「TUN」开关(无需密码,接口名已设为 `Meta`)
5. 浏览器访问 google 验证

命令行工具走代理:

```bash
export https_proxy=http://127.0.0.1:7892 http_proxy=http://127.0.0.1:7892
```

## 验证与排障

```bash
# 构建验证
NIXPKGS_ALLOW_UNFREE=1 nix build .#flashfox-lite --impure

# 代理端口是否在听
ss -tlnp | grep 7892

# 系统代理 schema 是否生效(应输出 manual;用闪狐 wrapper 注入的 schema dir 测)
gsettings get org.gnome.system.proxy mode

# 绕过浏览器直接验证翻墙(纯系统代理模式)
curl -x http://127.0.0.1:7892 https://www.google.com

# TUN 检查:接口 / 挂载 / 规则
ip addr show Meta
stat -c '%U:%G %A' "$(readlink -f /run/current-system/sw/bin/flashfox-lite | xargs dirname | xargs dirname)/share/FlashFoxLite/FlashFoxLiteCore"
#   应 root:root -rws--x--x(旧文档里的 /run/current-system/sw/share/... 路径 3.2.1 起不存在!)
systemctl status flashfox-core-mount --no-pager
ip rule | grep -E '9000|9001|9002|9010'   # 9001 的 iif Meta 规则不应 [detached]

# TUN 下直连验证(不挂任何代理)
curl -s -o /dev/null -w '%{http_code}\n' https://www.google.com   # 应 200
```

> ⚠ 排障必读(2026-09-10 实战):GUI 的运行时数据在
> `~/.local/share/com.ffclient.app/`(**不是** `ffclient.app`——3.2.1 起目录迁移,
> 曾导致设备名修正失效、TUN 状态残留、系统代理 7892 走国外全挂的连环故障,
> 详见 TUN-RESEARCH.md §17)。开关状态、`tun.device` 都看这个目录的
> `shared_preferences.json`;还有 `system_proxy_active.marker` 标记系统代理激活。

完整调研过程、根因分析与诊断数据见 [TUN-RESEARCH.md](./TUN-RESEARCH.md)。

## 升级 deb(3.2.1 起不止改版本号)

1. 替换 `vendor/FlashFoxLite-<新版本>-linux-amd64.deb`;
2. 把 `package.nix` 的 `version` 改成新版本;
3. **解包检查 deb 布局是否又变**(3.2.1 把 bundle 从 `usr/share/FlashFoxLite`
   迁到 `opt/FlashFoxLite`),installPhase 的 `cp -r` 路径要跟着改;
4. **对比旧版插件 .so 列表与 NEEDED**,新增 dlopen 依赖(如 libsecret)要补进
   buildInputs + LD_LIBRARY_PATH;新增裸名 dlopen 的库要按 librust_api 先例
   加 FRB 环境变量或等价机制;
5. **确认运行时数据目录是否迁移**(3.0.6→3.2.1 是 `ffclient.app`→`com.ffclient.app`,
   看 desktop 文件 `StartupWMClass` 可预判),`flashfox-fix-device` 的路径要同步;
6. 重建 + 实测系统代理与 TUN 两条路径。

## 仓库结构

```
flake.nix        # 输出:packages / checks / overlays / nixosModules / homeModules / formatter
package.nix      # 打包定义(autoPatchelfHook 补依赖,wrapProgram 注入 PATH/LD_LIBRARY_PATH/
                 # FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR/GSETTINGS_SCHEMA_DIR;tunSupport 布局)
vendor/          # 官方 deb(43M,版本泛化引用)
AGENTS.md        # 给维护者/agent 的仓库规则(硬性约定、机制、升级流程、坑)
README.md        # 本文件
TUN-RESEARCH.md  # TUN/系统代理完整调研记录(§15 最终方案、§17 3.2.1 升级复盘)
```

CI/本地验证:`NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure`(构建两种布局的包;闭源需 allowUnfree)。
