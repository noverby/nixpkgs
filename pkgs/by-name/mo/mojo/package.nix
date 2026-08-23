# Mojo, built from source with Bazel.
#
# Three derivations:
#
#   - `deps` is a fixed-output derivation running `bazel build --nobuild`
#     with `--repository_cache`, keeping only the pristine content-addressed
#     downloads plus MODULE.bazel.lock, which pins every registry file by
#     hash so the offline build resolves modules from the cache alone.
#
#   - `build` replays the same analysis offline, makes the two downloaded
#     toolchains runnable in the sandbox (see prepareExternal), and runs
#     the bazel build, exporting the raw products.
#
#   - The top-level derivation does the packaging: layout, autoPatchelf,
#     wrappers, modular.cfg and smoke tests.
#
# LLVM cannot come from nixpkgs: the compiler pins llvm-project at a trunk
# commit (see bazel/public-patches/llvm_source.bzl in the source) and
# applies Modular patches on top, including an lldb-exports patch that
# mojo-lldb needs. No released LLVM has that API surface, so Bazel builds
# the patched snapshot from source as upstream intends.
{
  lib,
  stdenv,
  fetchFromGitHub,
  bazel_9,
  bash,
  python3,
  python312,
  autoPatchelfHook,
  makeWrapper,
  patchelf,
  coreutils,
  lndir,
  zlib,
  ncurses,
  libedit,
  libxml2_13,
  libbsd,
  expat,
}:
let
  # TODO before submitting: swap to the first stable tag containing the
  # open-sourced compiler (expected mojo/v1.1.0). The v1.0.0 tag predates
  # the 2026-08-18 compiler drop and has no KGEN directory, so until then
  # main is the only buildable source.
  version = "1.1.0-unstable-2026-08-23";
  rev = "10d978e3c783ef940d1d30d0a10852b69fe285c8";

  src = fetchFromGitHub {
    owner = "modular";
    repo = "modular";
    inherit rev;
    hash = "sha256-p2fzZeWAnlVBNjzGsPG2cdgjs/kU2AfQ7lkO6/E1LGo=";
  };

  mblackPythonEnv = python3.withPackages (
    ps: with ps; [
      click
      mypy-extensions
      pathspec
      platformdirs
      tomli
    ]
  );

  # Identical flags for the fetch and the build so both analyze the same
  # graph and the repository cache is complete.
  bazelFlags = lib.concatStringsSep " " [
    "--config=build-mojo"
    "--//:modular_config=production"
    "--compilation_mode=opt"
    "--//:modular_version_sha=${rev}"
    # The nix sandbox is the isolation boundary; bazel's own sandbox cannot
    # nest inside it. Output path mapping (a remote-cache-key optimization
    # from the repo's bazelrc) requires a sandboxed strategy, so switch it
    # off alongside.
    "--spawn_strategy=local"
    "--experimental_output_paths=off"
    # rules_python's default bootstrap launches py_binary stubs through
    # `/usr/bin/env python3`; the script bootstrap references the hermetic
    # interpreter by its runfiles path instead, which prepareExternal has
    # made runnable. Together they keep the sandbox free of FHS paths.
    "--@@rules_python+//python/config_settings:bootstrap_impl=script"
    # Freshly built tools (tblgen, then mojo itself compiling the stdlib)
    # run as later build actions, so they must be executable inside the
    # sandbox from the moment they are linked: give every link the nix
    # dynamic linker and the runtime-library rpath up front. Both
    # configurations, because tools build in the exec config.
    "--linkopt=-Wl,--dynamic-linker=${stdenv.cc.bintools.dynamicLinker}"
    "--host_linkopt=-Wl,--dynamic-linker=${stdenv.cc.bintools.dynamicLinker}"
    "--linkopt=-Wl,-rpath,${lib.makeLibraryPath runtimeDeps}"
    "--host_linkopt=-Wl,-rpath,${lib.makeLibraryPath runtimeDeps}"
    # Large MLIR translation units: leave headroom so parallel clang + lld
    # invocations do not OOM the builder.
    "--local_resources=memory=HOST_RAM*.67"
  ];

  sdkTargets = lib.concatStringsSep " " [
    "//KGEN:mojo" # mojo-full: driver, with MojoLLDB, lldb, lldb-server and the repl entry point as data
    "//KGEN:CompilerRT" # libKGENCompilerRTShared.so, dlopened for JIT/REPL
    "//KGEN:MojoJupyter" # libMojoJupyter.so, loaded by the jupyter kernel
    "//KGEN/tools/mojo-lsp-server"
    "//KGEN/tools/mojo-repl-entry-point"
    "@mojo//:std" # standard library, std.mojoc
    "@llvm-project//lld:lld" # the driver execs `lld -flavor gnu` for JIT
    "@llvm-project//llvm:llvm-symbolizer"
  ];

  # Runtime libraries the downloaded tools and the installed SDK link
  # against. libxml2_13: Modular's prebuilt ld.lld wants the pre-2.14
  # libxml2.so.2 SONAME, which current libxml2 (.so.16) no longer provides.
  runtimeDeps = [
    stdenv.cc.cc.lib
    zlib
    ncurses
    libedit
    libxml2_13
    expat
  ];

  bazelEnv = ''
    export HOME="$NIX_BUILD_TOP/bazel-home"
    mkdir -p "$HOME"
    export USE_BAZEL_VERSION=${bazel_9.version}

    # rules_python's host-interpreter repository probes its interpreter by
    # running it during the repository fetch, before anything can make the
    # hermetic download executable in the sandbox. Override the repository
    # with the nix interpreter of the same minor version, which is host
    # compatible by construction; rules_pycross evaluates its environment
    # markers against it. The repository name tracks rules_python's pinned
    # interpreter version, so a bump fails here visibly.
    hostPythonRepo="$NIX_BUILD_TOP/host-python-repo"
    mkdir -p "$hostPythonRepo"
    touch "$hostPythonRepo/REPO.bazel"
    {
      echo '# Replaces rules_python generated host repo; see bazelEnv.'
      echo 'exports_files(["python"], visibility = ["//visibility:public"])'
    } > "$hostPythonRepo/BUILD.bazel"
    ln -sfn ${python312}/bin/python3 "$hostPythonRepo/python"
    ln -sfn ${python312}/bin "$hostPythonRepo/bin"
    ln -sfn ${python312}/include "$hostPythonRepo/include"
    ln -sfn ${python312}/lib "$hostPythonRepo/lib"
    hostPythonOverride="--override_repository=rules_python++python+python_3_12_host=$hostPythonRepo"
  '';

  # Exactly two downloaded toolchains execute during the build and need
  # the nix dynamic linker: Modular's prebuilt clang (which compiles
  # everything) and rules_python's hermetic CPython (which runs the
  # pycross wheel installer and py_binary tools). rules_python's stage-1
  # launcher template additionally hardcodes a bare `env` and an
  # `#!/usr/bin/env bash` shebang, neither of which resolves in the
  # sandbox; point the template at the store instead.
  prepareExternal = ''
    for repo in "$HOME"/.cache/bazel/_bazel_*/*/external/+http_archive+clang-linux-* \
      "$HOME"/.cache/bazel/_bazel_*/*/external/rules_python++python+python_3_*; do
      [ -d "$repo/bin" ] || continue
      chmod -R u+w "$repo"
      while IFS= read -r -d "" f; do
        # Store paths (the overridden host-python repository links into
        # nix's own interpreter) are correct as they are and read-only.
        case "$(readlink -f "$f")" in /nix/store/*) continue ;; esac
        [ "$(head -c4 "$f")" = "$(printf '\x7fELF')" ] || continue
        patchelf --print-interpreter "$f" > /dev/null 2>&1 || continue
        patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
          --set-rpath '$ORIGIN/../lib:${lib.makeLibraryPath runtimeDeps}' "$f"
      done < <(find -L "$repo/bin" "$repo" -maxdepth 1 -type f -print0 2>/dev/null)
    done
    # The linker driver invokes llvm-ifs (and on darwin llvm-readtapi)
    # from a third prebuilt archive laid out under tools/<platform>/.
    for f in "$HOME"/.cache/bazel/_bazel_*/*/external/+http_archive+llvm-ifs/tools/*/*.stripped; do
      [ -f "$f" ] || continue
      # The archive also carries darwin Mach-O tools; only ELF is ours.
      [ "$(head -c4 "$f")" = "$(printf '\x7fELF')" ] || continue
      chmod u+w "$f"
      patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
        --set-rpath '${lib.makeLibraryPath runtimeDeps}' "$f"
    done
    for template in "$HOME"/.cache/bazel/_bazel_*/*/external/rules_python+/python/private/stage1_bootstrap_template.sh; do
      chmod u+w "$template"
      sed -i \
        -e '1s|^#!/usr/bin/env bash|#!${lib.getExe bash}|' \
        -e 's|^  env$|  ${coreutils}/bin/env|' \
        "$template"
    done
  '';

  deps = stdenv.mkDerivation {
    pname = "mojo-deps";
    inherit version src;

    postPatch = ''
      # The developer bazel wrapper regenerates build/wrapper.bazelrc and
      # probes the host toolchain, none of which works in the sandbox;
      # bazel runs fine without it. .bazelrc hard-imports the generated
      # rc, so satisfy the import with an empty file.
      rm tools/bazel
      mkdir -p build
      touch build/wrapper.bazelrc
    '';

    nativeBuildInputs = [ bazel_9 ];

    buildPhase = ''
      runHook preBuild
      ${bazelEnv}
      mkdir -p "$NIX_BUILD_TOP/repo-cache"
      bazel --batch build --nobuild --repository_cache="$NIX_BUILD_TOP/repo-cache" --repo_contents_cache= "$hostPythonOverride" ${bazelFlags} ${sdkTargets}
      runHook postBuild
    '';

    installPhase = ''
      mkdir -p $out/repo-cache
      cp -r --reflink=auto "$NIX_BUILD_TOP"/repo-cache/* $out/repo-cache/
      # The lockfile pins every registry file by hash, which is what lets
      # the offline build resolve modules from the cache alone.
      cp MODULE.bazel.lock $out/
    '';

    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-ECuL/wO47Sqc7u6JwrczudCWoq1BJNjR6S/SlU4Belo=";
  };

  # The multi-hour bazel run, exporting raw products only. Nothing in here
  # may fail after bazel succeeds, and nothing that belongs to packaging
  # (patchelf of the outputs, wrappers, checks) happens here: those live
  # in the cheap top-level derivation so they can be iterated without
  # rebuilding LLVM.
  build = stdenv.mkDerivation {
    pname = "mojo-bazel-build";
    inherit version src;

    postPatch = ''
      rm tools/bazel
      mkdir -p build
      touch build/wrapper.bazelrc
      # Toolchain helper scripts are executed directly by build actions;
      # their #!/bin/bash does not resolve inside the sandbox.
      patchShebangs --build bazel tools utils
    '';

    nativeBuildInputs = [
      bazel_9
      patchelf
      lndir
    ];

    buildPhase = ''
      runHook preBuild
      ${bazelEnv}
      # The cache must be writable even though every entry is already
      # present.
      mkdir -p repo-cache
      lndir -silent ${deps}/repo-cache repo-cache
      install -m644 ${deps}/MODULE.bazel.lock MODULE.bazel.lock
      # Extract the repositories (offline, analysis only), make the two
      # downloaded toolchains runnable, then build. Toolchain repositories
      # materialize lazily and the hermetic python can stay hidden through
      # the analysis pass, so fetch it explicitly; the repository names
      # track rules_python's pinned interpreter version, and a bump fails
      # here visibly rather than mid-build.
      bazel --batch build --nobuild --repository_cache="$PWD/repo-cache" --repo_contents_cache= "$hostPythonOverride" ${bazelFlags} ${sdkTargets}
      bazel --batch fetch --repository_cache="$PWD/repo-cache" --repo_contents_cache= "$hostPythonOverride" ${bazelFlags} \
        "@@rules_python++python+python_3_12_x86_64-unknown-linux-gnu//..." \
        "@@+http_archive+llvm-ifs//..."
      ${prepareExternal}
      bazel --batch build --repository_cache="$PWD/repo-cache" --repo_contents_cache= "$hostPythonOverride" ${bazelFlags} ${sdkTargets}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/lib/mojo $out/share

      llvmBin=bazel-bin/external/+llvm_configure+llvm-project

      install -m755 bazel-bin/KGEN/tools/mojo/mojo-full $out/bin/
      install -m755 bazel-bin/KGEN/tools/mojo-lsp-server/mojo-lsp-server $out/bin/
      install -m755 bazel-bin/KGEN/tools/mojo-repl-entry-point/mojo-repl-entry-point $out/bin/
      install -m755 $llvmBin/lldb/lldb $llvmBin/lldb/lldb-server \
        $llvmBin/lld/lld $llvmBin/llvm/llvm-symbolizer \
        $out/bin/
      install -m644 bazel-bin/mojo/stdlib/std/std.mojoc $out/lib/mojo/std.mojoc

      # Every shared library bazel produced in the target configuration,
      # deduplicated by basename: the raw pool the packaging derivation
      # selects from, so a library it turns out to need is not a
      # multi-hour rebuild away.
      while IFS= read -r -d "" so; do
        cp -Ln "$so" $out/lib/ 2>/dev/null || true
      done < <(find -L bazel-bin/ -type f \( -name '*.so' -o -name '*.so.*' \) \
        -not -path '*/_objs/*' -print0 2>/dev/null)

      # Source-tree pieces the packaging derivation re-homes: the jupyter
      # kernel spec and mblack, which are plain Python.
      cp -r KGEN/utils/jupyter-mojo/kernel $out/share/jupyter-kernel
      cp -r KGEN/tools/mblack/src $out/share/mblack-src

      runHook postInstall
    '';

    # Raw export: no strip (std.mojoc and the libraries must stay
    # byte-exact), no patchelf, no shebang rewrites.
    dontFixup = true;
  };
in
stdenv.mkDerivation {
  pname = "mojo";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  # libbsd: lldb-server links libbsd.so.0.
  buildInputs = runtimeDeps ++ [ libbsd ];
  # Optional diagnostics libraries the lldb build references but the SDK
  # runs fine without; installCheckPhase is the arbiter of "works".
  autoPatchelfIgnoreMissingDeps = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib/mojo $out/etc/modular

    install -m755 ${build}/bin/mojo-full $out/bin/mojo-unwrapped
    install -m755 ${build}/bin/mojo-lsp-server $out/bin/mojo-lsp-server-unwrapped
    install -m755 ${build}/bin/mojo-repl-entry-point $out/lib/mojo-repl-entry-point
    install -m755 ${build}/bin/lldb $out/bin/mojo-lldb-unwrapped
    install -m755 ${build}/bin/lldb-server ${build}/bin/lld \
      ${build}/bin/llvm-symbolizer $out/bin/
    # The libraries the driver and its tools load at runtime: the JIT
    # runtime (dlopened via modular.cfg defaults), the lldb plugin and
    # its liblldb, the jupyter kernel library, the Modular runtime
    # globals, and lldb's python scripting support.
    for so in \
      ${build}/lib/libKGENCompilerRTShared.so \
      ${build}/lib/libMojoLLDB.so \
      ${build}/lib/libMojoJupyter.so \
      ${build}/lib/libMSupportGlobals.so \
      ${build}/lib/libAsyncRTRuntimeGlobals.so \
      ${build}/lib/liblldb*.so* \
      ${build}/lib/libpython3*.so*; do
      install -m644 "$so" $out/lib/
    done
    install -m644 ${build}/lib/mojo/std.mojoc $out/lib/mojo/std.mojoc

    # Jupyter kernel spec sources, for a jupyter kernel package to consume.
    mkdir -p $out/share/jupyter/kernels/mojo
    install -m644 ${build}/share/jupyter-kernel/mojokernel.py \
      ${build}/share/jupyter-kernel/logo-64x64.png \
      ${build}/share/jupyter-kernel/logo.svg \
      $out/share/jupyter/kernels/mojo/

    # ld.lld is the flavor the driver asks for when it shells out.
    ln -s lld $out/bin/ld.lld

    # lldb links the sysroot's libedit (SONAME libedit.so.2); nixpkgs
    # ships the ABI-compatible library as libedit.so.0.
    ln -s ${libedit}/lib/libedit.so.0 $out/lib/libedit.so.2

    # mblack is plain Python in-tree; run it off a nixpkgs interpreter
    # rather than through bazel's hermetic CPython.
    mkdir -p $out/share/mblack
    cp -r ${build}/share/mblack-src/. $out/share/mblack/
    chmod -R u+w $out/share/mblack
    # nixpkgs' pathspec predates PathSpec.__class_getitem__ and these
    # subscripts are type annotations that CPython evaluates at import
    # time; the bare class means the same thing to a formatter.
    sed -i 's/PathSpec\[PathSpecPattern\]/PathSpec/g' \
      $out/share/mblack/mblack/files.py $out/share/mblack/mblack/__init__.py
    makeWrapper ${mblackPythonEnv}/bin/python $out/bin/mblack \
      --prefix PYTHONPATH : $out/share/mblack \
      --add-flags "-m mblack"

    # Every mojo-max.* key not named here resolves to a
    # package_root-relative default (bin/mojo, bin/lld,
    # lib/libKGENCompilerRTShared.so, ...).
    cat > $out/etc/modular/modular.cfg <<EOF
    [max]
    name = Mojo (built from source)
    version = ${version}

    [mojo-max]
    package_root = $out
    import_path = $out/lib/mojo
    lldb_path = $out/bin/mojo-lldb
    system_libs = -lrt,-ldl,-lpthread,-lm,-lz,-ltinfo
    EOF

    # The driver derives its cache and crash directories from
    # MODULAR_HOME, which must therefore be writable; give each user
    # their own under XDG and seed it with the store config.
    modularHome='"''${MODULAR_HOME:-''${XDG_CACHE_HOME:-$HOME/.cache}/mojo}"'
    for tool in mojo mojo-lldb; do
      makeWrapper $out/bin/$tool-unwrapped $out/bin/$tool \
        --run "export MODULAR_HOME=$modularHome" \
        --run 'mkdir -p "$MODULAR_HOME"' \
        --run "ln -sfn $out/etc/modular/modular.cfg \"\$MODULAR_HOME/modular.cfg\"" \
        --set-default MODULAR_CRASH_REPORTING_ENABLED 0 \
        --set-default MODULAR_TELEMETRY_ENABLED 0 \
        --set-default TERMINFO_DIRS ${ncurses}/share/terminfo
    done
    makeWrapper $out/bin/mojo-lsp-server-unwrapped $out/bin/mojo-lsp-server \
      --run "export MODULAR_HOME=$modularHome" \
      --run 'mkdir -p "$MODULAR_HOME"' \
      --run "ln -sfn $out/etc/modular/modular.cfg \"\$MODULAR_HOME/modular.cfg\"" \
      --add-flags "-I $out/lib/mojo"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    export HOME="$(mktemp -d)"

    $out/bin/mojo --version
    $out/bin/mojo-lsp-server --version
    $out/bin/mblack --version

    cd "$(mktemp -d)"
    {
      echo 'def main():'
      echo '    print("mojo built from source")'
    } > smoke.mojo
    $out/bin/mojo run smoke.mojo | grep -q "mojo built from source"
    $out/bin/mojo build smoke.mojo -o smoke
    ./smoke | grep -q "mojo built from source"

    runHook postInstallCheck
  '';

  passthru = { inherit deps build; };

  meta = {
    description = "Mojo programming language, compiler and tools built from source";
    homepage = "https://www.modular.com/mojo";
    changelog = "https://docs.modular.com/mojo/changelog";
    license = with lib.licenses; WITH asl20 llvm-exception;
    platforms = [ "x86_64-linux" ];
    maintainers = with lib.maintainers; [ overby-me ];
    mainProgram = "mojo";
  };
}
