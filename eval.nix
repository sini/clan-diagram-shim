# eval.nix — Evaluate a clan flake and produce den-diagram fleet IR
#
# Usage:
#   nix eval --impure --json -f .clan-diagram-shim/eval.nix > fleet-ir.json
#
# Configuration (edit defaults or pass via --arg):
#   nix eval --impure --json -f eval.nix \
#     --arg flakePath 'toString /path/to/clan-flake' \
#     --arg withGraph true
#
# The evaluator auto-detects two clan config shapes:
#   1. flake-parts style: flake.clan.{meta,inventory}
#   2. clan-core.lib.clan style: flake.clan.{inventory} (+ flake.nixosConfigurations)
#
{
  flakePath ? toString ./.. ,
  withGraph ? true,
}:
let
  flake = builtins.getFlake flakePath;
  lib = flake.inputs.nixpkgs.lib;

  # Auto-detect clan config location
  clanConfig = flake.clan or { };
  rawInventory = clanConfig.inventory or { };

  # Access only the sub-attributes we need — avoids triggering
  # removed/deprecated option errors in the full inventory attrset
  inventory = {
    machines = rawInventory.machines or { };
    instances = rawInventory.instances or { };
  };
  clanName = (rawInventory.meta or (clanConfig.meta or { })).name or "fleet";

  # NixOS configurations — might be at flake.nixosConfigurations or flake.clan.nixosConfigurations
  nixosConfigurations =
    if withGraph then
      (flake.nixosConfigurations or (clanConfig.nixosConfigurations or { }))
    else
      { };

  ir = import ./clan-to-ir.nix {
    inherit lib clanName inventory nixosConfigurations;
    flakeInputs = if withGraph then (flake.inputs or { }) else { };
    flakeOutPath = if withGraph then (flake.outPath or null) else null;
  };
in
ir
