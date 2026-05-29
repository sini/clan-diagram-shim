{
  description = "Clan → den-diagram IR shim";

  inputs = {
    target.url = "path:/home/sini/Documents/repos/clan-configs/mic92";
    nixpkgs.follows = "target/nixpkgs";
  };

  outputs =
    { target, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      clanConfig = target.clan or { };
      rawInventory = clanConfig.inventory or { };
      clanName = (rawInventory.meta or { }).name or "fleet";

      # Extract only the fields we need — avoid triggering deprecated option errors
      inventory = {
        machines = rawInventory.machines or { };
        instances = rawInventory.instances or { };
      };

      nixosConfigurations = target.nixosConfigurations or { };

      ir = import ./clan-to-ir.nix {
        inherit lib clanName inventory nixosConfigurations;
        flakeInputs = target.inputs or { };
        flakeOutPath = target.outPath or null;
      };

      # Inventory-only IR (no NixOS eval needed)
      irNoGraph = import ./clan-to-ir.nix {
        inherit lib clanName inventory;
      };
    in
    {
      inherit ir irNoGraph;

      # Convenience: write IR to a file
      packages.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        {
          fleet-ir = pkgs.writeText "fleet-ir.json" (builtins.toJSON irNoGraph);
          fleet-ir-full = pkgs.writeText "fleet-ir.json" (builtins.toJSON ir);
        };
    };
}
