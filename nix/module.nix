# module.nix — NixOS module for Honcho memory server
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) types;

  inherit (lib.attrsets)
    mapAttrsToList
    ;

  inherit (lib.lists) flatten;

  inherit (lib.modules) mkIf mkMerge;

  inherit (lib.options) mkEnableOption mkOption;

  inherit (lib.strings)
    concatStringsSep
    toUpper
    ;

  inherit (lib.trivial) boolToString isBool;

  settingsFormat = pkgs.formats.yaml {};

  toEnvLines = prefix: attrs:
    flatten (
      mapAttrsToList (
        k: v: let
          key =
            if prefix == ""
            then toUpper k
            else "${prefix}__${toUpper k}";
        in
          if isBool v
          then "${key}=${boolToString v}"
          else if builtins.isFloat v || builtins.isInt v || builtins.isString v
          then "${key}=${toString v}"
          else if builtins.isAttrs v
          then toEnvLines key v
          else "${key}=${builtins.toJSON v}"
      )
      attrs
    );

  pathToSecret = types.pathWith {
    inStore = false;
    absolute = true;
  };

  useLocalDatabase = cfg: cfg.database.enable && cfg.database.host == "/run/postgresql";

  mkDbUri = cfg:
    if useLocalDatabase cfg
    then "postgresql+psycopg:///${cfg.database.user}?host=/run/postgresql&dbname=${cfg.database.name}"
    else "postgresql+psycopg://${cfg.database.user}@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}";

  mkRedisUrl = cfg:
    "redis://${cfg.redis.bind}:${toString cfg.redis.port}/${toString cfg.redis.database}?suppress=true";
in {
  options.services.honcho = {
    enable = mkEnableOption "Honcho memory server";

    honchoComponents = mkOption {
      type = types.attrsOf types.package;
      internal = true;
      description = ''
        Honcho component derivations (server, cli, migrate, worker).
        Provided automatically by the flake.
      '';
    };

    settings = mkOption {
      type = types.submodule {
        freeformType = settingsFormat.type;
        options = {};
      };
      default = {};
      description = ''
        Honcho configuration as nested attrs. Leaf values become environment
        variables with double-underscore nesting separators.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr pathToSecret;
      default = null;
      example = "/run/secrets/honcho/honcho-env";
      description = ''
        Environment file for secrets (API keys, JWT signing keys, remote DB URI).
        Never enters the /nix/store.
      '';
    };

    database = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Automatically configure a local PostgreSQL database with the pgvector
          extension. Disable when using an external database.
        '';
      };

      host = mkOption {
        type = types.str;
        default = "/run/postgresql";
        description = ''
          PostgreSQL host. Defaults to the local Unix socket when using the
          auto-created database.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 5432;
      };

      user = mkOption {
        type = types.str;
        default = "honcho";
      };

      name = mkOption {
        type = types.str;
        default = "honcho";
      };

      passwordFile = mkOption {
        type = types.nullOr pathToSecret;
        default = null;
        description = ''
          Path to a file containing the PostgreSQL password for remote databases.
          Prefer setting `DB_CONNECTION_URI` via `environmentFile` instead.
        '';
      };
    };

    redis = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Start a local Redis server and enable Honcho's cache layer
          (`CACHE_ENABLED=true`).
        '';
      };

      port = mkOption {
        type = types.port;
        default = 6379;
      };

      bind = mkOption {
        type = types.str;
        default = "127.0.0.1";
      };

      database = mkOption {
        type = types.int;
        default = 0;
        description = "Redis logical database number used in CACHE_URL.";
      };
    };

    migrate = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run Alembic migrations via honcho-migrate.service before the server
          and worker start. Disable for manual migration workflows.
        '';
      };
    };

    worker = {
      enable = mkEnableOption "Honcho background deriver / queue worker";
    };

    nginx = {
      enable = mkEnableOption "basic nginx reverse-proxy for Honcho";
      enableACME = mkEnableOption "Let's Encrypt and certificate discovery";
      host = mkOption {
        type = types.str;
        example = "honcho.example.com";
        description = "Host name for the nginx virtual host.";
      };
    };
  };

  config = mkIf config.services.honcho.enable (
    let
      cfg = config.services.honcho;
      honchoC = cfg.honchoComponents;

      envLines = toEnvLines "" cfg.settings;

      dbUri = mkDbUri cfg;

      runtimeEnvLines =
        [
          "HONCHO_CONFIG_TOML_DISABLED=1"
          "TIKTOKEN_CACHE_DIR=${honchoC.tiktokenCache}"
        ]
        ++ lib.optionals cfg.database.enable ["DB_CONNECTION_URI=${dbUri}"]
        ++ lib.optionals cfg.redis.enable [
          "CACHE_URL=${mkRedisUrl cfg}"
          "CACHE_ENABLED=true"
        ];

      runtimeEnvFile = pkgs.writeText "honcho-runtime-env" ''
        ${concatStringsSep "\n" runtimeEnvLines}
      '';

      settingsFile = pkgs.writeText "honcho-settings-env" ''
        # Generated by honcho-nix — do not edit directly
        ${concatStringsSep "\n" envLines}
      '';

      environmentFiles = lib.filter (f: f != null) [
        runtimeEnvFile
        cfg.environmentFile
        settingsFile
      ];

      migrateRequires = lib.optional cfg.migrate.enable "honcho-migrate.service";

      serviceUser = cfg.database.user;

      serviceDefaults = {
        User = serviceUser;
        Group = serviceUser;
        EnvironmentFile = environmentFiles;
        StateDirectory = "honcho";
      };
    in {
      assertions = [
        {
          assertion = cfg.nginx.enableACME -> cfg.nginx.enable;
          message = "services.honcho.nginx.enableACME requires nginx.enable.";
        }
        {
          assertion =
            !(cfg.database.passwordFile != null && !useLocalDatabase cfg)
            || cfg.environmentFile != null;
          message = ''
            When using a remote database with database.passwordFile, set
            services.honcho.environmentFile with DB_CONNECTION_URI instead.
          '';
        }
      ];

      services.postgresql = mkIf cfg.database.enable {
        enable = true;
        ensureDatabases = [cfg.database.name];
        ensureUsers = [
          {
            name = cfg.database.user;
            ensureDBOwnership = true;
          }
        ];
        extensions = ps: with ps; [pgvector];
        initialScript = pkgs.writeText "pgvector-init.sql" ''
          \c template1
          CREATE EXTENSION IF NOT EXISTS vector;
        '';
      };

      users.groups.${serviceUser} = {};
      users.users.${serviceUser} = {
        isSystemUser = true;
        group = serviceUser;
        description = "Honcho memory server";
      };

      services.redis.servers.honcho = mkIf cfg.redis.enable {
        enable = true;
        port = cfg.redis.port;
        bind = cfg.redis.bind;
      };

      systemd.services = {
        honcho-migrate = mkIf cfg.migrate.enable {
          requires = lib.optionals cfg.database.enable ["postgresql.target"];
          wants = ["network-online.target"];
          after =
            ["network-online.target"]
            ++ (lib.optionals cfg.database.enable ["postgresql.target"])
            ++ (lib.optionals cfg.redis.enable ["redis-honcho.service"]);
          before =
            ["honcho.service"]
            ++ (lib.optionals cfg.worker.enable ["honcho-worker.service"]);
          restartTriggers = [
            honchoC.migrate
            runtimeEnvFile
            settingsFile
          ];
          serviceConfig = mkMerge [
            serviceDefaults
            {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe honchoC.migrate;
              Restart = "on-failure";
              RestartSec = "1s";
            }
          ];
        };

        honcho-worker = mkIf cfg.worker.enable {
          wantedBy = ["multi-user.target"];
          wants = ["network-online.target"];
          requires =
            migrateRequires
            ++ (lib.optionals cfg.redis.enable ["redis-honcho.service"]);
          after =
            ["network-online.target"]
            ++ (lib.optionals cfg.redis.enable ["redis-honcho.service"]);
          before = ["honcho.service"];
          restartTriggers = [settingsFile];
          environment = {
            DERIVER_ENABLED = "true";
            DERIVER_WORKERS = "1";
          };
          serviceConfig = mkMerge [
            serviceDefaults
            {
              ExecStart = lib.getExe honchoC.worker;
              Restart = "on-failure";
              RestartSec = "5s";
            }
          ];
        };

        honcho = {
          wantedBy = ["multi-user.target"];
          wants = ["network-online.target"];
          requires =
            migrateRequires
            ++ (lib.optionals cfg.redis.enable ["redis-honcho.service"]);
          after =
            ["network-online.target"]
            ++ (lib.optionals cfg.redis.enable ["redis-honcho.service"]);
          restartTriggers = [settingsFile];
          serviceConfig = mkMerge [
            serviceDefaults
            {
              ExecStart = lib.getExe honchoC.server;
              Restart = "on-failure";
              RestartSec = "1s";
            }
          ];
        };
      };

      services.nginx = mkIf cfg.nginx.enable {
        enable = true;
        recommendedTlsSettings = true;
        recommendedProxySettings = true;
        virtualHosts.${cfg.nginx.host} = {
          inherit (cfg.nginx) enableACME;
          forceSSL = cfg.nginx.enableACME;
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://127.0.0.1:8000";
          };
        };
      };

      security.acme.certs = mkIf cfg.nginx.enableACME {
        ${cfg.nginx.host}.postRun = ''
          systemctl try-restart honcho.service || true
        '';
      };
    }
  );
}
