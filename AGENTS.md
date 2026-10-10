# Style guide

Import library functions at the top in a let in block, as if it's an import statement. Like this:

```nix
{lib, config, ...}:
let
  inherit (lib) mkIf
in {
  config = mkIf true {
    option = "value";
  };
}
```

The top `let in` block shouldn't get too big, it should just be an import and shared section, don't be afraid to create more let in blocks further down, things used only once should be placed in a block right before they're used for simplicity.

For readability, large modules with many sections should be split up into readable chunks with lib.mkMerge, each chunk being a self contained unit of code.
