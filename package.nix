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
  jdk,
  xdg-user-dirs,
}:

let
  version = "3.0.6";
in
stdenv.mkDerivation {
  pname = "flashfox-lite";
  inherit version;

  # 闭源 deb 直接 vendor 进仓库(51M);升级时替换 vendor/ 里的 deb 并改上面的 version
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
    # 系统托盘(libtray_manager_plugin.so)
    libayatana-appindicator
    libayatana-indicator
    ayatana-ido
    libdbusmenu
    # libdartjni.so 需要 libjvm.so(搜索路径在 preFixup 里补)
    jdk
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
    wrapProgram $out/bin/flashfox-lite \
      --prefix PATH : ${glib.bin}/bin:${xdg-user-dirs}/bin
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share
    cp -r $sourceRoot/usr/share/FlashFoxLite $out/share/
    cp -r $sourceRoot/usr/share/applications $out/share/
    cp -r $sourceRoot/usr/share/icons $out/share/
    ln -s $out/share/FlashFoxLite/FlashFoxLite $out/bin/flashfox-lite
    substituteInPlace $out/share/applications/FlashFoxLite.desktop \
      --replace "Exec=FlashFoxLite" "Exec=flashfox-lite"
    runHook postInstall
  '';

  meta = {
    description = "闪狐云 Lite(机场代理客户端)";
    homepage = "https://www.flashfox.cloud/";
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
    mainProgram = "flashfox-lite";
  };
}
