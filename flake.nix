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
        }:
        {
          enable = lib.mkEnableOption "闪狐云 Lite";

          package = lib.mkOption {
            type = lib.types.package;
            description = "闪狐云 Lite 包。默认自动(按 enableTun 选择布局),可 override 换版本。";
          };

          # 闪狐用 gsettings 设置系统代理(org.gnome.system.proxy)。
          # 注意(2026-09,3.2.1 + 新版 nixpkgs):schema 目录已从
          # share/glib-2.0/schemas 迁到 share/gsettings-schemas/<pkg>/glib-2.0/schemas,
          # 光把这个包加进 systemPackages 已不足以让 gsettings CLI 读到
          # (旧版单纯装包即生效,现已失效)。闪狐 GUI 读 schema 的真正保障是
          # package.nix 里 wrapProgram 注入的 GSETTINGS_SCHEMA_DIR(指向包内最终
          # schemas 目录,构建期拼出);本选项只是额外把 gsettings-desktop-schemas
          # 装进系统,供其它程序/手动 gsettings 使用,可关。
          enableGsettingsSchema = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "安装 gsettings-desktop-schemas(系统级可用;闪狐自身依赖包内 GSETTINGS_SCHEMA_DIR 注入,见 package.nix)";
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
      # TUN 的实现与限制详见 package.nix 的 tunSupport 分支与 AGENTS.md;
      # 3.0.6 时代完整调研见 TUN-RESEARCH.md(历史档案)。
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
          options.programs.flashfox-lite = mkOptions { inherit lib; } // {
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

            # 清理闪狐残留 TUN 状态(防御性,2026-09-10 实测定位):
            # 正常关 TUN(GUI 通知运行中的 Core 停 TUN)时,闪狐会自己清理干净
            # (接口 persist off 随 fd 关闭自动消失,9000-9010 规则/2022 表同步
            # 清除)——已实测验证,无需干预。
            # 但 Core 被异常杀死(GUI 崩溃/强杀/升级切换)时,内核只回收 persist off
            # 接口,不会清用户态加的 ip rule 与路由表 → 9000-9010 规则 + 2022 表
            # 残留。残留的 9002 "from 0.0.0.0 iif lo lookup 2022" 会把本地新出站
            # (含系统代理口 7892 的转发)吸进已不存在的 TUN → 系统代理走国外全挂
            # (国内碰巧直连兜底)。且残留有粘性:新 Core 启动后不认为自己开着 TUN,
            # 不会去清别人的残留,只能显式删除。
            # 本服务周期检查并清理,条件严格限定,绝不误删合法 TUN:
            #   - Core 不在跑 + Meta 存在        → 残留,清理
            #   - Core 在跑 + GUI tun.enable=false + Meta 存在 → 残留,清理
            #   - Core 在跑 + tun.enable=true     → 合法 TUN,绝不动
            # 只删闪狐专用的 9000-9010 优先级段、2022 表与名为 Meta 的接口。
            systemd.services.flashfox-tun-cleanup = lib.mkIf cfg.enableTun {
              description = "清理闪狐残留 TUN 状态(接口/规则/路由表)";
              serviceConfig = {
                Type = "oneshot";
              };
              script = ''
                set -eu
                ip=${pkgs.iproute2}/bin/ip
                pgrep=${pkgs.procps}/bin/pgrep
                jq=${pkgs.jq}/bin/jq
                prefs_glob=/home/*/.local/share/com.ffclient.app/shared_preferences.json

                # Meta 不存在 → 无残留,直接退出
                $ip link show Meta >/dev/null 2>&1 || exit 0

                should_clean=0
                if $pgrep -f FlashFoxLiteCore.bin >/dev/null 2>&1; then
                  # Core 在跑:尊重 GUI 配置,任一用户的 tun.enable=false 即视为
                  # "关了但没清干净";没有配置文件时保守不动(状态未知)。
                  found=false
                  for prefs in $prefs_glob; do
                    [ -f "$prefs" ] || continue
                    found=true
                    enable=$($jq -r '(
                      ."flutter.config" as $fc |
                      (if ($fc|type)=="string" then $fc|fromjson else $fc end) |
                      .patchClashConfig.tun.enable // false
                    )' "$prefs" 2>/dev/null || echo false)
                    if [ "$enable" = "false" ]; then should_clean=1; fi
                  done
                  [ "$found" = "true" ] || exit 0
                else
                  # Core 不在跑 → 接口必是残留(persist 不随进程消失)
                  should_clean=1
                fi

                [ "$should_clean" = "1" ] || exit 0

                # 清理:只删闪狐规则段/表/接口,全部幂等,不存在则忽略
                $ip rule del pref 9000 2>/dev/null || true
                $ip rule del pref 9001 2>/dev/null || true
                $ip rule del pref 9001 2>/dev/null || true
                $ip rule del pref 9002 2>/dev/null || true
                $ip rule del pref 9002 2>/dev/null || true
                $ip rule del pref 9002 2>/dev/null || true
                $ip rule del pref 9010 2>/dev/null || true
                $ip route flush table 2022 2>/dev/null || true
                $ip link del Meta 2>/dev/null || true
              '';
            };
            systemd.timers.flashfox-tun-cleanup = lib.mkIf cfg.enableTun {
              description = "周期触发 flashfox-tun-cleanup";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnBootSec = "30s";
                OnUnitActiveSec = "15s";
                AccuracySec = "1s";
              };
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
          options.programs.flashfox-lite = mkOptions { inherit lib; };

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

