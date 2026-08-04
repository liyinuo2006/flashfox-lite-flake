{
  description = "闪狐云 Lite 机场客户端 Nix 包(系统代理模式,无 TUN,仅 x86_64-linux)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # NixOS 模块与 home-manager 模块共用的选项。
      # package 默认直接 callPackage,不依赖 overlay(standalone home-manager 也能用)。
      # enableGsettingsSchema:闪狐用 gsettings 设置系统代理(org.gnome.system.proxy),
      # NixOS 默认缺该 schema,不装则代理设置静默失败,浏览器不走代理。
      mkOptions =
        {
          lib,
          pkgs,
        }:
        {
          enable = lib.mkEnableOption "闪狐云 Lite";
          package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.callPackage ./package.nix { };
            description = "闪狐云 Lite 包";
          };
          enableGsettingsSchema = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "安装 gsettings-desktop-schemas(系统代理必需)";
          };
        };
    in
    {
      packages.${system} = rec {
        flashfox-lite = pkgs.callPackage ./package.nix { };
        default = flashfox-lite;
      };

      formatter.${system} = pkgs.nixfmt;

      # 独立 overlay:想注入 pkgs.flashfox-lite 的场合使用
      overlays.default = final: prev: {
        flashfox-lite = final.callPackage ./package.nix { };
      };

      # NixOS 模块:系统级安装(全用户可见,含桌面入口)
      nixosModules.default =
        {
          lib,
          pkgs,
          config,
          ...
        }:
        let
          cfg = config.programs.flashfox-lite;
        in
        {
          options.programs.flashfox-lite = mkOptions { inherit lib pkgs; };

          config = lib.mkIf cfg.enable {
            nixpkgs.overlays = [ self.overlays.default ];
            environment.systemPackages = [
              cfg.package
            ]
            ++ lib.optionals cfg.enableGsettingsSchema [ pkgs.gsettings-desktop-schemas ];
          };
        };

      # home-manager 模块:用户级安装(独立 hm 可用;注意此方式需用户自行 allowUnfree)
      homeModules.default =
        {
          lib,
          pkgs,
          config,
          ...
        }:
        let
          cfg = config.programs.flashfox-lite;
        in
        {
          options.programs.flashfox-lite = mkOptions { inherit lib pkgs; };

          config = lib.mkIf cfg.enable {
            home.packages = [
              cfg.package
            ]
            ++ lib.optionals cfg.enableGsettingsSchema [ pkgs.gsettings-desktop-schemas ];
          };
        };
    };
}
