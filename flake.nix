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
    # llc comes from the LLVM of the Odin compiler (18): Odin writes LLVM IR, and
    # llc makes each object with frame pointers.
    buildTools = [pkgs.odin pkgs.llvmPackages_18.llvm pkgs.llvmPackages.lld pkgs.nasm pkgs.qemu pkgs.coreutils];

    # The UEFI firmware of the first machine. kerneltool reads these two names.
    firmware = {
      OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
      OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
      # The source of the font, for the command "font" of kerneltool.
      FONT_SOURCE = "${pkgs.spleen}/share/fonts/misc/spleen-8x16.bdf";
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

    # The command "kerneltool": it compiles tools/kerneltool with the two source
    # libraries of the project, and runs it in the folder of the project.
    kerneltool = pkgs.writeShellScriptBin "kerneltool" ''
      mkdir -p build
      exec odin run tools/kerneltool -vet -collection:contract=contract -collection:support=support -out:build/kerneltool -- "$@"
    '';

    # kerneltool check: the host code passes -vet and its tests, the system builds,
    # and the machine test passes under QEMU (console, desktop, tools).
    bootTest = pkgs.stdenvNoCC.mkDerivation ({
        name = "kernel-boot-test";
        src = inputs.nixpkgs.lib.fileset.toSource {
          root = ./.;
          fileset = inputs.nixpkgs.lib.fileset.unions [./flake.nix ./boot ./contract ./kernel ./modules ./programs ./support ./tools];
        };
        nativeBuildInputs = buildTools ++ [kerneltool];
        buildPhase = ''
          export HOME=$TMPDIR
          mkdir -p build
          kerneltool check
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
        packages = buildTools ++ [kerneltool pkgs.ffmpeg] ++ preCommitCheck.enabledPackages; # ffmpeg: the command "film" of kerneltool.
        inherit (preCommitCheck) shellHook;
      }
      // firmware);
  };
}
