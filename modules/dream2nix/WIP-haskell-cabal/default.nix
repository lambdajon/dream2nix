{
  lib,
  dream2nix,
  config,
  ...
}: let
  cfg = config.haskell-cabal;

  lock-content = config.lock.content.haskell-cabal-lock;
  lock = lock-content.hackage or {};
  git-lock = lock-content.git or {};

  writers = import ../../../pkgs/writers {
    inherit lib;
    inherit
      (config.deps)
      bash
      coreutils
      gawk
      git
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

  vendorGitPackage = p: ''
    echo "Vendoring git ${p.name}-${p.version}"
    cp --no-preserve=all -r ${config.deps.fetchzip {inherit (p.src) url hash;}} $VENDOR_DIR/${p.name}
    # Strip source-repository stanzas so cabal treats this as a plain local package
    # and does not try to look up or fetch the VCS source
    awk '/^source-repository/{skip=1;next} /^[^ \t]/{skip=0} !skip' \
      $VENDOR_DIR/${p.name}/${p.name}.cabal > $VENDOR_DIR/${p.name}/${p.name}.cabal.tmp
    mv $VENDOR_DIR/${p.name}/${p.name}.cabal.tmp $VENDOR_DIR/${p.name}/${p.name}.cabal
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
        # Strip source-repository-package stanzas — those packages are vendored locally
        awk '/^source-repository-package/{skip=1;next} /^[^ \t]/{skip=0} !skip' \
          cabal.project > cabal.project.tmp
        mv cabal.project.tmp cabal.project
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
      config.deps.git
      (config.deps.python3.withPackages (ps: with ps; [requests]))
    ] ''
      cd $TMPDIR
      cp -r --no-preserve=all ${config.mkDerivation.src}/* .
      cabal update # We need to run update or cabal will fetch invalid cabal hashes
      cabal freeze
      python3 ${./lock.py}
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
        git
        writeScript
        writeScriptBin
        path
        ;
      haskell-compiler = cfg.compiler;
    };
}
