# Use the same effective metadata in own, dependency and build-tool indexes.
#
# `viaRedirect` writes the revised `.cabal` with a shell redirect instead of
# `cp`.  `cp --no-preserve=mode` sets the copy's mode explicitly, which
# fails with "setting permissions ...: Permission denied" when the target
# is in `$out` on the darwin-hosted Linux builders (their /nix/store is a
# VirtioFS share).  A redirect just creates the file.
{ fragment, target, copyOptions ? "", singleLine ? false, viaRedirect ? false }:
if fragment.cabalFile != null
then (if viaRedirect
      then "cat ${fragment.cabalFile} > ${target}"
      else "cp${copyOptions} ${fragment.cabalFile} ${target}")
else if singleLine
then "tar -xOzf ${fragment.tarball} ${fragment.pkgName}-${fragment.pkgVersion}/${fragment.pkgName}.cabal > ${target}"
else ''
  tar -xOzf ${fragment.tarball} \
    ${fragment.pkgName}-${fragment.pkgVersion}/${fragment.pkgName}.cabal \
    > ${target}
''
