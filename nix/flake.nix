{
  description = "Pop!_OS workstation dev shell and validation tooling (Nix is kept for `nix shell` / `nix develop`; package/dotfile management lives in Ansible)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        # "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      mkPkgs = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      checks = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          # statix runs inside flake checks so the DevContainer can validate Nix code
          # without relying on host-side tooling.
          statix = pkgs.runCommand "statix-check"
            {
              nativeBuildInputs = [ pkgs.statix ];
            } ''
            statix check ${./.}
            touch "$out"
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nil
              nixpkgs-fmt
              statix
            ];
          };
        }
      );

      formatter = forAllSystems (
        system: (mkPkgs system).nixpkgs-fmt
      );
    };
}
