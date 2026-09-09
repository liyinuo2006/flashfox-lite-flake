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
  # libsecret-1.so 供 flutter_secure_storage 经 dlopen 加载(无 NEEDED 引用,
  # autoPatchelf 扫不到,靠 postFixup 的 LD_LIBRARY_PATH 暴露);3.2.1 的 deb
  # 新增 Depends libsecret-1-0,旧版无此依赖。
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
  # 完整机制见 installPhase 注释与 flake.nix 的 nixosModules。
  tunSupport ? false,
  # 启动前修补 shared_preferences.json 用(仅 tunSupport 时进入运行时闭包)
  jq,
}:

let
  version = "3.2.1";

  # 当前 nixpkgs 的 gsettings-desktop-schemas 把 schema 放在
  # share/gsettings-schemas/<包名>/glib-2.0/schemas(旧 share/glib-2.0/schemas 已空),
  # gsettings CLI 只有 GSETTINGS_SCHEMA_DIR 指向该最终目录才读得到
  # org.gnome.system.proxy 等 schema. 用 .name 拼出该目录,传给 wrapper.
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
    # 运行时需要的外部命令:
    # - gsettings:设置系统代理(NixOS 无此命令)
    # - xdg-user-dir:path_provider 查询 Downloads/Documents 目录,缺失会导致启动崩溃
    # - tunSupport 时把假 sudo 目录放在 PATH 最前(见 installPhase 说明)
    # - LD_LIBRARY_PATH 暴露 libsecret + bundle lib:3.2.1 起订阅口令等经
    #   librust_api.so(Rust 桥)dlopen("libsecret-1.so.0") 与
    #   dlopen("librust_api.so") 裸名加载,无 NEEDED 引用、autoPatchelf RUNPATH
    #   覆盖不到 → 必须经 LD_LIBRARY_PATH 显式提供。
    # - FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR:flutter_rust_bridge 在
    #   Linux 上按"可执行文件相对目录"找 librust_api.so 并 open 全路径,裸名
    #   dlopen 不可靠(LD_LIBRARY_PATH 不一定命中)。该环境变量是其官方覆盖点,
    #   设为 bundle 的 lib/ 目录即可确定性加载,重启 GUI 即生效。
    # - GSETTINGS_SCHEMA_DIR:gsettings CLI 只认该单目录(指向 schema 最终目录)。
    #   当前 nixpkgs 的 gsettings-desktop-schemas 把 schema 放
    #   share/gsettings-schemas/<pkg>/glib-2.0/schemas(旧的 share/glib-2.0/schemas
    #   已空),不注入则闪狐调 gsettings set org.gnome.system.proxy 报"没有安装架构"
    #   静默失败 → 系统代理开关无效。GSETTINGS_SCHEMA_DIR 在构建期由 let 块拼出。
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
    # 注意:3.2.1 起数据目录从 ~/.local/share/ffclient.app 迁到
    # ~/.local/share/com.ffclient.app(desktop 文件 StartupWMClass=com.ffclient.app
    # 即为线索),写错目录会导致 device 修正永不生效(系统里残留旧接口/路由)。
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

