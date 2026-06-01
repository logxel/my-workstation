{
  description = "Hybrid Pop!_OS workstation dotfiles with Home Manager and validation tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      supportedSystems = [
        "x86_64-linux"
        # "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      currentSystem =
        let value = builtins.getEnv "NIX_SYSTEM";
        in if value != "" then value else builtins.currentSystem;
      username =
        let value = builtins.getEnv "DOTFILES_USER";
        in if value != "" then value else "developer";
      homeDirectory =
        let value = builtins.getEnv "DOTFILES_HOME";
        in if value != "" then value else "/home/${username}";
      homeManagerProfileName =
        let value = builtins.getEnv "DOTFILES_HOME_MANAGER_PROFILE_NAME";
        in if value != "" then value else "my-workstation-home-manager";
      editorCommand =
        let value = builtins.getEnv "DOTFILES_EDITOR";
        in if value != "" then value else "code --wait";
      mkPkgs = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      mkHomeConfiguration = system:
        home-manager.lib.homeManagerConfiguration {
          pkgs = mkPkgs system;
          extraSpecialArgs = {
            inherit username homeDirectory editorCommand homeManagerProfileName;
          };
          modules = [ ./home.nix ];
        };
    in
    {
      homeConfigurations =
        (forAllSystems mkHomeConfiguration)
        // {
          default = mkHomeConfiguration currentSystem;
        };

      checks = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          home-configuration = self.homeConfigurations.${system}.activationPackage;

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
              home-manager.packages.${system}.default
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
