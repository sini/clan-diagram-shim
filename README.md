# clan-diagram-shim

Transforms a [clan-core](https://git.clan.lol/clan/clan-core) fleet configuration into [den-diagram](https://github.com/denful/den-diagram) fleet IR for visualization.

Two-layer IR composition:

1. **Fleet topology** from clan inventory — machines, service instances, roles, tags, cross-machine pipes
2. **Module/aspect graph** from `.graph` (nixpkgs 24.05+) — per-host NixOS module import trees with dedup, input attribution, and `via option` chain parsing for service identity

## Quick start

Point the `target` input at your clan flake:

```bash
# Inventory-only (fast, no NixOS eval)
nix eval --override-input target path:/path/to/your/clan-flake \
  .#irNoGraph --json > fleet-ir.json

# Full IR with per-host module graphs (evaluates nixosConfigurations)
nix eval --override-input target path:/path/to/your/clan-flake \
  .#ir --json > fleet-ir.json
```

### Build as a package

```bash
# Inventory-only
nix build --override-input target path:/path/to/your/clan-flake .#fleet-ir
cat result

# Full IR
nix build --override-input target path:/path/to/your/clan-flake .#fleet-ir-full
cat result
```

### View the result

Load the JSON into the [den IR viewer](https://den.denful.dev/tools/ir-viewer.html):

1. Open the viewer
2. Paste the contents of `fleet-ir.json` into the text area
3. Click "Load"

Or use the included examples directly:

- [`examples/mic92-topology.json`](examples/mic92-topology.json) — inventory-only (90 nodes)
- [`examples/mic92-full.json`](examples/mic92-full.json) — full IR with module graphs (1464 nodes)

## Handling private inputs

If your clan flake has private inputs (SSH repos, local paths), override them with the included mock flake:

```bash
nix eval \
  --override-input target path:/path/to/your/clan-flake \
  --override-input target/private-repo path:./mock-flake \
  --override-input target/another-private path:./mock-flake \
  .#irNoGraph --json > fleet-ir.json
```

The mock flake provides empty `nixosModules` and a stub `packages.x86_64-linux.default`. Inventory evaluation doesn't need real module content — it only reads the structural declarations.

For the full IR (`.#ir`), mocked modules will appear in the graph as empty nodes. Real module content requires resolvable inputs.

## What it produces

### Inventory layer

| Clan concept | IR element | Node shape |
|-------------|-----------|-----------|
| Fleet (meta.name) | Root scope | hexagon |
| Machine | Host scope | rect |
| Service instance | Aspect node per host | hexagon |
| Tag group | Tag node | trapezoid |
| Multi-machine service | Cross-host pipe edges | animated |

### Module graph layer

Parses `.graph` entries with full `via option` chain resolution:

```
clanServices/tor/default.nix
  via option _services.allServices."<clan-core>-tor".roles.server.perInstance
  via option nixosModule
```

becomes aspect node `tor/server` with provenance chain in `fullLabel`.

| Module source | Node shape | Identity example |
|--------------|-----------|-----------------|
| Self (your modules) | hexagon | `acme`, `zfs`, `nftables` |
| Clan services | hexagon | `tor/server`, `borgbackup/client` |
| External inputs | trapezoid | `srvos/...`, `disko/...` |

Dedup collapses identical modules per host into single nodes with multiple edges.

## Flake outputs

| Output | Description |
|--------|-------------|
| `ir` | Full IR attrset (inventory + `.graph` module trees) |
| `irNoGraph` | Inventory-only IR attrset (no NixOS eval) |
| `packages.x86_64-linux.fleet-ir` | Inventory IR as a derivation |
| `packages.x86_64-linux.fleet-ir-full` | Full IR as a derivation |
