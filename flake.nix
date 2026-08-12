{
  description = "Headless timekeeping automation for Acuttis";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
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
          # nixpkgs are the only ones that run on NixOS. The npm `playwright`
          # version has to match `playwright-driver` for this to work.
          env = {
            PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
            PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
            PLAYWRIGHT_HOST_PLATFORM_OVERRIDE = "nixos";
          };

          shellHook = ''
            echo "acuttis-point: gleam $(gleam --version | cut -d' ' -f2), node $(node --version)"
            echo "playwright browsers: ${pkgs.playwright-driver.version}"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
