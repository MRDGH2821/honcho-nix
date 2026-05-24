# honcho-nix

A Nix flake packaging [Honcho](https://github.com/plastic-labs/honcho) as a
NixOS service — memory infrastructure for stateful agents.

## Overview

| Output                        | Description                                                        |
| ----------------------------- | ------------------------------------------------------------------ |
| `nixosModules.default`        | NixOS module — PostgreSQL (pgvector), Redis, server, worker, nginx |
| `packages.<system>.server`    | Honcho FastAPI server wrapper                                      |
| `packages.<system>.cli`       | `honcho` CLI (typer terminal)                                      |
| `packages.<system>.migrate`   | Alembic database migration runner                                  |
| `packages.<system>.worker`    | Background queue deriver daemon                                    |
| `packages.<system>.pythonEnv` | Python environment with all third-party deps                       |

### Repository layout

| Path             | Contents                                    |
| ---------------- | ------------------------------------------- |
| `flake.nix`      | Root flake — 2 inputs (nixpkgs, honcho-src) |
| `flake.lock`     | Pinned inputs                               |
| `nix/module.nix` | NixOS module                                |
| `nix/tests/`     | VM integration test and build validation    |

## NixOS Module Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    honcho-nix.url = "github:your-user/honcho-nix";
  };

  outputs = { self, nixpkgs, honcho-nix, ... }: {
    nixosConfigurations.my-server = nixpkgs.lib.nixosSystem {
      modules = [
        honcho-nix.nixosModules.default
        {
          services.honcho = {
            enable = true;
            settings = {
              log_level = "INFO";
              embedding.model_config = {
                transport = "openai";
                model    = "text-embedding-3-small";
              };
            };
            environmentFile = "/run/secrets/honcho-env";
            # nginx = { enable = true; host = "honcho.example.com"; };
          };
        }
      ];
    };
  };
}
```

## How it works

**Just `pkgs.python3.withPackages`.** The flake avoids uv2nix, pyproject-nix,
and flake-parts entirely — it builds a single Python environment from nixpkgs
deps and serves Honcho's own source tree on `$PYTHONPATH` at runtime. This
keeps the dependency surface minimal: **2 flake inputs** (nixpkgs + honcho-src).

Component scripts (`server`, `cli`, `migrate`, `worker`) are lightweight
`writeShellScript` wrappers that set the right `$PYTHONPATH` and call the
entry point.

The NixOS module uses `services.postgresql.initialScript` to create the pgvector
extension on first database init — no ad-hoc `postStart` hacks. Redis is managed
via `services.redis.servers.<name>`.

## Settings Reference

Settings are nested Nix attrs that get flattened to environment variables
with `__` as the nesting separator, matching Honcho's config convention:

```nix
services.honcho.settings = {
  log_level = "DEBUG";
  db.connection_uri = "postgresql+psycopg://...";
  embedding.model_config = {
    transport = "openai";
    model = "text-embedding-3-small";
  };
};
```

becomes:

```
LOG_LEVEL=DEBUG
DB_CONNECTION_URI=postgresql+psycopg://...
EMBEDDING_MODEL_CONFIG__TRANSPORT=openai
EMBEDDING_MODEL_CONFIG__MODEL=text-embedding-3-small
```

## Secrets

Use `environmentFile` instead of `settings` for anything sensitive:

```nix
environmentFile = "/run/secrets/honcho-env";
```

This file is injected via systemd's `EnvironmentFile` and never enters the
Nix store. Compatible with [sops-nix](https://github.com/Mic92/sops-nix)
and [agenix](https://github.com/ryantm/agenix).

## Development

```
nix build '.#packages.x86_64-linux.pythonEnv'
```
