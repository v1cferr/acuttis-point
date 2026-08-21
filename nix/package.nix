{
  lib,
  stdenvNoCC,
  gleam,
  nodejs,
  playwright-driver,
  cacert,
  makeWrapper,
  bash,
  coreutils,
  curl,
  iproute2,
  openssh,
  systemd,
  util-linux,
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

    # Only the package sources. `gleam.lock` is a lock file whose presence at the
    # end of a download is not guaranteed, and one stray empty file changes the
    # hash — which it did on 2026-08-17, leaving the build unable to reproduce
    # itself. The package contents themselves are pinned by the outer_checksum in
    # manifest.toml, so gleam verifies them regardless of this hash.
    installPhase = ''
      cp -r build/packages $out
      rm -f $out/gleam.lock
    '';

    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-jQsAYlNRP1Ol0k3RNOEWBkfcrwmDpvUnAeo8f3P0bIE=";
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
      ../scripts/with-fai-proxy.sh
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

    # The proxy wrapper ships with the program rather than being reimplemented in
    # Nix, so the declarative deployment and the local scripts/ path run the same
    # code. It runs $out/bin/acuttis-point unless told otherwise.
    install -Dm755 ${../scripts/with-fai-proxy.sh} $out/bin/acuttis-point-proxied
    wrapProgram $out/bin/acuttis-point-proxied \
      --set-default ACUTTIS_BINARY $out/bin/acuttis-point \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          coreutils
          curl
          iproute2
          openssh
          systemd
          # flock, which is what keeps two runs from fighting over the tunnel.
          util-linux
        ]
      }

    runHook postInstall
  '';

  meta = {
    description = "Headless timekeeping automation for Acuttis";
    homepage = "https://github.com/v1cferr/acuttis-point";
    mainProgram = "acuttis-point";
    platforms = lib.platforms.linux;
  };
}
