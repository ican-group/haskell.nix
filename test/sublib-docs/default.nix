# Test a package set
{ stdenv, lib, util, cabalProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap, buildPackages }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "sublib-docs";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal + ''

      package *
        documentation: True
    '';
  };

  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  # Haddock is not included with cross compilers currently -- nor with a
  # stable-haskell `-target` compiler, which ghc914-sh uses for any target
  # other than the native one (musl64 too, though that is not a cross host).
  meta.disabled = haskellLib.isCrossHost || stdenv.hostPlatform.isStatic
    || !(buildPackages.haskell-nix.compiler.${compiler-nix-name}.hasHaddock or true);
  ifdInputs = {
    inherit (project) plan-nix;
  };
  run = stdenv.mkDerivation {
    name = "sublib-docs-test";

    buildCommand = ''
      exe="${packages.sublib-docs.components.exes.sublib-docs.exePath}"

      size=$(command stat --format '%s' "$exe")
      printf "size of executable $exe is $size. \n" >& 2

      # fixme: run on target platform when cross-compiled
      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.sublib-docs.components.exes.sublib-docs}/test-stdout

    '' +
    # Musl and Aarch are statically linked..
    optionalString (!stdenv.hostPlatform.isAarch32 && !stdenv.hostPlatform.isAarch64 && !stdenv.hostPlatform.isMusl) (''
      printf "checking that executable is dynamically linked to system libraries... " >& 2
    '' + optionalString (stdenv.isLinux && !stdenv.hostPlatform.isMusl) ''
      ${haskellLib.lddForTests} $exe | grep 'libc[.]so'
    '' + optionalString stdenv.isDarwin ''
      otool -L $exe |grep .dylib
    '') + ''

      printf "check that it looks like we have docs..." >& 2
      # v1 writes haddock html into
      # `share/doc/<pkg>/html/<Module>.html`; v2 uses each unit's
      # `share/doc/html/<Module>.html` (the unit-id is hashed so we
      # don't synthesise a path).  A non-anchored `find -name`
      # accepts either layout.
      test -f "$(find ${packages.sublib-docs.components.library.doc} \
                       -name 'Lib.html' -print -quit)"
      test -f "$(find ${packages.sublib-docs.components.sublibs.slib.doc} \
                       -name '*Slib.html' -print -quit)"

      # Cross-package hyperlinks (#2580): haddock only emits a link when
      # the dependency's `haddock-html`/`haddock-interfaces` fields in the
      # package DB point at its generated docs.  Otherwise it warns
      # "The documentation for the following packages are not installed"
      # and renders the name without an `href`.
      # (`-not -path '*/src/*'` skips the hyperlinked source pages.)
      printf "check that the sublib docs link to aeson's docs..." >& 2
      slib=$(find ${packages.sublib-docs.components.sublibs.slib.doc} \
                  -name 'Slib.html' -not -path '*/src/*' -print -quit)
      grep -E 'href="[^"]*aeson[^"]*#t:Value"' "$slib" > /dev/null
      echo yes >& 2

      # The link has to lead somewhere: a v2 doc slice used to point it into
      # its own copy of aeson's docs, which the slice then deleted.
      printf "check that the link to aeson's docs resolves..." >& 2
      checkAesonLink() {
        local target
        target=$(grep -oE 'href="(file://)?/[^"#]*aeson[^"#]*#t:Value' "$1" | head -1)
        target=''${target#href=\"}
        target=''${target#file://}
        target=''${target%#t:Value}
        if [ ! -f "$target" ]; then
          echo "$1 links to aeson's docs at $target, which does not exist" >& 2
          exit 1
        fi
      }
      checkAesonLink "$slib"
      echo yes >& 2
    '' + optionalString (project.pkg-set.config.builderVersion == 1) ''
      # The v2 builder's doc slices do not yet link a library's docs to
      # its own sub-libraries' docs ("could not find link destinations
      # for: Slib.Greeting").
      printf "check that the library docs link to the sublib docs..." >& 2
      grep -E 'href="[^"]*#t:Greeting"' \
        "$(find ${packages.sublib-docs.components.library.doc} \
                -name 'Lib.html' -not -path '*/src/*' -print -quit)" > /dev/null
      echo yes >& 2
    '' + ''

      # `projectHaddock` (#737): both components' docs in one directory,
      # with a contents page and an index that cover them.
      printf "check the combined project docs..." >& 2
      html=${project.projectHaddock}/share/doc/haskell-project/html
      test -f $html/index.html
      test -f $html/doc-index.html
      grep -q 'Lib' $html/index.html
      grep -q 'Slib' $html/index.html
      echo yes >& 2

      printf "check the combined docs hold only documentation..." >& 2
      if find ${project.projectHaddock} \( -name '*.a' -o -name '*.so' -o -name '*.dylib' \
           -o -name '*.hi' -o -name '*.conf' -o -name dist-newstyle \) | grep -q .; then
        echo "compiled code or package databases in the combined docs:" >& 2
        find ${project.projectHaddock} \( -name '*.a' -o -name '*.so' -o -name '*.dylib' \
           -o -name '*.hi' -o -name '*.conf' -o -name dist-newstyle \) >& 2
        exit 1
      fi
      echo yes >& 2

      printf "check every relative link in the combined docs resolves..." >& 2
      find $html -name '*.html' | while read -r f; do
        grep -oE 'href="[^"#]*' "$f" | sed 's/^href="//' | sort -u | while read -r h; do
          case "$h" in
            ""|file://*|http://*|https://*|mailto:*|javascript:*|/*) ;;
            *) if [ ! -e "$(dirname "$f")/$h" ]; then
                 echo "dangling link in $f: $h" >& 2
                 exit 1
               fi ;;
          esac
        done
      done
      echo yes >& 2

      printf "check the combined sublib docs' link to aeson's docs resolves..." >& 2
      checkAesonLink "$(find $html/sublib-docs-0.1.0.0-slib -name 'Slib.html' -not -path '*/src/*' -print -quit)"
      echo yes >& 2
    '' + optionalString (project.pkg-set.config.builderVersion == 1) ''
      # The library's link to the sublib's docs now points at the copy next
      # to it, not at the sublib's doc output in the store.
      printf "check the combined docs link between components relatively..." >& 2
      lib=$(find $html/sublib-docs-0.1.0.0 -name 'Lib.html' -not -path '*/src/*' -print -quit)
      grep -E 'href="(\.\./)+sublib-docs-0\.1\.0\.0-slib/[^"]*#t:Greeting"' "$lib" > /dev/null
      if grep -q '${packages.sublib-docs.components.sublibs.slib.doc}' "$lib"; then
        echo "Lib.html still refers to the sublib's doc output in the store" >& 2
        exit 1
      fi
      echo yes >& 2
    '' + ''

      touch $out
    '';

    meta.platforms = platforms.all;

    passthru = {
      # Used for debugging with nix repl
      inherit packages project;
    };
  };
}
