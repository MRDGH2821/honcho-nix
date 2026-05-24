# tests/override-scope.nix
#
# Verify that the honcho flake builds cleanly for the given pkgs.
{
  pkgs,
  self,
}:
pkgs.runCommand "honcho-validate"
{
  buildInputs = [
    (pkgs.python3.withPackages (
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
        ]
    ))
  ];
}
''
  echo "honcho-nix: python env builds ok" > $out
''
