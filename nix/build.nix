{
  self,
  nixpkgs,
  honcho-src,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
}: let
  inherit (nixpkgs) lib;

  eachSystem = f:
    lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
    ] f;

  mkScope = system: let
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
  in
    import ./honcho-scope.nix {
      inherit
        pkgs
        lib
        honcho-src
        pyproject-nix
        uv2nix
        pyproject-build-systems
        ;
    };

  mkApp = scope: name: {
    type = "app";
    program = "${scope.packages.${name}}/bin/honcho-${name}";
  };

  mkCliApp = scope: {
    type = "app";
    program = "${scope.packages.cli}/bin/honcho";
  };
in {
  packages = eachSystem (
    system: let
      scope = mkScope system;
    in
      scope.packages
  );

  apps = eachSystem (
    system: let
      scope = mkScope system;
    in {
      default = mkApp scope "server";
      server = mkApp scope "server";
      migrate = mkApp scope "migrate";
      worker = mkApp scope "worker";
      cli = mkCliApp scope;
    }
  );

  devShells = eachSystem (
    system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      scope = mkScope system;
    in {
      default = pkgs.mkShell {
        packages = [
          scope.devVirtualenv
          pkgs.uv
        ];
        env = {
          UV_NO_SYNC = "1";
          UV_PYTHON = scope.editablePythonSet.python.interpreter;
          UV_PYTHON_DOWNLOADS = "never";
        };
        shellHook = ''
          unset PYTHONPATH
          export REPO_ROOT="${scope.honcho-src}"
        '';
      };
    }
  );

  overlays.default = eachSystem (system: (mkScope system).overlayForPkgs);

  checks = eachSystem (
    system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      scope = mkScope system;
    in {
      override-scope = import ./tests/override-scope.nix {
        inherit pkgs scope;
      };
      smoke-test = import ./tests/smoke-test.nix {
        inherit pkgs scope;
      };
      vmtest = import ./tests/minimal-vmtest.nix {
        inherit pkgs self;
      };
    }
  );

  nixosModules.default = {
    pkgs,
    ...
  }: let
    scope = mkScope pkgs.system;
  in {
    imports = [
      ./module.nix
      (lib.mkRenamedOptionModule
        ["services" "honcho" "createDatabase"]
        ["services" "honcho" "database" "enable"])
      (lib.mkRenamedOptionModule
        ["services" "honcho" "enableRedis"]
        ["services" "honcho" "redis" "enable"])
    ];
    services.honcho.honchoComponents = {
      inherit (scope.packages)
        server
        cli
        migrate
        worker
        ;
    };
  };
}
