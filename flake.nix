{
  description = "tg-ws-proxy - Telegram MTProto WebSocket bridge (headless + optional tray)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      tgws = pkgs: {
        tg-ws-proxy = pkgs.callPackage ./pkgs/package.nix { };
        tg-ws-proxy-tray = pkgs.callPackage ./pkgs/package.nix { withTray = true; };
      };
    in
    {
      overlays.default = final: _: tgws final;

      packages = forAllSystems (pkgs: (tgws pkgs) // { default = (tgws pkgs).tg-ws-proxy; });

      nixosModules = {
        tg-ws-proxy = import ./modules/nixos.nix { inherit self; };
        default = self.nixosModules.tg-ws-proxy;
      };

      # homeManagerModules отложен.

      checks = forAllSystems (
        pkgs:
        (tgws pkgs)
        // {
          module-eval = import ./tests/module-eval.nix { inherit self pkgs; };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            nixfmt
            nix-update
          ];
        };
      });
    };
}
