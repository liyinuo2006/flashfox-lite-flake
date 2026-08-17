{
  description = "闪狐云 Lite 机场客户端 Nix 包(系统代理 + TUN 模式,仅 x86_64-linux)";

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
      # package 不在选项上设 default,由两个模块的 config 段用 mkDefault 提供
      # (NixOS 侧需要根据 enableTun 选择不同布局;用户仍可用普通定义覆盖)。
      mkOptions =
        {
          lib,
          pkgs,
        }:
        {
          enable = lib.mkEnableOption "闪狐云 Lite";

          package = lib.mkOption {
            type = lib.types.package;
            description = "闪狐云 Lite 包。默认自动(按 enableTun 选择布局),可 override 换版本。";
          };

          # 闪狐用 gsettings 设置系统代理(org.gnome.system.proxy);
          # NixOS 默认缺该 schema,不装则代理设置静默失败,浏览器不走代理。
          enableGsettingsSchema = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "安装 gsettings-desktop-schemas(系统代理必需)";
          };
        };
    in
    {
      packages.${system} = rec {
        # 纯系统代理布局(无 TUN 支持)
        flashfox-lite = pkgs.callPackage ./package.nix { };
        # TUN 布局(core.bin + 跳板脚本 + 假 sudo),需配合 NixOS 模块使用
        flashfox-lite-tun = pkgs.callPackage ./package.nix { tunSupport = true; };
        default = flashfox-lite;
      };

      formatter.${system} = pkgs.nixfmt;

      # nix flake check 验证两个布局都能构建(模块实际使用的是 -tun 布局)
      checks.${system} = {
        flashfox-lite = pkgs.callPackage ./package.nix { };
        flashfox-lite-tun = pkgs.callPackage ./package.nix { tunSupport = true; };
      };

      # 独立 overlay:想注入 pkgs.flashfox-lite 的场合使用
      overlays.default = final: prev: {
        flashfox-lite = final.callPackage ./package.nix { };
      };

      # NixOS 模块:系统级安装(全用户可见,含桌面入口,支持 TUN)。
      # TUN 的实现与限制详见 package.nix 的 tunSupport 分支与 TUN-RESEARCH.md。
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
          options.programs.flashfox-lite = mkOptions { inherit lib pkgs; } // {
            # 开箱即用,无任何手动步骤:设备名修正由包内包装器自动完成
            # (package.nix 的 flashfox-fix-device,每次启动 GUI 前幂等写入)。
            enableTun = lib.mkEnableOption "TUN 模式(全流量接管)";
          };

          config = lib.mkIf cfg.enable {
            assertions = [
              {
                assertion = cfg.enableTun -> config.security.enableWrappers;
                message = ''
                  programs.flashfox-lite.enableTun 依赖 security.enableWrappers
                  (默认开启)生成 /run/wrappers 下的 setuid wrapper。
                '';
              }
            ];

            nixpkgs.overlays = [ self.overlays.default ];
            environment.systemPackages = [
              cfg.package
            ]
            ++ lib.optionals cfg.enableGsettingsSchema [ pkgs.gsettings-desktop-schemas ];

            # 默认包按 enableTun 选布局;用户显式指定 package 时以用户为准
            programs.flashfox-lite.package = lib.mkDefault (
              pkgs.callPackage ./package.nix { tunSupport = cfg.enableTun; }
            );

            boot.kernelModules = lib.optionals cfg.enableTun [ "tun" ];

            # setuid root wrapper:core 本体(.bin)的提权入口。
            # permissions 设 u+rwx 使 owner 位呈现 "rws"(闪狐的提权检查要求
            # stat 输出以 "root:" 开头且包含 "rws";默认 u+rx 只有 "r-s",过不了)。
            security.wrappers.flashfox-core = lib.mkIf cfg.enableTun {
              owner = "root";
              group = "root";
              setuid = true;
              source = "${cfg.package}/share/FlashFoxLite/FlashFoxLiteCore.bin";
              permissions = "u+rwx,g+x,o+x";
            };

            # Nix 构建沙箱无法给 store 文件设 suid 位(chmod 报 EPERM),而闪狐
            # 对 corePath 的提权检查(lstat/stat)要求看到 root:root+suid 才免弹
            # 密码框。把真 wrapper bind-mount 到 corePath 上,该路径即呈现
            # root:root+rws;挂载失败时包内跳板脚本仍会 exec wrapper,core 照样
            # 以 root 运行(只是提权检查不通过、开关 TUN 会弹密码框)。
            # 当前 nixpkgs 中 wrapper 由 suid-sgid-wrappers.service 创建,挂载
            # 作为 oneshot 排在其后;系统切换时单元内容随 store 路径变化而重启。
            systemd.services.flashfox-core-mount = lib.mkIf cfg.enableTun {
              description = "把 flashfox-core setuid wrapper 挂载到 bundle 路径";
              wantedBy = [ "multi-user.target" ];
              after = [ "suid-sgid-wrappers.service" ];
              requires = [ "suid-sgid-wrappers.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                ${pkgs.util-linux}/bin/mount --bind /run/wrappers/bin/flashfox-core "${cfg.package}/share/FlashFoxLite/FlashFoxLiteCore" || true
              '';
            };

            # mihomo 的 tun2socks 桥接在 198.18.0.1:<随机端口> 起 TCP 监听,并把
            # 改写后的 SYN 经 TUN 接口送回本机;NixOS 防火墙默认丢弃非信任接口的
            # 入站包 → 握手失败 → TUN 下所有 TCP 全断。必须信任 TUN 接口
            # (接口名随闪狐 patchClashConfig.tun.device,本项目约定为 "Meta")。
            networking.firewall.trustedInterfaces = lib.optionals cfg.enableTun [ "Meta" ];

            # TUN 的非对称回包(fake-ip 段)会被严格 rp_filter 丢弃
            networking.firewall.checkReversePath = lib.mkIf cfg.enableTun (lib.mkDefault "loose");
          };
        };

      # home-manager 模块:用户级安装(独立 hm 可用;注意此方式需用户自行 allowUnfree)。
      # 不支持 enableTun:TUN 需要 NixOS 的 security.wrappers(见 nixosModules)。
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
            programs.flashfox-lite.package = lib.mkDefault (pkgs.callPackage ./package.nix { });

            home.packages = [
              cfg.package
            ]
            ++ lib.optionals cfg.enableGsettingsSchema [ pkgs.gsettings-desktop-schemas ];
          };
        };
    };
}

