# Markdown for a list of options, as `nixosOptionsDoc`'s `optionsNix` gives
# them (an attribute set from option name to its documentation).  Shared by
# `options-doc.nix` and `project-options-doc.nix`.
{ lib }:
let
  # `literalExpression` and `literalMD` values come through as
  # `{ _type = ...; text = ...; }`; anything else is shown as JSON.
  renderValue = v:
    if v._type or null == "literalMD" then " ${v.text}"
    else
      let text = if v._type or null == "literalExpression" then v.text else builtins.toJSON v;
      in if lib.hasInfix "\n" text
        then "\n\n```nix\n${lib.removeSuffix "\n" text}\n```"
        else " `` ${text} ``";

  description = value:
    let d = value.description or null;
    in lib.removeSuffix "\n" (if d == null then "" else d.text or d);

  # `headingLevel` is the number of `#`s; `nameOf` lets a section strip a
  # common prefix (`shell.`) from the names it shows.
  renderOption = { headingLevel ? 2, nameOf ? lib.id }: name: value:
    lib.concatStringsSep "\n\n" (lib.filter (x: x != "") [
      "${lib.fixedWidthString headingLevel "#" ""} `${nameOf name}`"
      (description value)
      "**Type**: ${lib.replaceStrings [ "<" ">" ] [ "&lt;" "&gt;" ] value.type}"
      (lib.optionalString (value ? default) "**Default**:${renderValue value.default}")
      (lib.optionalString (value.readOnly or false) "**Read only**")
      (lib.optionalString (value ? example) "**Example**:${renderValue value.example}")
    ]) + "\n";
in {
  inherit renderValue renderOption;
  renderOptions = args: optionsNix:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (renderOption args) optionsNix);
}
