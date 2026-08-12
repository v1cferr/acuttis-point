{
  lib,
  stdenvNoCC,
  gleam,
  nodejs,
  playwright-driver,
  cacert,
  makeWrapper,
}:
let
  version = "0.1.0";

  # Hex is reached once, in a fixed-output derivation, so the build proper stays
  # offline and reproducible. Bump the hash when manifest.toml changes.
  deps = stdenvNoCC.mkDerivation {
    pname = "acuttis-point-deps";
    inherit version;

    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../gleam.toml
        ../manifest.toml
      ];
    };

    nativeBuildInputs = [ gleam ];

    buildPhase = ''
      export HOME="$TMPDIR"
      export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
      gleam deps download
    '';

    installPhase = "cp -r build/packages $out";

    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-nmu9WjhHbjSKBssR4PQayNxe5RGa6SopDfYA2Yc4QVU=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "acuttis-point";
  inherit version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../gleam.toml
      ../manifest.toml
      ../src
    ];
  };

  nativeBuildInputs = [
    gleam
    makeWrapper
  ];

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR"
    mkdir -p build
    cp -r ${deps} build/packages
    chmod -R u+w build/packages
    gleam build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/bin
    cp -r build/dev/javascript/. $out/lib/

    cat > $out/lib/main.mjs <<'ENTRY'
    import { main } from "./acuttis_point/acuttis_point.mjs";
    main();
    ENTRY

    # Node's ESM resolver ignores NODE_PATH, so the Playwright driver has to be
    # a real node_modules entry that resolution can walk up to from the adapter.
    mkdir -p $out/lib/node_modules
    ln -s ${playwright-driver} $out/lib/node_modules/playwright-core

    # The browsers come from the same playwright-driver as the code that drives
    # them; a mismatch asks for a browser revision that does not exist.
    makeWrapper ${nodejs}/bin/node $out/bin/acuttis-point \
      --add-flags $out/lib/main.mjs \
      --set PLAYWRIGHT_BROWSERS_PATH "${playwright-driver.browsers}" \
      --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD 1 \
      --set PLAYWRIGHT_HOST_PLATFORM_OVERRIDE nixos

    runHook postInstall
  '';

  meta = {
    description = "Headless timekeeping automation for Acuttis";
    homepage = "https://github.com/v1cferr/acuttis-point";
    mainProgram = "acuttis-point";
    platforms = lib.platforms.linux;
  };
}
