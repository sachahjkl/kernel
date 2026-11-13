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

    # The release of Odin is pinned here, not by Nixpkgs: Nixpkgs is months
    # behind the releases of the compiler.
    odinRelease = "dev-2026-11a";
    odin = pkgs.odin.overrideAttrs (_: {
      version = odinRelease;
      src = pkgs.fetchFromGitHub {
        owner = "odin-lang";
        repo = "Odin";
        tag = odinRelease;
        hash = "sha256-LzvPcA6CA0p9DZi1cuFUizDPkVODMZ0OC9/y+NAO0Kc=";
      };
      # The compiler as its release gives it: no patch. The patches of
      # Nixpkgs are for raylib and for Darwin, which this system does not use.
      patches = [];
      postPatch = "patchShebangs --build build_odin.sh";
      # The compiler and its base and core libraries only: no vendor library
      # is built, because no code of this system imports one.
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin $out/share
        cp odin $out/bin/odin
        cp -r base core $out/share
        wrapProgram $out/bin/odin \
          --prefix PATH : ${pkgs.lib.makeBinPath (with pkgs.llvmPackages_18; [bintools llvm clang lld])} \
          --set-default ODIN_ROOT $out/share
        runHook postInstall
      '';
    });

    # What tools/kerneltool needs on the path.
    # llc comes from the LLVM of the Odin compiler (18): Odin writes LLVM IR, and
    # llc makes each object with frame pointers.
    # openssl: its QUIC client is the peer of the test "quic-real" of kerneltool.
    # swtpm: the software TPM of the machines of "test trusted_boot".
    # sbsigntool (sbsign): signs the boot program for Secure Boot.
    # virt-firmware (virt-fw-vars): enrols the certificate of the firmware
    # signing key in a variable store of the firmware, with Secure Boot on.
    # openssl also makes the firmware signing key ("kerneltool key new").
    buildTools = [odin pkgs.llvmPackages_18.llvm pkgs.llvmPackages.lld pkgs.nasm pkgs.qemu pkgs.coreutils pkgs.openssl pkgs.swtpm pkgs.sbsigntool pkgs.python3Packages.virt-firmware];

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

    # The firmware of the machines of the measure: the TPM driver without
    # Secure Boot, so without system management mode. With it, the firmware
    # sometimes abandons one command of the software TPM and stops using the
    # TPM for the rest of the boot (docs/TRUSTED_BOOT.md, "The machines of
    # the TPM").
    ovmfWithTpm = pkgs.OVMF.override {tpmSupport = true;};

    # The UEFI firmware of the first machine. kerneltool reads these names.
    firmware = {
      OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
      OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
      # The same firmware with a TPM driver and no system management mode,
      # for the machines of the measure. Nixpkgs builds no such variant: this
      # one is built from the source of EDK II, once, then kept in the store.
      OVMF_TPM_CODE = "${ovmfWithTpm.fd}/FV/OVMF_CODE.fd";
      OVMF_TPM_VARS = "${ovmfWithTpm.fd}/FV/OVMF_VARS.fd";
      # The firmware with a TPM driver and Secure Boot (it needs the system
      # management mode of QEMU), for the machines of Secure Boot. Its
      # variable store has no key; the build writes a copy with the
      # certificate of the firmware signing key enrolled and Secure Boot on.
      OVMF_FULL_CODE = "${pkgs.OVMFFull.fd}/FV/OVMF_CODE.fd";
      OVMF_FULL_VARS = "${pkgs.OVMFFull.fd}/FV/OVMF_VARS.fd";
      # The source of the font, for the command "font" of kerneltool.
      FONT_SOURCE = "${pkgs.spleen}/share/fonts/misc/spleen-8x16.bdf";
      # The Xcursor folder of the pointer theme of the owner, for the build.
      POINTER_THEME_SOURCE = "${pointerTheme}/share/icons/Posy_Cursor/cursors";
    };

    # The vector font candidates, for the command "vector_fonts" of kerneltool
    # (docs/FONTS.md): name=file, separated by ";". Only the development shell
    # has them: the build reads the subsets in resources/fonts.
    # Paper Mono is not in nixpkgs: its two files come from its repository,
    # at one commit, each checked by its hash.
    paperMonoFile = name: hash:
      pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/paper-design/paper-mono/74fc5537cc1f7b39aa8cccfa7dd3822e17143cca/fonts/ttf/${name}";
        inherit hash;
      };
    # B612, the interface font (docs/FONTS.md, section 12): from its
    # repository, at one commit, each file checked by its hash.
    b612File = name: hash:
      pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/polarsys/b612/48ac6ba67ecab8123e8e36d6aa05367db0c7b638/fonts/ttf/${name}";
        inherit hash;
      };
    vectorFontSources = {
      VECTOR_FONT_SOURCES = builtins.concatStringsSep ";" [
        "paper_mono=${paperMonoFile "PaperMono-Regular.ttf" "sha256-Ew4aCbZLTxUNNMk6a3vVLWxcNRN2HR+8e+QtaDmLjBA="}"
        "paper_mono_semibold=${paperMonoFile "PaperMono-SemiBold.ttf" "sha256-Gx5gctnLUz5DBacHayRKoSEnElaJyTSf25d1c6Naxl4="}"
        "dejavu_sans_mono=${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf"
        "jetbrains_mono=${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-Regular.ttf"
        "ibm_mono=${pkgs.ibm-plex}/share/fonts/truetype/IBMPlexMono-Regular.ttf"
        "fira_mono=${pkgs.fira-mono}/share/fonts/truetype/FiraMono-Regular.ttf"
        "commit_mono=${pkgs.commit-mono}/share/fonts/truetype/CommitMono-400-Regular.ttf"
        "iosevka=${pkgs.iosevka-bin}/share/fonts/truetype/Iosevka-Regular.ttc"
        "b612=${b612File "B612-Regular.ttf" "sha256-E53OZZEAqDv5W0hHRpbkSL7pVjHvhP09BDfO0r8zz3M="}"
        "b612_bold=${b612File "B612-Bold.ttf" "sha256-kXSVQax7LDKLWIMrfixN+AnX4ro41io6WqP444snGBQ="}"
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
          # The host tests of `kerneltool site` read README.md, flake.lock and the Markdown documents; the check of the README needs its pictures; `kerneltool news check` reads news/; the check of the font of the name of the mark reads LICENSE, whose text the font carries.
          fileset = inputs.nixpkgs.lib.fileset.unions [./flake.nix ./flake.lock ./CHANGELOG.md ./changelog.d ./news ./README.md ./LICENSE (inputs.nixpkgs.lib.fileset.fileFilter (file: file.hasExt "md") ./docs) ./docs/screenshots ./boot ./contract ./kernel ./modules ./programs ./resources ./runtime ./support ./tools ./.project];
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
      // firmware
      # The source fonts: a test of the tool reads the feature "zero" of Paper Mono in them.
      // vectorFontSources);
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
