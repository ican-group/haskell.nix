# Copy a cabal.project file, leaving out its `source-repository-package`
# stanzas (used by the `stripSourceRepositoryPackages` shellFor wrapper).
# A stanza is its header line plus every following line that is blank, a
# comment, or indented more deeply than the header.
# A CRLF file is matched as if it were LF (and copied as it is).
{
  line = $0
  sub(/\r$/, "", line)
  match(line, /^[ \t]*/)
  indent = RLENGTH
  if (skipping) {
    if (line ~ /^[ \t]*(--.*)?$/ || indent > stanzaIndent) next
    skipping = 0
  }
  if (tolower(line) ~ /^[ \t]*source-repository-package[ \t]*(--.*)?$/) {
    skipping = 1
    stanzaIndent = indent
    next
  }
  print
}
