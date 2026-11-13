{ pkgs ? import <nixpkgs> {}
, lib ? pkgs.lib
}:
let
  # Provide a dummy pkg-def for the package set function
  pkg-def = _hackage: {
    packages = {};
    compiler = {
      version = "";
      nix-name = "";
      packages = {};
    };
  };

  # Apply the package set function to get NixOS options.
  inherit (import ../package-set.nix { hackage = null; inherit pkgs pkg-def; }) options;

  optionsNix = (pkgs.nixosOptionsDoc { inherit options; }).optionsNix;

  optionsMarkdown = lib.concatStringsSep "\n" (lib.mapAttrsToList singleMarkdown optionsNix);

  singleMarkdown = name: value: ''
    ## ${name}

    ${lib.optionalString (value.description != null) (value.description.text or value.description)}

    **Type**: ${value.type}

    ${ if lib.hasAttr "default" value
       then ''
        **Default**: ${builtins.toJSON value.default}
      ''
      else "**No Default**"
    }
    ${ if value.readOnly
       then "**Read Only**"
      else ""
    }
    ${ if lib.hasAttr "example" value
       then ''
        **Example**:

        ${builtins.toJSON value.example}
      ''
      else "**No Example**"
    }

  '';

in builtins.toFile "options.md" ''
Haskell.nix modules options for packages and components.

!!! note "Generated"
    This documentation is generated from Nix sources in the
    [`modules`](https://github.com/ican-group/haskell.nix/tree/master/modules)
    subdirectory using `scripts/update-docs.nix`

# Configuration Options

${optionsMarkdown}
''
