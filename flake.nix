{
  description = "Nix flake for Honcho — memory infrastructure for stateful agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    honcho-src = {
      url = "github:plastic-labs/honcho/v3.0.7";
      flake = false;
    };
  };

  outputs = args: import ./nix/build.nix args;
}
