{
  lib,
  stdenv,
  autoPatchelfHook,
  wrapGAppsHook3,
  makeWrapper,
  dpkg,
  gtk3,
  glib,
  libepoxy,
  fontconfig,
  libayatana-appindicator,
  libayatana-indicator,
  ayatana-ido,
  libdbusmenu,
  # libsecret-1.so:3.2.1 deb 新增 Depends,但全 bundle 无任何 .so NEEDED 它
  # (readelf 确认)→ 必是 dlopen 加载(经 librust_api.so 或插件,闭源无法确证),
  # autoPatchelf 扫不到 → 这里进 buildInputs 并靠 postFixup 的 LD_LIBRARY_PATH 暴露。
  libsecret,
  # 系统代理:闪狐调 gsettings set org.gnome.system.proxy 设置系统代理。
  # 当前 nixpkgs 把 gsettings-desktop-schemas 的 schema 迁到
  # share/gsettings-schemas/<pkg>/glib-2.0/schemas,且 gsettings CLI 只在
  # GSETTINGS_SCHEMA_DIR 指向该最终目录(或经 GSETTINGS_SCHEMAS_PATH 传播进
  # XDG_DATA_DIRS)时才读得到;旧版单纯加进 systemPackages 已失效。
  # 这里把它加进 buildInputs 使其进入闭包,并在 postFixup 显式注入其 schema 目录。
  gsettings-desktop-schemas,
  jdk,
  xdg-user-dirs,
  # TUN 布局:true 时 core 改名 .bin,core 原路径放跳板脚本,给 GUI 注入假 sudo,
  # 并在每次启动前自动把 TUN 设备名补成 ASCII(见 installPhase 的 tunSupport 分支)。
  # 完整机制见 installPhase 注释与 AGENTS.md(TUN 适配一节)。
  tunSupport ? false,
  # 启动前修补 shared_preferences.json 用(仅 tunSupport 时进入运行时闭包)
  jq,
}:

let
  version = "3.2.1";

  # 当前 nixpkgs 的 gsettings-desktop-schemas 把 schema 放在
  # share/gsettings-schemas/<包名>/glib-2.0/schemas(旧 share/glib-2.0/schemas 已空),
  # gsettings CLI 只有 GSETTINGS_SCHEMA_DIR 指向该最终目录才读得到
  # org.gnome.system.proxy 等 schema. 用 .name 拼出该目录,传给 wrapper
  # (.name = pname-version,与目录内嵌名一致;将来包升级版本号自动跟随)。
  GSETTINGS_SCHEMA_DIR = "${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}/glib-2.0/schemas";
in
stdenv.mkDerivation {
  pname = "flashfox-lite";
  inherit version;

  # 闭源 deb 直接 vendor 进仓库(43M);升级时替换 vendor/ 里的 deb 并改上面的 version
  src = ./vendor/FlashFoxLite-${version}-linux-amd64.deb;

  nativeBuildInputs = [
    autoPatchelfHook
    wrapGAppsHook3
    makeWrapper
    dpkg
  ];

  buildInputs = [
    # GTK 栈(libflutter_linux_gtk.so 与全部插件依赖)
    gtk3
    glib
    libepoxy
    fontconfig
    # 系统托盘(libtray_plugin.so;3.2.1 起由 libtray_manager_plugin.so 改名,依赖不变)
    libayatana-appindicator
    libayatana-indicator
    ayatana-ido
    libdbusmenu
    libsecret
    # gsettings-desktop-schemas 进 buildInputs,使 WrapGAppsHook3 经
    # GSETTINGS_SCHEMAS_PATH → XDG_DATA_DIRS 传播其 schema 目录(见函数参数注释)
    gsettings-desktop-schemas
    # libdartjni.so 需要 libjvm.so(搜索路径在 preFixup 里补)
    jdk
    # 启动前修补设备名脚本的依赖(仅 tunSupport 时被引用,进入运行时闭包)
    jq
  ];

  dontConfigure = true;
  dontBuild = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" debroot
    sourceRoot=$PWD/debroot
    cd "$sourceRoot"
    runHook postUnpack
  '';

  preFixup = ''
    # Flutter 引擎按 /proc/self/exe 相对路径找 lib/、data/、icudtl.dat,
    # 因此 bundle 整体放在 share/FlashFoxLite/,bin 里只放符号链接
    addAutoPatchelfSearchPath $out/share/FlashFoxLite/lib
    # libjvm.so 不在常规 lib 目录,显式补搜索路径
    addAutoPatchelfSearchPath ${jdk}/lib/openjdk/lib/server
  '';

  postFixup = ''
    # 本包实际有两层 wrapper(fixup 阶段顺序决定,勿改):
    #   1. wrapGAppsHook3(nativeBuildInputs)先自动 wrap:注入 GIO_EXTRA_MODULES、
    #      XDG_DATA_DIRS(gsettings 库检索路径)。原 symlink 被移到
    #      $out/bin/.flashfox-lite-wrapped。
    #   2. 下面这段 wrapProgram 再包一层:注入 PATH/LD_LIBRARY_PATH/FRB/
    #      GSETTINGS_SCHEMA_DIR 与 --run fix-device。gapps 那层被改名为
    #      $out/bin/.flashfox-lite-wrapped_。
    # 最终 exec 链:flashfox-lite → .flashfox-lite-wrapped_(gapps env)
    #   → .flashfox-lite-wrapped(symlink)→ bundle 真 ELF。
    # 两层都有存在理由:gapps 层补 GTK/gio 生态环境(图标/模块检索),
    # 本层补闭源软件特有的 dlopen/schema/命令路径;不要试图合并成一层。
    # 运行时需要的外部命令与库(职责划分,勿随意删减):
    # - PATH + glib.bin:gsettings 命令(设置系统代理;NixOS 系统 PATH 无此命令)
    # - PATH + xdg-user-dirs:xdg-user-dir(path_provider 查 Downloads 等目录,
    #   缺失导致启动崩溃)
    # - PATH + 假 sudo(tunSupport):吞掉针对 FlashFoxLiteCore 的 chown/chmod
    # - LD_LIBRARY_PATH:两个无 NEEDED 引用、靠 dlopen 裸名加载的库:
    #   libsecret(3.2.1 deb 新增 Depends,订阅凭据存储经 Rust 桥 dlopen)与
    #   bundle lib/ 目录(librust_api.so 等裸名 dlopen 的兜底搜索路径)
    # - FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR:librust_api.so 的
    #   flutter_rust_bridge 官方覆盖点。FRB 在 Linux 上默认按"可执行文件相对
    #   目录"找库并 open 全路径,裸名 dlopen(LD_LIBRARY_PATH)并不可靠——
    #   实测不设此变量 GUI 启动即报 Failed to load dynamic library。
    #   设为 bundle 的 lib/ 目录即确定性加载。
    # - GSETTINGS_SCHEMA_DIR:gsettings CLI 认的单目录(schema 最终目录)。
    #   2026-09 nixpkgs 起 gsettings-desktop-schemas 的 schema 从
    #   share/glib-2.0/schemas 迁到 share/gsettings-schemas/<pkg>/glib-2.0/schemas,
    #   不注入则闪狐 set org.gnome.system.proxy 报"没有安装架构"而静默失败
    #   → 系统代理开关无效。目录在 let 块用包 .name 构建期拼出。
    #   注意 --set 会覆盖环境已有值:闪狐只依赖 org.gnome.system.proxy,
    #   其它 schema 由各程序自身环境提供,故可接受。
    wrapProgram $out/bin/flashfox-lite \
      --prefix PATH : ${glib.bin}/bin:${xdg-user-dirs}/bin \
      --prefix LD_LIBRARY_PATH : ${libsecret}/lib:$out/share/FlashFoxLite/lib \
      --set FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR "$out/share/FlashFoxLite/lib" \
      --set GSETTINGS_SCHEMA_DIR "${GSETTINGS_SCHEMA_DIR}" \
      ${lib.optionalString tunSupport "--prefix PATH : $out/libexec/flashfox-fake-sudo"} \
      ${lib.optionalString tunSupport "--run $out/libexec/flashfox-fix-device"}
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share
    # 3.2.1 起 deb 把 bundle 从 usr/share/FlashFoxLite 搬到 opt/FlashFoxLite
    # (postinst 软链与 desktop 图标仍在 usr/share 下,下面两行不动);
    # src 文件名保持 FlashFoxLite-${version}-linux-amd64.deb 泛化引用。
    cp -r $sourceRoot/opt/FlashFoxLite $out/share/
    cp -r $sourceRoot/usr/share/applications $out/share/
    cp -r $sourceRoot/usr/share/icons $out/share/
    ln -s $out/share/FlashFoxLite/FlashFoxLite $out/bin/flashfox-lite
    substituteInPlace $out/share/applications/FlashFoxLite.desktop \
      --replace "Exec=FlashFoxLite" "Exec=flashfox-lite"

  '' + lib.optionalString tunSupport ''

    # ---- TUN 布局(需配合 nixosModules.default 的 enableTun 使用)----
    #
    # 闪狐的提权协议(Arch/Ubuntu 原生):
    #   GUI 对 corePath 做 lstat/stat 检查(root:root + suid 位才算"已提权"),
    #   否则执行 sudo chown root:root <core> && chmod +sx <core>,再 fork core
    #   期待它以 setuid root 运行。
    # NixOS 上的三个障碍及对应处理:
    #   1. /nix/store 只读 + nosuid → chmod +sx 必然失败、suid 位执行也不生效
    #      → 用 security.wrappers.flashfox-core(setuid root wrapper)替代。
    #   2. 提权检查要求 corePath 是 root:root+suid 的真实文件;符号链接会被
    #      lstat 看到链接本身 → 检查永远失败 → 每次开 TUN 弹密码框
    #      → corePath 放真实文件(下面的跳板脚本);Nix 构建沙箱不能设 suid 位,
    #      所以"带 suid 位"的形态由 nixosModules 的 flashfox-core-mount 服务
    #      把真 wrapper bind-mount 到本路径来实现。
    #   3. GUI 的 sudo chown/chmod 在只读 store 上会失败
    #      → 给 GUI 的 PATH 注入假 sudo(见下),该命令直接返回成功。
    #
    # 执行链:GUI fork corePath → (挂载后即 wrapper 本体,setuid)→ root;
    # 挂载未生效时 → 跳板脚本 exec /run/wrappers/bin/flashfox-core → root。
    mv $out/share/FlashFoxLite/FlashFoxLiteCore $out/share/FlashFoxLite/FlashFoxLiteCore.bin

    # 跳板脚本:mount 的挂载点 + 挂载缺失时的兜底执行链
    echo "#!${stdenv.shell}" > $out/share/FlashFoxLite/FlashFoxLiteCore
    cat >> $out/share/FlashFoxLite/FlashFoxLiteCore <<'BOUNCE_EOF'
exec /run/wrappers/bin/flashfox-core "$@"
BOUNCE_EOF

    # 假 sudo:GUI 经 PATH 找 sudo(wrapProgram 已把本目录置于 PATH 最前)。
    # 只吞掉针对 FlashFoxLiteCore 的 chown/chmod 命令(在只读 store 上必然失败
    # 且本来就是 no-op),其余命令原样交给真 sudo,密码流程不受影响。
    mkdir -p $out/libexec/flashfox-fake-sudo
    echo "#!${stdenv.shell}" > $out/libexec/flashfox-fake-sudo/sudo
    cat >> $out/libexec/flashfox-fake-sudo/sudo <<'FAKE_SUDO_EOF'
# 闪狐开 TUN 执行: sudo sh -c 'chown root:root <core> && chmod +sx <core>'
# 该命令在只读 /nix/store 上必然失败,且本布局下是 no-op(真提权由
# /run/wrappers/bin/flashfox-core 完成),直接返回成功即可。
case "$*" in
  *FlashFoxLiteCore*) exit 0 ;;
esac
exec /run/wrappers/bin/sudo "$@"
FAKE_SUDO_EOF
    chmod +x $out/libexec/flashfox-fake-sudo/sudo

    # 启动前设备名修补:闪狐对中文 TUN 设备名有 bug(创建接口时把非 ASCII 字节
    # 替换成下划线,加 ip rule 时却用原始中文名 → 规则 [detached] → 死循环全断网)。
    # 本脚本在 GUI 每次启动前(经 postFixup 的 --run)把 patchClashConfig.tun.device
    # 幂等改为 "Meta",仅在值不同时写文件;文件不存在时静默跳过。
    # ⚠ 数据目录:3.2.1 起从 ~/.local/share/ffclient.app 迁到
    # ~/.local/share/com.ffclient.app(线索:desktop 的 StartupWMClass=com.ffclient.app)。
    # 写错目录 = device 修正永不生效:新目录 device 保持中文、而旧目录里被改成
    # Meta 的配置又不被 3.2.1 读取 → GUI 开关与系统实际 TUN 状态脱节,残留
    # Meta 接口/2022 路由表导致系统代理 7892 走国外全挂(2026-09-10 实战复盘)。
    echo "#!${stdenv.shell}" > $out/libexec/flashfox-fix-device
    cat >> $out/libexec/flashfox-fix-device <<'FIXDEV_EOF'
set -e
prefs="$HOME/.local/share/com.ffclient.app/shared_preferences.json"
[ -f "$prefs" ] || exit 0
tmp="$prefs.tmp.$$"
${jq}/bin/jq 'if (."flutter.config" | type) == "string" then ."flutter.config" |= (fromjson | .patchClashConfig //= {} | .patchClashConfig.tun //= {} | .patchClashConfig.tun.device = "Meta" | tojson) else . end' "$prefs" > "$tmp"
if cmp -s "$tmp" "$prefs"; then rm -f "$tmp"; else mv "$tmp" "$prefs"; fi
FIXDEV_EOF
    chmod +x $out/libexec/flashfox-fix-device


  '' + ''
    runHook postInstall

  '';

  meta = {
    description = "闪狐云 Lite(机场代理客户端)";
    homepage = "https://www.flashfox.cloud/";
    license = lib.licenses.unfree;
    # 官方 deb 只有 amd64
    platforms = [ "x86_64-linux" ];
    mainProgram = "flashfox-lite";
    # 直接分发上游二进制,无源码构建
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

