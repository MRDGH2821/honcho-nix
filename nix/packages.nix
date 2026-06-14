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
    license = lib.licenses.agpl3Plus;
  };

  # Honcho imports tiktoken encodings at startup; prefetch them for offline use.
  # Cache keys are sha1(url) as used by tiktoken.load.read_file_cached.
  o200kBaseTiktoken = pkgs.fetchurl {
    url = "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken";
    sha256 = "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d";
  };

  cl100kBaseTiktoken = pkgs.fetchurl {
    url = "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken";
    sha256 = "223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7";
  };

  tiktokenCache = pkgs.runCommand "honcho-tiktoken-cache" {} ''
    mkdir -p $out
    cp ${o200kBaseTiktoken} $out/fb374d419588a4632f3f557e76b4b70aebbca790
    cp ${cl100kBaseTiktoken} $out/9b5ad71b2ce5302211f9c61530b329a4922fc6a4
  '';

  runtimeEnv = [honchoEnv honchoPkg];
in {
  inherit honchoApp honchoEnv honchoPkg appRoot tiktokenCache;

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
