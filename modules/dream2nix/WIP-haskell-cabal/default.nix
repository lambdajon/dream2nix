{
  lib,
  dream2nix,
  config,
  ...
}: let
  cfg = config.haskell-cabal;

  lock = config.lock.content.haskell-cabal-lock;
  git-lock = config.lock.content.haskell-cabal-git-lock or {};

  writers = import ../../../pkgs/writers {
    inherit lib;
    inherit
      (config.deps)
      bash
      coreutils
      gawk
      writeScript
      writeScriptBin
      path
      ;
  };

  fetchCabalFile = p:
    config.deps.fetchurl {
      inherit (p.cabal) url hash;
    };

  fetchDependency = p:
    config.deps.fetchzip {
      inherit (p.src) url hash;
    };

  vendorPackage = p: ''
    echo "Vendoring ${p.name}-${p.version}"
    cp --no-preserve=all -r ${fetchDependency p} $VENDOR_DIR/${p.name}
    cp --no-preserve=all    ${fetchCabalFile p}  $VENDOR_DIR/${p.name}/${p.name}.cabal
  '';

  vendorPackages =
    builtins.concatStringsSep "\n"
    (lib.mapAttrsToList (_: vendorPackage) lock);

  fetchGitDependency = p:
    config.deps.fetchzip {
      inherit (p.src) url hash;
    };

  vendorGitPackage = p: ''
    echo "Vendoring git ${p.name}-${p.version}"
    cp --no-preserve=all -r ${fetchGitDependency p} $VENDOR_DIR/${p.name}
  '';

  vendorGitPackages =
    builtins.concatStringsSep "\n"
    (lib.mapAttrsToList (_: vendorGitPackage) git-lock);

  gitPackagesEntries =
    builtins.concatStringsSep "\n"
    (lib.mapAttrsToList
      (_: p: ''echo "packages: $VENDOR_DIR/${p.name}" >> cabal.project'')
      git-lock);
in {
  imports = [
    dream2nix.modules.dream2nix.core
    dream2nix.modules.dream2nix.mkDerivation
    ./interface.nix
  ];

  # TODO: Split build into dependencies and rest
  # TODO: Run tests

  mkDerivation = {
    nativeBuildInputs = [
      config.deps.cabal-install
      config.deps.haskell-compiler
    ];

    configurePhase = ''
      runHook preConfigure

      VENDOR_DIR="$(mktemp -d)"

      if ! test -f ./cabal.project;
      then
        {
          echo "packages: ./."
          echo "optional-packages: $VENDOR_DIR/*/*.cabal"
        } > cabal.project
      else
        echo "optional-packages: $VENDOR_DIR/*/*.cabal" >> cabal.project
      fi

      ${gitPackagesEntries}

      ${vendorPackages}
      ${vendorGitPackages}

      runHook postConfigure
    '';

    # TODO: Add options to enable/disable -j
    buildPhase = ''
      runHook preBuild

      mkdir -p $out/bin

      mkdir -p .cabal
      touch .cabal/config

      HOME=$(pwd) cabal install         \
                  --offline             \
                  --installdir $out/bin \
                  --install-method copy \
                  -j

      runHook postBuild
    '';
  };

  lock.invalidationData = {
    ghcVersionMajor = lib.versions.major config.deps.haskell-compiler.version;
    ghcVersionMinor = lib.versions.minor config.deps.haskell-compiler.version;
  };

  lock.fields.haskell-cabal-lock.script =
    writers.writePureShellScript [
      config.deps.cabal-install
      config.deps.haskell-compiler
      config.deps.coreutils
      config.deps.nix
      (config.deps.python3.withPackages (ps: with ps; [requests]))
    ] ''
      cd $TMPDIR
      cp -r --no-preserve=all ${config.mkDerivation.src}/* .
      cabal update # We need to run update or cabal will fetch invalid cabal hashes
      cabal freeze
      python3 ${./lock.py}
    '';

  lock.fields.haskell-cabal-git-lock.script =
    writers.writePureShellScript [
      config.deps.cabal-install
      config.deps.haskell-compiler
      config.deps.coreutils
      config.deps.nix
      (config.deps.python3.withPackages (ps: with ps; [requests]))
    ] ''
      cd $TMPDIR
      cp -r --no-preserve=all ${config.mkDerivation.src}/* .
      cabal update
      cabal freeze
      python3 ${./lock.py} git
    '';

  deps = {nixpkgs, ...}:
    lib.mapAttrs (_: lib.mkDefault) {
      inherit
        (nixpkgs)
        cabal-install
        python3
        fetchurl
        fetchzip
        stdenv
        coreutils
        bash
        gawk
        writeScript
        writeScriptBin
        path
        ;
      haskell-compiler = cfg.compiler;
    };
}
