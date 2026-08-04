{
  description = "闪狐云 Lite 机场客户端 Nix 包(系统代理模式,无 TUN)";

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
    in
    {
      packages.${system} = rec {
        flashfox-lite = pkgs.callPackage ./package.nix { };
        default = flashfox-lite;
      };

      # 独立 overlay:想注入 pkgs.flashfox-lite 的场合(如 home-manager)使用
      overlays.default = final: prev: {
        flashfox-lite = final.callPackage ./package.nix { };
      };

      # NixOS 模块:提供 programs.flashfox-lite 选项,enable 后装包 + gsettings schema。
      # 闪狐用 gsettings 设置系统代理(org.gnome.system.proxy),
      # NixOS 默认缺该 schema,不装则代理设置静默失败,浏览器不走代理。
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
          options.programs.flashfox-lite = {
            enable = lib.mkEnableOption "闪狐云 Lite";
            package = lib.mkPackageOption pkgs "flashfox-lite" { };
          };

          config = lib.mkIf cfg.enable {
            nixpkgs.overlays = [ self.overlays.default ];
            environment.systemPackages = [
              cfg.package
              pkgs.gsettings-desktop-schemas
            ];
          };
        };
    };
}
