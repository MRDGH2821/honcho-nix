{
  pkgs,
  scope,
}:
let
  # Editable overlays require a non-store checkout; the pinned flake input
  # lives in /nix/store, so the dev shell uses the locked uv2nix env instead.
  devVirtualenv = scope.pythonSet.mkVirtualEnv "honcho-dev-env" scope.workspace.deps.all;
in
pkgs.mkShell {
  packages = [
    devVirtualenv
    pkgs.uv
  ];
  env = {
    UV_NO_SYNC = "1";
    UV_PYTHON = scope.pythonSet.python.interpreter;
    UV_PYTHON_DOWNLOADS = "never";
  };
  shellHook = ''
    unset PYTHONPATH
  '';
}
