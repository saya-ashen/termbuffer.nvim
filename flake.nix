{
  description = "termbuffer.nvim flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          let
            pkgs = import nixpkgs { inherit system; };
          in
          f pkgs
        );
    in
    {
      packages = forAllSystems (pkgs: {
        termbuffer-nvim = pkgs.vimUtils.buildVimPlugin {
          pname = "termbuffer.nvim";
          version = "2025-10-15";
          src = pkgs.fetchFromGitHub {
            owner = "saya-ashen";
            repo = "termbuffer.nvim";
            rev = "main";
            sha256 = "sha256-XHZW+GBjNkHN6BjlFHkg0wa0nD3q+XdL3qUhLMcX814="; # 先假hash
          };
        };
        default = self.packages.${pkgs.system}.termbuffer-nvim;
      });
    };
}
