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
    # The first machine is x86-64 under QEMU. The build host is the same.
    system = "x86_64-linux";
    pkgs = inputs.nixpkgs.legacyPackages.${system};

    # What tools/kerneltool needs on the path.
    buildTools = [pkgs.odin pkgs.llvmPackages.lld pkgs.qemu pkgs.coreutils];

    # The UEFI firmware of the first machine. kerneltool reads these two names.
    firmware = {
      OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
      OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
    };

    preCommitCheck = inputs.git-hooks.lib.${system}.run {
      package = pkgs.prek;
      src = ./.;
      hooks = {
        alejandra.enable = true;
        deadnix.enable = true;
        statix.enable = true;
        check-merge-conflicts.enable = true;
      };
    };

    # kerneltool check: the tool passes -vet, the boot program builds, and the
    # machine starts under QEMU and prints the mark of the boot program.
    bootTest = pkgs.stdenvNoCC.mkDerivation ({
        name = "kernel-boot-test";
        src = inputs.nixpkgs.lib.fileset.toSource {
          root = ./.;
          fileset = inputs.nixpkgs.lib.fileset.unions [./flake.nix ./boot ./tools ./module ./modules ./blake3];
        };
        nativeBuildInputs = buildTools;
        buildPhase = ''
          export HOME=$TMPDIR
          mkdir -p build
          odin run tools/kerneltool -out:build/kerneltool -- check
        '';
        installPhase = ''
          cp build/test_output.txt $out
        '';
      }
      // firmware);
  in {
    formatter.${system} = pkgs.alejandra;

    checks.${system} = {
      pre-commit = preCommitCheck;
      boot-test = bootTest;
    };

    devShells.${system}.default = pkgs.mkShell ({
        packages = buildTools ++ preCommitCheck.enabledPackages;
        inherit (preCommitCheck) shellHook;
      }
      // firmware);
  };
}
