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

    # The Odin compiler with one patch: -thread-count:1 gives one thread, so
    # one source gives one module (property 11). The reason is in the patch.
    odin = pkgs.odin.overrideAttrs (old: {
      patches = (old.patches or []) ++ [./tools/odin_compiler/thread_count_counts_the_main_thread.patch];
    });

    # What tools/kerneltool needs on the path.
    # llc comes from the LLVM of the Odin compiler (18): Odin writes LLVM IR, and
    # llc makes each object with frame pointers.
    buildTools = [odin pkgs.llvmPackages_18.llvm pkgs.llvmPackages.lld pkgs.nasm pkgs.qemu pkgs.coreutils];

    # The pointer theme of the owner (docs/POINTERS.md): "Posy's Cursor", the
    # package of nixpkgs, pinned by flake.lock. Its license is CC-BY-NC-4.0,
    # which nixpkgs marks unfree and not redistributable: this one package is
    # allowed by its name. The repository holds no file of the theme: the
    # tool converts it at each build into build/pointers.
    pointerTheme =
      (import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate = package: inputs.nixpkgs.lib.getName package == "posy-cursors";
      }).posy-cursors;

    # The UEFI firmware of the first machine. kerneltool reads these two names.
    firmware = {
      OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
      OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
      # The source of the font, for the command "font" of kerneltool.
      FONT_SOURCE = "${pkgs.spleen}/share/fonts/misc/spleen-8x16.bdf";
      # The Xcursor folder of the pointer theme of the owner, for the build.
      POINTER_THEME_SOURCE = "${pointerTheme}/share/icons/Posy_Cursor/cursors";
    };

    # The vector font candidates, for the command "vector_fonts" of kerneltool
    # (docs/FONTS.md): name=file, separated by ";". Only the development shell
    # has them: the build reads the subsets in resources/fonts.
    vectorFontSources = {
      VECTOR_FONT_SOURCES = builtins.concatStringsSep ";" [
        "dejavu_sans_mono=${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf"
        "jetbrains_mono=${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-Regular.ttf"
        "ibm_mono=${pkgs.ibm-plex}/share/fonts/truetype/IBMPlexMono-Regular.ttf"
        "fira_mono=${pkgs.fira-mono}/share/fonts/truetype/FiraMono-Regular.ttf"
        "commit_mono=${pkgs.commit-mono}/share/fonts/truetype/CommitMono-400-Regular.ttf"
        "iosevka=${pkgs.iosevka-bin}/share/fonts/truetype/Iosevka-Regular.ttc"
      ];
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
          fileset = inputs.nixpkgs.lib.fileset.unions [./flake.nix ./CHANGELOG.md ./changelog.d ./boot ./contract ./kernel ./modules ./programs ./resources ./runtime ./support ./tools];
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
      // firmware
      // vectorFontSources);
  };
}
