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

  # Walk a .graph tree, collecting non-nixpkgs module nodes.
  # When a nixpkgs node is encountered, skip it but recurse into ALL
  # children (not just non-nixpkgs ones) — non-nixpkgs modules may be
  # nested several levels deep through nixpkgs import chains.
  collectModules =
    depth: node:
    let
      r = resolveFile node.file;
      skip = isNixpkgs r.input;
      label = if r.rel != "" then "${r.input}:${r.rel}" else r.input;
      children = node.imports or [ ];
      nonNixpkgsChildren = filter (c: !(isNixpkgs (resolveFile c.file).input)) children;
      nixpkgsCount = length children - length nonNixpkgsChildren;
    in
    if skip then
      # Skip this node, recurse ALL children to find non-nixpkgs descendants
      concatMap (collectModules depth) children
    else
      [
        {
          inherit label depth;
          input = r.input;
          rel = r.rel;
          nixpkgsChildren = nixpkgsCount;
          # For non-nixpkgs nodes, only recurse non-nixpkgs children
          # (nixpkgs children under a user module are uninteresting)
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

  # Flatten a module tree into nodes + edges for a host
  flattenModuleTree =
    hostName: modules:
    let
      ms = machineScopeMap.${hostName} or null;
      parentNodeId = if ms != null then ms.nodeId else "unknown_${sanitize hostName}";

      go =
        parentId: depth: mods:
        concatMap (
          m:
          let
            nodeId = mkNodeId parentNodeId (sanitize m.label);
            childResults = go nodeId (depth + 1) m.children;
          in
          [
            {
              node = mkNode {
                id = nodeId;
                label = m.label;
                fullLabel = m.label;
                shape = if m.input == "self" then "hexagon" else "trapezoid";
                style = if m.input == "self" then "default" else "adapter";
                entityKind = "machine";
                entityInstance = "machine:${hostName}";
                scope = "machine:${hostName}";
                originalId = m.label;
                pathKey = m.label;
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
          ]
          ++ childResults
        ) mods;
    in
    go parentNodeId 0 modules;

  allModuleResults = lib.concatLists (
    mapAttrsToList (
      hostName: modules:
      if machineScopeMap ? ${hostName} then flattenModuleTree hostName modules else [ ]
    ) hostModuleGraphs
  );

  moduleNodes = map (r: r.node) allModuleResults;
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
      entityKind = "machine";
      entityInstance = "machine:${ms.name}";
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
        entityKind = "machine";
        entityInstance = "machine:${machineName}";
        scope = "machine:${machineName}";
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
    kind = "machine";
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
    kind = "machine";
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
