{
  pkgs,
  honcho-src,
  python,
}:
final: prev: {
  # Root honcho project has no [build-system] upstream; install runtime app data
  # alongside the Python package so Alembic and FastAPI keep the src/ layout.
  honcho = prev.honcho.overrideAttrs (old: {
    nativeBuildInputs =
      (old.nativeBuildInputs or [])
      ++ (final.resolveBuildSystem {
        hatchling = [];
      });

    postInstall =
      (old.postInstall or "")
      + ''
        appRoot="$out/${python.sitePackages}/honcho-app"
        mkdir -p "$appRoot"
        cp -r ${honcho-src}/src "$appRoot/"
        cp -r ${honcho-src}/migrations "$appRoot/"
        cp -r ${honcho-src}/scripts "$appRoot/"
        cp ${honcho-src}/alembic.ini "$appRoot/"
        if [ -f ${honcho-src}/config.toml.example ]; then
          cp ${honcho-src}/config.toml.example "$appRoot/"
        fi
      '';
  });

  lancedb = prev.lancedb.overrideAttrs (old: {
    buildInputs = (old.buildInputs or []) ++ [pkgs.stdenv.cc.cc pkgs.zlib];
  });
}
