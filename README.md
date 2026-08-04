# flashfox-lite-flake

闪狐云 Lite 机场客户端 NixOS 包(系统代理模式)。

```nix
# flake.nix
inputs.flashfox-lite = {
  url = "github:liyinuo2006/flashfox-lite-flake";
  inputs.nixpkgs.follows = "nixpkgs";
};

# modules
inputs.flashfox-lite.nixosModules.default

# 需要 allowUnfree
nixpkgs.config.allowUnfree = true;
```

或只用包:`inputs.flashfox-lite.packages.${pkgs.system}.flashfox-lite`


仅支持 x86_64-linux。
