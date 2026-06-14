# tests/override-scope.nix — verify the uv2nix package set builds cleanly.
{
  pkgs,
  scope,
}:
pkgs.runCommand "honcho-validate" {
  nativeBuildInputs = [
    scope.packages.default
    scope.packages.server
    scope.packages.migrate
    scope.packages.worker
    scope.packages.cli
  ];
} ''
  echo "honcho-nix: uv2nix packages build ok" > "$out"
''
