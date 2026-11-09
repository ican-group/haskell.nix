# Compose cabal.project configuration blocks from a slice's closure.
#
# Input (tab separated, already `LC_ALL=C sort -u`ed): one record per
# fragment and config field,
#
#   <pkg-name> \t <stage> \t <field>: <value>
#
# plus one `<pkg-name> \t <stage> \t -` marker per fragment, so a unit that
# sets no field still counts as present at its stage.  Every record comes
# from a fragment in the slice's closure: nothing here is project-wide.
#
# Output (sorted, so independent of fragment order):
#   * `package <name>` blocks with each field all of the package's units
#     agree on (across stages and versions);
#   * `package <stage>:*` stanzas for fields that differ between a
#     package's stages.  The fork's cabal has no per-package stage
#     qualifier, and a per-package stanza applies to both stages, so such a
#     field can only be stated for a whole stage -- which reaches exactly the
#     packages that do not set it in their own block.  It is emitted only
#     when every such package agrees on the stage's value; otherwise it is
#     left to cabal's default and reported on stderr.
BEGIN { FS = "\t"; OFS = "\t" }
{
  name = $1; stage = $2; rec = $3
  present[name SUBSEP stage] = 1
  if (!(name in seenName)) { seenName[name] = 1; names[++nNames] = name }
  if (rec == "-") next
  i = index(rec, ": ")
  field = substr(rec, 1, i - 1); value = substr(rec, i + 2)
  k = name SUBSEP stage SUBSEP field
  if ((k in val) && val[k] != value) conflict[name SUBSEP field] = 1
  val[k] = value
  if (!((name SUBSEP field) in hasField)) {
    hasField[name SUBSEP field] = 1
    fields[name] = fields[name] SUBSEP field
  }
}
END {
  for (a = 1; a <= nNames; a++) {
    name = names[a]
    nf = split(substr(fields[name], 2), fl, SUBSEP)
    for (b = 1; b <= nf; b++) {
      field = fl[b]
      if ((name SUBSEP field) in conflict) {
        print "compose-config-blocks: " name ": units at one stage disagree on " field "; left unset" > "/dev/stderr"
        continue
      }
      same = 1; first = ""; firstSet = 0
      for (ps in present) {
        split(ps, pp, SUBSEP)
        if (pp[1] != name) continue
        k = name SUBSEP pp[2] SUBSEP field
        v = (k in val) ? "=" val[k] : "unset"
        if (!firstSet) { first = v; firstSet = 1 } else if (v != first) same = 0
      }
      if (same && first != "unset") {
        print "P", name, field ": " substr(first, 2)
        continue
      }
      for (ps in present) {
        split(ps, pp, SUBSEP)
        if (pp[1] != name) continue
        k = name SUBSEP pp[2] SUBSEP field
        if (!(k in val)) continue
        sk = pp[2] SUBSEP field
        if ((sk in stageVal) && stageVal[sk] != val[k]) stageConflict[sk] = 1
        stageVal[sk] = val[k]
      }
    }
  }
  for (sk in stageVal) {
    split(sk, sp, SUBSEP)
    if (sk in stageConflict) {
      print "compose-config-blocks: packages at stage " sp[1] " disagree on " sp[2] "; left unset" > "/dev/stderr"
      continue
    }
    print "S", sp[1] ":*", sp[2] ": " stageVal[sk]
  }
}
