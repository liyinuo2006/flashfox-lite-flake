# flashfox-lite-flake

闪狐云 Lite 机场代理客户端的 Nix 包。闭源 deb 直接 vendor 进仓库,纯 flake 构建,无外部下载。
**系统代理与 TUN 模式均已在 NixOS 上验证可用**(nixos-unstable 2026-08,内核 6.18)。

## 特性与限制

- **系统代理模式**:客户端设置系统代理(127.0.0.1:7892),浏览器自动走代理翻墙
- **TUN 模式**:全流量接管(免逐应用代理设置),国内直连 + 国外走节点,fake-ip DNS 劫持可用
- **仅 x86_64-linux**(官方 deb 只有 amd64)
- **闭源**:需要 `allowUnfree`(deb 版权归闪狐,作者允许分发)
- 自动装 `gsettings-desktop-schemas`(系统代理 schema,NixOS 默认缺失会导致代理设置静默失败)

## 快速开始

```nix
# flake.nix
inputs.flashfox-lite = {
  url = "github:liyinuo2006/flashfox-lite-flake";
  inputs.nixpkgs.follows = "nixpkgs";
};

# 任一配置文件(或 nixosConfigurations.modules 列表)
{ inputs, ... }: {
  imports = [ inputs.flashfox-lite.nixosModules.default ];
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

### 一次性配置(必须,只做一次)

闪狐把 TUN 设备名硬编码为中文「闪狐云_Lite」,而它创建 TUN 接口时会把非 ASCII 字节
替换为下划线(实际接口 `__________Lite`),加路由规则时却用中文原名 → 规则
`[detached]` → 流量在 TUN 内死循环、全断网。解法是把设备名改成 ASCII(闪狐会记住,
不会改回;重置应用数据后需重跑):

```bash
# 完全退出闪狐后执行
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home() / ".local/share/ffclient.app/shared_preferences.json"
d = json.loads(p.read_text(encoding="utf-8"))
fc = json.loads(d["flutter.config"])
fc.setdefault("patchClashConfig", {}).setdefault("tun", {})["device"] = "Meta"
d["flutter.config"] = json.dumps(fc, ensure_ascii=False)
p.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
print("tun.device =", fc["patchClashConfig"]["tun"]["device"])
EOF
```

> 设备名必须与本模块信任的接口名一致(默认 `Meta`,见 `networking.firewall.trustedInterfaces`)。

### 原理(模块自动完成,无需手动)

闪狐的提权协议是「给 core 文件 chmod +sx,再 fork 它以 setuid root 运行」,
与 NixOS 的只读 nosuid store 直接冲突。本模块的 `enableTun` 做了以下适配:

1. **真提权** —— `security.wrappers.flashfox-core`:core 本体改名为
   `FlashFoxLiteCore.bin`,由 NixOS 生成 setuid root wrapper(`/run/wrappers/bin/flashfox-core`);
2. **跳板文件** —— core 原路径放一个 0755 脚本(exec 上面的 wrapper),作为挂载点和兜底;
3. **免弹密码框** —— 闪狐开 TUN 前会 lstat core 文件,要求 root:root+suid 才免弹
   密码框;Nix 构建沙箱无法给 store 文件设 suid 位,因此用
   `flashfox-core-mount.service` 把真 wrapper `mount --bind` 到 core 路径上,
   检查直接看到 wrapper 本体 → 和普通发行版一样**完全不弹密码框**;
4. **假 sudo 兜底** —— 若闪狐仍执行 `sudo chown/chmod`(打只读 store 必然失败),
   包内给 GUI 的 PATH 注入了只吞掉该命令的假 sudo,其余 sudo 不受影响;
5. **防火墙** —— `trustedInterfaces = [ "Meta" ]`:mihomo 的 tun2socks 桥接在
   `198.18.0.1:<随机端口>` 起监听并把改写后的 SYN 经 TUN 接口送回本机,
   NixOS 防火墙默认丢非信任接口入站包 → TUN 下所有 TCP 全断(Arch 无防火墙所以原生可用);
6. **rp_filter** —— `checkReversePath = "loose"`,防 TUN 非对称回包被丢弃;
7. `boot.kernelModules = [ "tun" ]`。

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
  enableTun = true;             # TUN 模式(需先做上文的 device 一次性配置)
  package = ...;                # 默认自动(按 enableTun 选布局),可 override 换版本
  enableGsettingsSchema = true; # 系统代理 schema(默认开)
};
```

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

# 系统代理 schema 是否生效(应输出 manual)
gsettings get org.gnome.system.proxy mode

# 绕过浏览器直接验证翻墙
curl -x http://127.0.0.1:7892 https://www.google.com

# TUN 检查:接口 / 挂载 / 规则
ip addr show Meta
stat -c '%U:%G %A' /run/current-system/sw/share/FlashFoxLite/FlashFoxLiteCore  # 应 root:root -rws--x--x
systemctl status flashfox-core-mount --no-pager
ip rule | grep -E '9000|9001|9002|9010'   # 9001 的 iif Meta 规则不应 [detached]

# TUN 下直连验证(不挂任何代理)
curl -s -o /dev/null -w '%{http_code}\n' https://www.google.com   # 应 200
```

完整调研过程、根因分析与诊断数据见 [TUN-RESEARCH.md](./TUN-RESEARCH.md)。

## 升级 deb

替换 `vendor/FlashFoxLite-<新版本>-linux-amd64.deb`,并把 `package.nix` 的 `version` 改成新版本,重新构建即可。

## 仓库结构

```
flake.nix        # 输出:packages / overlays / nixosModules / homeModules / formatter
package.nix      # 打包定义(autoPatchelfHook 补依赖,wrapProgram 加 PATH;tunSupport 布局)
vendor/          # 官方 deb(51M,版本泛化引用)
TUN-RESEARCH.md  # TUN 模式完整调研记录(含最终根因与方案)
```

