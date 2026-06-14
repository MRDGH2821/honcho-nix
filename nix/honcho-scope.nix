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
      honcho-src
      pyproject-nix
      uv2nix
      pyproject-build-systems
      ;
  };

  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = honcho-src;
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
        })
      ]
    );

  packages = callPackage ./packages.nix {
    inherit workspace pythonSet python;
  };

  editableOverlay = workspace.mkEditablePyprojectOverlay {
    root = "$REPO_ROOT";
  };

  editablePythonSet = pythonSet.overrideScope editableOverlay;

  devVirtualenv = editablePythonSet.mkVirtualEnv "honcho-dev-env" workspace.deps.all;

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
    devVirtualenv
    editablePythonSet
    overlayForPkgs
    honcho-src
    ;
}
