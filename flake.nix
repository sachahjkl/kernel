{
  description = "Next-Gen Kernel";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605";
    git-hooks = {
      url = "https://flakehub.com/f/cachix/git-hooks.nix/0.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forEachSystem = function:
      inputs.nixpkgs.lib.genAttrs systems (system:
        function {
          inherit system;
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        });
    preCommitCheck = {
      system,
      pkgs,
    }:
      inputs.git-hooks.lib.${system}.run {
        package = pkgs.prek;
        src = ./.;
        hooks = {
          alejandra.enable = true;
          deadnix.enable = true;
          statix.enable = true;
          check-merge-conflicts.enable = true;
        };
      };
  in {
    formatter = forEachSystem ({pkgs, ...}: pkgs.alejandra);

    checks = forEachSystem (arguments: {
      pre-commit = preCommitCheck arguments;
    });

    devShells = forEachSystem (arguments: let
      check = preCommitCheck arguments;
    in {
      default = arguments.pkgs.mkShell {
        packages = check.enabledPackages;
        inherit (check) shellHook;
      };
    });
  };
}
