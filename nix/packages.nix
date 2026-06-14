{
  pkgs,
  lib,
  pyproject-nix,
  workspace,
  pythonSet,
  python,
}: let
  inherit (pkgs.callPackages pyproject-nix.build.util {}) mkApplication;

  honchoPkg = pythonSet.honcho;
  appRoot = "${honchoPkg}/${python.sitePackages}/honcho-app";

  honchoEnv = pythonSet.mkVirtualEnv "honcho-env" {
    honcho = [];
    honcho-cli = [];
  };

  honchoApp = mkApplication {
    venv = honchoEnv;
    package = honchoPkg;
  };

  honchoMeta = {
    description = "Honcho memory server for stateful agents";
    homepage = "https://github.com/plastic-labs/honcho";
    license = lib.licenses.asl20;
  };

  runtimeEnv = [honchoEnv honchoPkg];
in {
  inherit honchoApp honchoEnv honchoPkg appRoot;

  default =
    pkgs.symlinkJoin {
      name = "honcho";
      paths = [honchoEnv honchoPkg];
      meta = honchoMeta;
    };

  server =
    pkgs.writeShellApplication {
      name = "honcho-server";
      runtimeInputs = runtimeEnv;
      meta = honchoMeta // {mainProgram = "honcho-server";};
      text = ''
        cd "${appRoot}"
        exec fastapi run --host "''${HOST:-0.0.0.0}" --port "''${PORT:-8000}" src/main.py
      '';
    };

  migrate =
    pkgs.writeShellApplication {
      name = "honcho-migrate";
      runtimeInputs = runtimeEnv;
      meta = honchoMeta // {mainProgram = "honcho-migrate";};
      text = ''
        cd "${appRoot}"
        exec python scripts/migrate_db.py
      '';
    };

  worker =
    pkgs.writeShellApplication {
      name = "honcho-worker";
      runtimeInputs = runtimeEnv;
      meta = honchoMeta // {mainProgram = "honcho-worker";};
      text = ''
        cd "${appRoot}"
        exec python -c "import asyncio; from src.deriver.queue_manager import main; asyncio.run(main())"
      '';
    };

  cli = pkgs.writeShellApplication {
    name = "honcho";
    runtimeInputs = [honchoEnv];
    meta = honchoMeta // {mainProgram = "honcho";};
    text = ''
      exec honcho "$@"
    '';
  };
}
