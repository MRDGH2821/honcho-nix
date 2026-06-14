# tests/smoke-test.nix — verify packaged binaries exist and the CLI runs.
{
  pkgs,
  scope,
}:
pkgs.runCommand "honcho-smoke-test" {
  nativeBuildInputs = [
    pkgs.coreutils
    scope.packages.server
    scope.packages.migrate
    scope.packages.cli
  ];
} ''
  test -x ${scope.packages.server}/bin/honcho-server
  test -x ${scope.packages.migrate}/bin/honcho-migrate
  test -x ${scope.packages.cli}/bin/honcho
  ${scope.packages.cli}/bin/honcho --help > /dev/null
  touch "$out"
''
