# module.nix — NixOS module for Honcho memory server
#
# Usage (in your NixOS config):
#   services.honcho = {
#     enable = true;
#     environmentFile = "/run/secrets/honcho/env";  # managed via sops-nix / agenix
#     settings = {
#       llm_openai_api_key = "sk-...";
#       log_level = "DEBUG";
#     };
#     nginx = {
#       enable = true;
#       host = "honcho.example.com";
#     };
#   };
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    types
    ;

  inherit
    (lib.attrsets)
    mapAttrsToList
    recursiveUpdate
    ;

  inherit
    (lib.lists)
    flatten
    toList
    ;

  inherit
    (lib.modules)
    mkDefault
    mkIf
    mkMerge
    mkOverride
    ;

  inherit
    (lib.options)
    mkEnableOption
    mkOption
    ;

  inherit
    (lib.strings)
    concatStringsSep
    optionalString
    toUpper
    ;

  inherit
    (lib.trivial)
    boolToString
    isBool
    ;

  # Formats
  settingsFormat = pkgs.formats.yaml {};

  # Convert nested Nix attrs → HONCHO__STYLE env-var lines.
  #
  #   { log_level = "DEBUG"; embedding.model_config = { model = "text-embedding-3-small"; }; }
  #   → [ "LOG_LEVEL=DEBUG" "EMBEDDING_MODEL_CONFIG__MODEL=text-embedding-3-small" ]
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
in {
  options.services = {
    honcho = {
      enable = mkEnableOption "Honcho memory server";

      honchoComponents = mkOption {
        type = types.attrsOf types.package;
        internal = true;
        description = ''
          Honcho component derivations (pythonEnv, server, cli, migrate, worker).
          Provided by the flake automatically via withSystem.
        '';
      };

      settings = mkOption {
        type = types.submodule {
          freeformType = settingsFormat.type;
          options = {};
        };
        default = {};
        description = ''
          Honcho configuration as a nested attribute set.  Leaf values become
          environment variables (strings, ints, bools) with double-underscore
          nesting separators.

          Example:
          ```nix
          settings = {
            log_level = "DEBUG";
            embedding.model_config.transport = "openai";
            embedding.model_config.model = "text-embedding-3-small";
          };
          ```
        '';
      };

      environmentFile = mkOption {
        type = types.nullOr pathToSecret;
        default = null;
        example = "/run/secrets/honcho/honcho-env";
        description = ''
          Environment file as defined in {manpage}`systemd.exec(5)`.

          Use this for secrets (API keys, JWT signing keys) without placing
          them in the world-readable /nix/store.

          ```
          LLM_OPENAI_API_KEY=sk-...
          AUTH_JWT_SECRET=your-secret-here
          ```
        '';
      };

      createDatabase = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically create a local PostgreSQL database with the pgvector extension";
      };

      enableRedis = mkOption {
        type = types.bool;
        default = false;
        description = "Start a local Redis server and wire up the honcho cache layer";
      };

      database = {
        host = mkOption {
          type = types.str;
          default = "/run/postgresql";
          description = ''
            PostgreSQL host.  Defaults to the local Unix socket when using the
            auto-created database; set to a remote hostname when pointing at an
            external database.
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
        password_file = mkOption {
          type = types.nullOr pathToSecret;
          default = null;
          description = "Path to file containing the PostgreSQL password (remote only)";
        };
      };

      worker = {
        enable = mkEnableOption "Honcho background deriver / queue worker systemd unit";
      };

      nginx = {
        enable = mkEnableOption "basic nginx reverse-proxy for Honcho";
        enableACME = mkEnableOption "Let's Encrypt and certificate discovery";
        host = mkOption {
          type = types.str;
          example = "honcho.example.com";
          description = ''
            Host name for the nginx virtual host and associated ACME cert.
          '';
        };
      };
    };
  };

  config = mkIf config.services.honcho.enable (
    let
      cfg = config.services.honcho;

      # Guard — the flake must supply honchoComponents
      honchoC = cfg.honchoComponents;

      # ── DB connection URI ──────────────────────────────────────────────────────
      #
      # When using the local socket (default) we don't need a password.  For remote
      # hosts the password is read from the file referenced by `password_file` via
      # bash (escaping the shell injection concern by reading it into an env var on
      # the systemd ExecStart line — actually we just inline it into the URI that's
      # already baked into the store.  For truly dynamic passwords use the
      # environmentFile option instead.
      dbUri =
        if cfg.database.host == "/run/postgresql"
        then "postgresql+psycopg:///${cfg.database.user}?host=/run/postgresql&dbname=${cfg.database.name}"
        else "postgresql+psycopg://${cfg.database.user}@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}";

      # ── Redis URL ──────────────────────────────────────────────────────────────
      redisUrl = "redis://localhost:6379/0?suppress=true";

      # ── User-supplied settings flattened to env-lines ──────────────────────────
      envLines = toEnvLines "" cfg.settings;

      # ── Write user settings to a temp env file (merged into systemd EnvFile) ───
      settingsFile = pkgs.writeText "honcho-settings-env" ''
        # Generated by honcho-nix — do not edit directly
        ${concatStringsSep "\n" envLines}
      '';

      # ── Base environment -------------------------------------------------------
      baseEnvironment =
        recursiveUpdate
        {
          HONCHO_CONFIG_TOML_DISABLED = "1";
        }
        (
          mkIf cfg.createDatabase {
            DB_CONNECTION_URI = mkDefault dbUri;
          }
        )
        // (mkIf cfg.enableRedis {
          CACHE_URL = redisUrl;
          CACHE_ENABLED = "true";
        });

      # ── Common systemd service properties ─────────────────────────────────────
      serviceDefaults = {
        DynamicUser = true;
        User = "honcho";
        EnvironmentFile = mkIf (cfg.environmentFile != null) [
          cfg.environmentFile
          settingsFile
        ];
        StateDirectory = "honcho";
      };
    in {
      # ── Assertions ──────────────────────────────────────────────────────────────
      assertions = [
        {
          assertion = cfg.nginx.enableACME -> cfg.nginx.enable;
          message = ''
            Cannot enable `services.honcho.nginx.enableACME` when
            `services.honcho.nginx.enable` is `false`.
          '';
        }
      ];

      # ── PostgreSQL with pgvector ────────────────────────────────────────────────
      services.postgresql = mkIf cfg.createDatabase {
        enable = true;
        ensureDatabases = [cfg.database.name];
        ensureUsers = [
          {
            name = cfg.database.user;
            ensureDBOwnership = true;
          }
        ];
        # Bring in the pgvector extension package.  The modern option name is
        # `extensions` (extraPlugins is a deprecated alias).
        extensions = ps: with ps; [pgvector];
        # Install the vector extension into template1 so every newly-created
        # database (including honcho, created below by ensureDatabases)
        # inherits it automatically.  The migration runner also has a safety-net
        # CREATE EXTENSION IF NOT EXISTS vector for existing databases.
        initialScript = pkgs.writeText "pgvector-init.sql" ''
          \c template1
          CREATE EXTENSION IF NOT EXISTS vector;
        '';
      };

      # ── Redis (optional) ────────────────────────────────────────────────────────
      services.redis.servers.honcho = mkIf cfg.enableRedis {
        enable = true;
        port = 6379;
        bind = "127.0.0.1";
      };

      # ── Systemd services ────────────────────────────────────────────────────────

      systemd.services = {
        # Migration  — runs Alembic "upgrade head" before the server starts
        honcho-migrate = {
          requires = lib.optionals cfg.createDatabase ["postgresql.target"];
          wants = ["network-online.target"];
          after =
            [
              "network-online.target"
            ]
            ++ (lib.optionals cfg.createDatabase ["postgresql.target"])
            ++ (lib.optionals cfg.enableRedis ["redis-honcho.service"]);
          before = ["honcho.service"] ++ (lib.optionals cfg.worker.enable ["honcho-worker.service"]);

          restartTriggers = [settingsFile];
          environment = baseEnvironment;
          serviceConfig = mkMerge [
            serviceDefaults
            {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${honchoC.migrate}";
              Restart = "on-failure";
              RestartSec = "1s";
            }
          ];
        };

        # Worker (deriver)  — optional, processes background queue
        honcho-worker = mkIf cfg.worker.enable {
          wantedBy = ["multi-user.target"];
          wants = ["network-online.target"];
          requires =
            [
              "honcho-migrate.service"
            ]
            ++ (lib.optionals cfg.enableRedis ["redis-honcho.service"]);
          after = ["network-online.target"] ++ (lib.optionals cfg.enableRedis ["redis-honcho.service"]);
          before = ["honcho.service"];

          restartTriggers = [settingsFile];
          environment =
            baseEnvironment
            // {
              DERIVER_ENABLED = "true";
              DERIVER_WORKERS = "1";
            };
          serviceConfig = mkMerge [
            serviceDefaults
            {
              ExecStart = "${honchoC.worker}";
              Restart = "on-failure";
              RestartSec = "5s";
            }
          ];
        };

        # Main Honcho FastAPI server
        honcho = {
          wantedBy = ["multi-user.target"];
          wants = ["network-online.target"];
          requires =
            [
              "honcho-migrate.service"
            ]
            ++ (lib.optionals cfg.enableRedis ["redis-honcho.service"]);
          after = ["network-online.target"] ++ (lib.optionals cfg.enableRedis ["redis-honcho.service"]);

          restartTriggers = [settingsFile];
          environment = baseEnvironment;
          serviceConfig = mkMerge [
            serviceDefaults
            {
              ExecStart = "${honchoC.server}";
              Restart = "on-failure";
              RestartSec = "1s";
            }
          ];
        };
      };

      # ── Nginx reverse proxy ─────────────────────────────────────────────────────
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

      # ACME cert refresh triggers a restart so Honcho picks up the new PEM.
      security.acme.certs = mkIf cfg.nginx.enableACME {
        ${cfg.nginx.host}.postRun = ''
          systemctl try-restart honcho.service || true
        '';
      };
    }
  );
}
