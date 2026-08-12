{
  description = "Headless timekeeping automation for Acuttis";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.gleam
            pkgs.nodejs_22
          ];

          # Playwright must not download its own browsers: the pinned ones from
          # nixpkgs are the only ones that run on NixOS. Driver and browsers
          # come from the same `playwright-driver`, because a mismatch between
          # them fails with a browser revision that does not exist.
          env = {
            PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
            PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
            PLAYWRIGHT_HOST_PLATFORM_OVERRIDE = "nixos";
          };

          # Node's ESM resolver ignores NODE_PATH, so the driver has to be
          # reachable as a real node_modules entry. node_modules is not tracked.
          shellHook = ''
            mkdir -p node_modules
            ln -sfn ${pkgs.playwright-driver} node_modules/playwright-core
            echo "acuttis-point: gleam $(gleam --version | cut -d' ' -f2), node $(node --version)"
            echo "playwright-core ${pkgs.playwright-driver.version} with its matching browsers"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
