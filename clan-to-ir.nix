# clan-to-ir.nix — Transforms a clan config into den-diagram fleet IR
#
# Composes two layers into one IR:
#   1. Fleet topology — machines, service instances, roles, tags from clan inventory
#   2. Module/aspect graph — per-host NixOS module import trees from .graph (nixpkgs 24.05+)
#
# Takes: { lib, clanName, inventory, nixosConfigurations ? {}, flakeInputs ? {} }
#   - inventory: the clan inventory attrset (machines, instances)
#   - nixosConfigurations: optional — if provided, .graph is extracted per host
#   - flakeInputs: optional — used to resolve store paths to input names for .graph
#
# Returns: attrset matching den-diagram's fleet-ir.json schema
{
  lib,
  clanName,
  inventory,
  nixosConfigurations ? { },
  flakeInputs ? { },
  flakeOutPath ? null,
}:
let
  inherit (lib)
    attrNames
    concatMap
    concatStringsSep
    elem
    filter
    flatten
    hasAttr
    length
    mapAttrsToList
    replaceStrings
    ;
  inherit (builtins) listToAttrs;

  machines = inventory.machines or { };
  instances = inventory.instances or { };
  machineNames = attrNames machines;

  # --- Utilities ---

  sanitize = s: replaceStrings [ "," "=" "-" "." ] [ "_" "_" "_" "_" ] s;
  mkNodeId = prefix: suffix: "${sanitize prefix}__${sanitize suffix}";
  mkNode = attrs: {
    class = "";
    classes = [ ];
    hasClass = false;
    isParametric = false;
    isPolicyDispatch = false;
    isProvider = false;
    isScope = false;
    policyName = null;
    providerPath = [ ];
    fnArgNames = [ ];
    from = null;
    to = null;
    perClass = { };
    pipes.produces = [ ];
  } // attrs;

  mkEdge = attrs: {
    label = null;
    style = "normal";
    crossHost = false;
    host = null;
  } // attrs;

  # --- Tag resolution ---

  resolveMachines =
    roleCfg:
    let
      directMachines = attrNames (roleCfg.machines or { });
      tagMachines =
        if hasAttr "tags" roleCfg then
          concatMap (
            tagName:
            if tagName == "all" then
              machineNames
            else
              filter (name: elem tagName ((machines.${name}).tags or [ ])) machineNames
          ) (attrNames roleCfg.tags)
        else
          [ ];
    in
    lib.unique (directMachines ++ tagMachines);

  # --- Fleet topology (Layer 1) ---

  rootScopeId = "fleet=${clanName}";
  rootNodeId = "scope_fleet_${sanitize clanName}";

  machineScopes = map (name: {
    scopeId = "${rootScopeId},machine=${name}";
    nodeId = "scope_fleet_${sanitize clanName}_machine_${sanitize name}";
    inherit name;
    tags = (machines.${name}).tags or [ ];
  }) machineNames;

  machineScopeMap = listToAttrs (
    map (ms: {
      name = ms.name;
      value = ms;
    }) machineScopes
  );

  # Service instance → machine role bindings
  serviceBindings = concatMap (
    instanceName:
    let
      inst = instances.${instanceName};
      moduleName = (inst.module or { }).name or instanceName;
      moduleInput = (inst.module or { }).input or "self";
      roles = inst.roles or { };
    in
    concatMap (
      roleName:
      let
        roleCfg = roles.${roleName};
        boundMachines = resolveMachines roleCfg;
      in
      map (machineName: {
        inherit instanceName moduleName moduleInput roleName machineName;
      }) boundMachines
    ) (attrNames roles)
  ) (attrNames instances);

  bindingsForMachine = machineName: filter (b: b.machineName == machineName) serviceBindings;

  allTags = lib.unique (concatMap (name: (machines.${name}).tags or [ ]) machineNames);

  # --- Module graph (Layer 2) ---
  # Resolve store paths to flake input names (from nixos-module-graph.nix)

  inputPairs =
    let
      fromInputs = concatMap (
        name:
        let
          path = builtins.tryEval (toString (flakeInputs.${name}.outPath or flakeInputs.${name}));
        in
        if path.success then
          [
            {
              storePath = path.value;
              inputName = name;
            }
          ]
        else
          [ ]
      ) (attrNames flakeInputs);
      fromSelf =
        if flakeOutPath != null then
          [
            {
              storePath = toString flakeOutPath;
              inputName = "self";
            }
          ]
        else
          [ ];
    in
    fromInputs ++ fromSelf;

  resolveFile =
    file:
    let
      matches = filter (
        p: builtins.substring 0 (builtins.stringLength p.storePath) file == p.storePath
      ) inputPairs;
      sorted = builtins.sort (
        a: b: builtins.stringLength a.storePath > builtins.stringLength b.storePath
      ) matches;
      best = if sorted != [ ] then builtins.head sorted else null;
    in
    if best != null then
      {
        input = best.inputName;
        rel = builtins.substring (builtins.stringLength best.storePath + 1) 9999 file;
      }
    else
      {
        input = "?";
        rel = file;
      };

  isNixpkgs = input: builtins.match "nixpkgs.*" input != null;

  # --- File identity parsing ---
  # .graph file strings can contain "via option" suffixes:
  #   "/nix/store/..../module.nix, via option outputs.moduleForMachine.eve"
  #   "/nix/store/..../flake.nix#nixosModules.clanCore"
  # Parse these into structured identity.

  # --- File identity parsing ---
  # .graph file strings encode provenance through multiple patterns:
  #
  #   Simple file:
  #     "/nix/store/.../nixosModules/acme.nix"
  #
  #   Single via option:
  #     "/nix/store/.../module.nix, via option outputs.moduleForMachine.eve"
  #
  #   Chained via options (clan service instantiation):
  #     "/nix/store/.../clanServices/tor/default.nix, via option
  #      _services.allServices."<clan-core>-tor".roles.server.perInstance,
  #      via option nixosModule"
  #
  #   Flake fragment:
  #     "/nix/store/.../flake.nix#nixosModules.clanCore"
  #
  # Parse these into structured identity with:
  #   - aspectName: clean module name for display
  #   - loc: the full via-option chain (how it was included)
  #   - identity: dedup key (input:relPath, ignoring via-option suffix)

  # Split a file string into base path + list of via-option segments
  splitViaOptions =
    file:
    let
      parts = builtins.split ", via option " file;
      # builtins.split returns interleaved [str, match, str, match, str]
      # Filter to just the string parts
      strings = filter builtins.isString parts;
    in
    {
      basePath = builtins.head strings;
      viaOptions = builtins.tail strings;
    };

  stripNix = s:
    let m = builtins.match "(.+)\\.nix" s;
    in if m != null then builtins.elemAt m 0 else s;

  stripPrefixes = s:
    let
      prefixes = [ "nixosModules/" "clanServices/" "modules/" ];
      go = remaining: ps:
        if ps == [ ] then remaining
        else
          let p = builtins.head ps;
          in if builtins.substring 0 (builtins.stringLength p) remaining == p
             then builtins.substring (builtins.stringLength p) 9999 remaining
             else go remaining (builtins.tail ps);
    in go s prefixes;

  # Extract a service identity from a via-option chain like:
  #   _services.allServices."<clan-core>-tor".roles.server.perInstance
  # → { service = "tor"; role = "server"; }
  parseServiceVia =
    via:
    let
      # Match: _services.allServices."<input>-name".roles.<role>.perInstance
      m1 = builtins.match ''.*allServices\."?<?([^">]+)>?-([^"]+)"?\.roles\.([^.]+)\.perInstance.*'' via;
      # Match: _services.allServices.<name>.roles.<role>.perInstance (no quotes)
      m2 = builtins.match ".*allServices\\.([^.]+)\\.roles\\.([^.]+)\\.perInstance.*" via;
    in
    if m1 != null then {
      service = builtins.elemAt m1 1;
      role = builtins.elemAt m1 2;
      source = builtins.elemAt m1 0;
    }
    else if m2 != null then {
      service = builtins.elemAt m2 0;
      role = builtins.elemAt m2 1;
      source = null;
    }
    else null;

  parseFileIdentity =
    file:
    let
      split = splitViaOptions file;
      basePath = split.basePath;
      viaOptions = split.viaOptions;

      # Split off "#fragment" (flake.nix#nixosModules.clanCore)
      fragMatch = builtins.match "(.+)#(.+)" basePath;
      hasFragment = fragMatch != null;
      filePath = if hasFragment then builtins.elemAt fragMatch 0 else basePath;
      fragment = if hasFragment then builtins.elemAt fragMatch 1 else null;

      # Resolve store path to input:relative
      r = resolveFile filePath;
      cleanRel = stripPrefixes (stripNix r.rel);

      # Try to extract service identity from via-option chain
      serviceInfo =
        let
          parsed = map parseServiceVia viaOptions;
          found = filter (x: x != null) parsed;
        in
        if found != [ ] then builtins.head found else null;

      # Build the display name
      # Clan service modules: use "service/role" identity
      # Self modules: just the clean relative path
      # External: input/cleanPath
      aspectName =
        if serviceInfo != null then "${serviceInfo.service}/${serviceInfo.role}"
        else if r.input == "self" then cleanRel
        else if cleanRel == "" && fragment != null then fragment
        else if cleanRel == "" then r.input
        else "${r.input}/${cleanRel}";

      # The full via-option chain is the loc
      loc =
        if viaOptions != [ ] then concatStringsSep " → " viaOptions
        else if fragment != null then fragment
        else null;

      displayLabel =
        if serviceInfo != null then "${serviceInfo.service}/${serviceInfo.role}"
        else aspectName;
    in
    {
      inherit (r) input;
      rel = r.rel;
      inherit viaOptions fragment loc aspectName serviceInfo;
      label = displayLabel;
      fullLabel =
        if loc != null then "${displayLabel} (via ${loc})"
        else displayLabel;
      # Identity key for dedup — same base file on same host = same node
      # Via-option variants of the same file collapse into one node
      identity = "${r.input}:${if cleanRel != "" then cleanRel else r.rel}";
    };

  # Walk a .graph tree, collecting non-nixpkgs module nodes.
  # When a nixpkgs node is encountered, skip it but recurse into ALL
  # children (not just non-nixpkgs ones) — non-nixpkgs modules may be
  # nested several levels deep through nixpkgs import chains.
  collectModules =
    depth: node:
    let
      parsed = parseFileIdentity node.file;
      skip = isNixpkgs parsed.input;
      children = node.imports or [ ];
      nonNixpkgsChildren = filter (c: !(isNixpkgs (resolveFile c.file).input)) children;
      nixpkgsCount = length children - length nonNixpkgsChildren;
    in
    if skip then
      concatMap (collectModules depth) children
    else
      [
        {
          inherit (parsed) input label fullLabel aspectName identity loc;
          inherit depth;
          nixpkgsChildren = nixpkgsCount;
          children = concatMap (collectModules (depth + 1)) nonNixpkgsChildren;
        }
      ];

  # Extract module graph for a host if nixosConfigurations is available
  hostModuleGraphs = lib.mapAttrs (
    hostName: cfg:
    let
      graph = cfg.graph or [ ];
    in
    concatMap (collectModules 0) graph
  ) nixosConfigurations;

  # Flatten a module tree into nodes + edges for a host, with dedup
  flattenModuleTree =
    hostName: modules:
    let
      ms = machineScopeMap.${hostName} or null;
      parentNodeId = if ms != null then ms.nodeId else "unknown_${sanitize hostName}";
      hostScopeId = if ms != null then ms.scopeId else "";

      go =
        parentId: mods: seen:
        builtins.foldl' (
          acc: m:
          let
            nodeId = mkNodeId parentNodeId (sanitize m.identity);
            isDuplicate = acc.seen ? ${m.identity};
            childResult = go nodeId m.children (acc.seen // { ${m.identity} = true; });
          in
          if isDuplicate then
            # Node already emitted — still emit the edge (different parent)
            # but skip creating a duplicate node
            {
              seen = childResult.seen;
              results = acc.results ++ [
                {
                  node = null; # skip
                  edge = mkEdge {
                    from = parentId;
                    to = nodeId;
                    host = hostName;
                  };
                }
              ] ++ childResult.results;
            }
          else
            {
              seen = childResult.seen // { ${m.identity} = true; };
              results = acc.results ++ [
                {
                  node = mkNode {
                    id = nodeId;
                    label = m.label;
                    fullLabel = m.fullLabel;
                    shape = if m.input == "self" then "hexagon" else "trapezoid";
                    style = if m.input == "self" then "default" else "adapter";
                    entityKind = "host";
                    entityInstance = "host:${hostName}";
                    scope = hostScopeId;
                    originalId = m.identity;
                    pathKey = m.aspectName;
                    host = hostName;
                    class = "nixos";
                    classes = [ "nixos" ];
                    hasClass = true;
                  };
                  edge = mkEdge {
                    from = parentId;
                    to = nodeId;
                    host = hostName;
                  };
                }
              ] ++ childResult.results;
            }
        ) { inherit seen; results = []; } mods;
    in
    (go parentNodeId modules { }).results;

  allModuleResults = lib.concatLists (
    mapAttrsToList (
      hostName: modules:
      if machineScopeMap ? ${hostName} then flattenModuleTree hostName modules else [ ]
    ) hostModuleGraphs
  );

  moduleNodes = filter (n: n != null) (map (r: r.node) allModuleResults);
  moduleEdges = map (r: r.edge) allModuleResults;

  # --- Assemble IR ---

  # Fleet nodes
  rootNode = mkNode {
    id = rootNodeId;
    label = "fleet: ${clanName}";
    fullLabel = "fleet: ${clanName}";
    isScope = true;
    shape = "hexagon";
    entityKind = "fleet";
    entityInstance = "fleet:${clanName}";
    scope = rootScopeId;
    originalId = rootScopeId;
    pathKey = rootScopeId;
    host = null;
  };

  machineNodes = map (
    ms:
    mkNode {
      id = ms.nodeId;
      label = "machine: ${ms.name}";
      fullLabel = "machine: ${ms.name}";
      isScope = true;
      shape = "rect";
      entityKind = "host";
      entityInstance = "host:${ms.name}";
      scope = ms.scopeId;
      originalId = ms.scopeId;
      pathKey = ms.scopeId;
      host = ms.name;
    }
  ) machineScopes;

  serviceNodes = concatMap (
    machineName:
    let
      ms = machineScopeMap.${machineName};
      instanceNames = lib.unique (map (b: b.instanceName) (bindingsForMachine machineName));
    in
    map (
      instanceName:
      mkNode {
        id = mkNodeId ms.nodeId instanceName;
        label = instanceName;
        fullLabel = "service: ${instanceName}";
        shape = "hexagon";
        entityKind = "host";
        entityInstance = "host:${machineName}";
        scope = machineScopeMap.${machineName}.scopeId;
        originalId = instanceName;
        pathKey = instanceName;
        host = machineName;
        class = "nixos";
        classes = [ "nixos" ];
        hasClass = true;
      }
    ) instanceNames
  ) machineNames;

  tagNodes = map (
    tag:
    mkNode {
      id = "tag_${sanitize tag}";
      label = "tag: ${tag}";
      fullLabel = "tag: ${tag}";
      shape = "trapezoid";
      style = "adapter";
      entityKind = "fleet";
      entityInstance = "fleet:${clanName}";
      scope = rootScopeId;
      originalId = "tag:${tag}";
      pathKey = "tag:${tag}";
      host = null;
    }
  ) allTags;

  # Fleet edges
  treeEdges = map (ms: mkEdge { from = rootNodeId; to = ms.nodeId; }) machineScopes;

  serviceEdges = concatMap (
    machineName:
    let
      ms = machineScopeMap.${machineName};
      instanceNames = lib.unique (map (b: b.instanceName) (bindingsForMachine machineName));
    in
    map (instanceName: mkEdge {
      from = ms.nodeId;
      to = mkNodeId ms.nodeId instanceName;
      host = machineName;
    }) instanceNames
  ) machineNames;

  tagEdges = concatMap (
    tag:
    map (machineName: mkEdge {
      from = "tag_${sanitize tag}";
      to = machineScopeMap.${machineName}.nodeId;
    }) (filter (name: elem tag ((machines.${name}).tags or [ ])) machineNames)
  ) allTags;

  # Cross-machine edges for shared service instances
  crossMachineEdges =
    let
      instanceMachineGroups = map (instanceName: {
        inherit instanceName;
        machines = lib.unique (
          map (b: b.machineName) (filter (b: b.instanceName == instanceName) serviceBindings)
        );
      }) (lib.unique (map (b: b.instanceName) serviceBindings));
      multiMachine = filter (im: length im.machines > 1) instanceMachineGroups;
    in
    concatMap (
      im:
      flatten (
        lib.imap0 (
          i: m1:
          map (m2: mkEdge {
            from = mkNodeId machineScopeMap.${m1}.nodeId im.instanceName;
            to = mkNodeId machineScopeMap.${m2}.nodeId im.instanceName;
            label = im.instanceName;
            style = "pipe";
            crossHost = true;
          }) (lib.drop (i + 1) im.machines)
        ) im.machines
      )
    ) multiMachine;

  # Pipes for cross-machine services
  crossServicePipes =
    let
      instanceMachineGroups = map (instanceName: {
        inherit instanceName;
        machines = lib.unique (
          map (b: b.machineName) (filter (b: b.instanceName == instanceName) serviceBindings)
        );
      }) (lib.unique (map (b: b.instanceName) serviceBindings));
      multiMachine = filter (im: length im.machines > 1) instanceMachineGroups;
    in
    listToAttrs (
      map (im: {
        name = im.instanceName;
        value = {
          producers = map (m: {
            aspect = im.instanceName;
            host = m;
            scope = machineScopeMap.${m}.scopeId;
          }) im.machines;
          consumers = map (m: {
            host = m;
            scope = machineScopeMap.${m}.scopeId;
            hasCollect = true;
            stages = [ "collect" ];
          }) im.machines;
          flows = concatMap (
            m1: map (m2: { from = m1; to = m2; pipeName = im.instanceName; }) (filter (m2: m2 != m1) im.machines)
          ) im.machines;
        };
      }) multiMachine
    );

  # Scopes
  rootScopeEntry = {
    id = rootScopeId;
    name = clanName;
    kind = "fleet";
    label = "fleet: ${clanName}";
    parent = null;
    children = map (ms: ms.scopeId) machineScopes;
    ctxKeys = [ "fleet" ];
  };

  machineScopeEntries = map (ms: {
    id = ms.scopeId;
    name = ms.name;
    kind = "host";
    label = "machine: ${ms.name}";
    parent = rootScopeId;
    children = [ ];
    ctxKeys = [ "fleet" "machine" ];
  }) machineScopes;

  # Entity instances
  rootEntityInstance = {
    id = rootNodeId;
    kind = "fleet";
    name = clanName;
    label = "fleet: ${clanName}";
    parent = null;
    scopeId = rootScopeId;
  };

  machineEntityInstances = map (ms: {
    id = ms.nodeId;
    kind = "host";
    name = ms.name;
    label = "machine: ${ms.name}";
    parent = rootNodeId;
    scopeId = ms.scopeId;
  }) machineScopes;

in
{
  direction = "LR";
  rootName = clanName;
  nodes = [ rootNode ] ++ machineNodes ++ serviceNodes ++ tagNodes ++ moduleNodes;
  edges = treeEdges ++ serviceEdges ++ tagEdges ++ crossMachineEdges ++ moduleEdges;
  scopes = [ rootScopeEntry ] ++ machineScopeEntries;
  pipes = crossServicePipes;
  entityInstances = [ rootEntityInstance ] ++ machineEntityInstances;
}
