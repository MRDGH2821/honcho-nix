{
  self,
  nixpkgs,
  honcho-src,
}: let
  eachSystem = f:
    builtins.listToAttrs (
      map
      (s: {
        name = s;
        value = f s;
      })
      [
        "x86_64-linux"
        "aarch64-linux"
      ]
    );

  mkHonchoScope = {pkgs}: let
    pythonEnv = pkgs.python3.withPackages (
      ps:
        with ps; [
          fastapi
          uvicorn
          httpx
          pydantic
          pydantic-settings
          sqlalchemy
          alembic
          psycopg2
          asyncpg
          pgvector
          cashews
          redis
          scikit-learn
          tiktoken
          pdfplumber
          openpyxl
          sqlalchemy-utils
        ]
    );

    mkScript = name: entryPoint:
      pkgs.writeShellScript "honcho-${name}" ''
        export PYTHONPATH="${honcho-src}/src:${honcho-src}/honcho-cli/src''${PYTHONPATH:+:$PYTHONPATH}"
        cd ${honcho-src}
        exec ${pythonEnv}/bin/${entryPoint}
      '';
  in {
    inherit pythonEnv honcho-src;
    server = mkScript "server" "fastapi run --host 0.0.0.0 src/main.py";
    cli = mkScript "cli" "honcho";
    migrate = mkScript "migrate" "python scripts/migrate_db.py";
    worker = mkScript "worker" "python -c \"import asyncio; from src.deriver.queue_manager import main; asyncio.run(main())\"";
  };
in {
  packages = eachSystem (
    system: let
      pkgs = import nixpkgs {inherit system;};
      scope = mkHonchoScope {inherit pkgs;};
    in {
      inherit
        (scope)
        pythonEnv
        server
        cli
        migrate
        worker
        ;
    }
  );

  checks = eachSystem (
    system: let
      pkgs = import nixpkgs {inherit system;};
    in {
      override-scope = import ./tests/override-scope.nix {inherit pkgs self;};
      vmtest = import ./tests/minimal-vmtest.nix {inherit pkgs self;};
    }
  );

  nixosModules.default = {
    pkgs,
    config,
    lib,
    ...
  }: let
    scope = mkHonchoScope {inherit pkgs;};
  in {
    imports = [./module.nix];
    services.honcho.honchoComponents = {
      inherit
        (scope)
        pythonEnv
        server
        cli
        migrate
        worker
        ;
    };
  };
}
