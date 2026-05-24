{
  description = "Honcho-Nix dev shell";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
  in {
    formatter.${system} = pkgs.treefmt;
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        alejandra
        bun
        libxml2
        nil
        nixd
        nixfmt
        prettypst
        shfmt
        treefmt
        uv
        yq-go
      ];
    };
  };
}
