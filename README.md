# flashfox-lite-flake

闪狐云 Lite 机场代理客户端的 Nix 包。闭源 deb 直接 vendor 进仓库,纯 flake 构建,无外部下载。

## 特性与限制

- **系统代理模式**:客户端设置系统代理(127.0.0.1:7892),浏览器自动走代理翻墙
- **无 TUN**:TUN 需 setuid 提权,/nix/store 只读+nosuid 无法实现,实测不可用
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
  programs.flashfox-lite.enable = true;
}
```

```bash
nix flake update flashfox-lite
sudo nixos-rebuild switch --flake .#mynixos
```

## 三种接入方式

| 方式 | 说明 |
|---|---|
| `nixosModules.default` | 系统级安装,全用户可见,含桌面入口(推荐) |
| `homeModules.default` | 用户级安装(home.packages),standalone home-manager 也可用 |
| `packages.x86_64-linux.flashfox-lite` | 纯包,配合 `overlays.default` 注入 `pkgs.flashfox-lite` |

## 选项

```nix
programs.flashfox-lite = {
  enable = true;               # 启用
  package = ...;               # 默认自动,可 override 换版本
  enableGsettingsSchema = true; # 系统代理 schema(默认开)
};
```

## 使用教程

1. 启动「闪狐云_Lite」(应用列表)
2. 导入订阅 → 连接节点
3. 确认「系统代理」已开启(默认开)
4. 浏览器访问 google 验证

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
```

## 升级 deb

替换 `vendor/FlashFoxLite-<新版本>-linux-amd64.deb`,并把 `package.nix` 的 `version` 改成新版本,重新构建即可。

## 仓库结构

```
flake.nix    # 输出:packages / overlays / nixosModules / homeModules / formatter
package.nix  # 打包定义(autoPatchelfHook 补依赖,wrapProgram 加 PATH)
vendor/      # 官方 deb(51M,版本泛化引用)
```
