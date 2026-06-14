# honcho-nix

A Nix flake packaging [Honcho](https://github.com/plastic-labs/honcho) as a
reproducible Nix package and NixOS service — memory infrastructure for
stateful agents.

## Overview

| Output                      | Description                                                  |
| --------------------------- | ------------------------------------------------------------ |
| `packages.<system>.default` | Honcho application (uv2nix + `mkApplication`)                |
| `packages.<system>.server`  | FastAPI server wrapper                                       |
| `packages.<system>.cli`     | `honcho` CLI                                                 |
| `packages.<system>.migrate` | Alembic migration runner (`honcho-migrate`)                  |
| `packages.<system>.worker`  | Background deriver / queue worker                            |
| `apps.<system>.*`           | `nix run` entry points                                       |
| `devShells.default`         | Editable uv2nix development shell                            |
| `overlays.default`          | `pkgs.honcho`, `pkgs.honcho-server`, etc.                    |
| `nixosModules.default`      | PostgreSQL (pgvector), Redis, migrate, server, worker, nginx |

### Repository layout

| Path                   | Contents                                             |
| ---------------------- | ---------------------------------------------------- |
| `flake.nix`            | Flake inputs (nixpkgs, honcho-src, uv2nix ecosystem) |
| `nix/build.nix`        | Flake outputs                                        |
| `nix/honcho-scope.nix` | uv2nix workspace + Python package set                |
| `nix/overrides.nix`    | Package-specific build overrides                     |
| `nix/packages.nix`     | `mkApplication` + component wrappers                 |
| `nix/devshell.nix`     | Locked uv2nix development shell (non-editable)       |
| `nix/module.nix`       | NixOS module                                         |
| `nix/tests/`           | Build, smoke, and VM integration tests               |

## Quick start

```bash
# Build the server
nix build '.#packages.x86_64-linux.server'

# Run the CLI
nix run '.#cli' -- --help

# Development shell (editable Honcho source via uv2nix)
nix develop
```

## NixOS module

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    honcho-nix.url = "github:your-user/honcho-nix";
  };

  outputs = { nixpkgs, honcho-nix, ... }: {
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
                model = "text-embedding-3-small";
              };
            };
            environmentFile = "/run/secrets/honcho-env";
            database.enable = true;   # auto PostgreSQL + pgvector
            redis.enable = false;     # opt-in local Redis + CACHE_ENABLED
            migrate.enable = true;    # honcho-migrate.service (Alembic)
            worker.enable = true;
          };
        }
      ];
    };
  };
}
```

### Service units

| Unit                     | Type    | Role                                     |
| ------------------------ | ------- | ---------------------------------------- |
| `honcho-migrate.service` | oneshot | Alembic `upgrade head` before app starts |
| `honcho.service`         | simple  | FastAPI server on port 8000              |
| `honcho-worker.service`  | simple  | Optional deriver queue worker            |

When `migrate.enable = true` (default), both `honcho.service` and
`honcho-worker.service` require `honcho-migrate.service`. The migrate unit
re-runs when the migrate package or settings change (`restartTriggers`).

Legacy option names `createDatabase` and `enableRedis` are renamed to
`database.enable` and `redis.enable`.

## How it works

Dependencies are resolved from upstream `honcho-src/uv.lock` via
[uv2nix](https://pyproject-nix.github.io/uv2nix/). The build uses layered
overlays:

1. `pyproject-build-systems.overlays.wheel`
2. `workspace.mkPyprojectOverlay`
3. Project overrides in `nix/overrides.nix` (hatchling + app data for root `honcho`)

Component packages are thin `writeShellApplication` wrappers around a single
`mkApplication` derivation — no `$PYTHONPATH` hacks.

PostgreSQL gets pgvector via `services.postgresql.extensions` and
`initialScript` on `template1`. Redis is managed via
`services.redis.servers.honcho` when `redis.enable = true`.

## Settings reference

Nested Nix attrs flatten to environment variables with `__` separators:

```nix
services.honcho.settings = {
  log_level = "DEBUG";
  embedding.model_config = {
    transport = "openai";
    model = "text-embedding-3-small";
  };
};
```

## Secrets

Use `environmentFile` for API keys, JWT secrets, and remote `DB_CONNECTION_URI`:

```nix
environmentFile = "/run/secrets/honcho-env";
```

Compatible with [sops-nix](https://github.com/Mic92/sops-nix) and
[agenix](https://github.com/ryantm/agenix).

## Development

```bash
nix develop
nix build '.#checks.x86_64-linux.override-scope'
nix build '.#checks.x86_64-linux.smoke-test'
nix build '.#checks.x86_64-linux.vmtest'
```
