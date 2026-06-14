{
  pkgs,
  lib,
  honcho-src,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
}: let
  callPackage = lib.callPackageWith {
    inherit
      pkgs
      lib
      pyproject-nix
      uv2nix
      pyproject-build-systems
      ;
  };

  # Flake inputs with `flake = false` are store-path sets, not plain paths.
  honchoSrc =
    if lib.isStorePath honcho-src
    then honcho-src
    else if honcho-src ? outPath
    then honcho-src.outPath
    else honcho-src;

  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = honchoSrc;
  };

  python = pkgs.python312;

  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {inherit python;})
    .overrideScope (
      lib.composeManyExtensions [
        pyproject-build-systems.overlays.wheel
        (workspace.mkPyprojectOverlay {
          sourcePreference = "wheel";
        })
        (callPackage ./overrides.nix {
          inherit python;
          honcho-src = honchoSrc;
        })
      ]
    );

  packages = callPackage ./packages.nix {
    inherit workspace pythonSet python;
  };

  overlayForPkgs = final: prev: {
    inherit (packages)
      default
      server
      cli
      migrate
      worker
      ;
    honcho = packages.default;
    honcho-server = packages.server;
    honcho-cli = packages.cli;
    honcho-migrate = packages.migrate;
    honcho-worker = packages.worker;
  };
in {
  inherit
    workspace
    pythonSet
    python
    packages
    overlayForPkgs
    honchoSrc
    ;
}
