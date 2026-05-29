{
  description = "Mock flake providing empty nixosModules and packages for private inputs";
  outputs = _: {
    nixosModules = {
      default = { };
      media = { };
      mailserver = { };
    };
    packages.x86_64-linux.default = builtins.derivation {
      name = "mock";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [ "-c" "mkdir -p $out" ];
    };
  };
}
