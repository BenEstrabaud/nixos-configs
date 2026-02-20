{
  description = "NAS NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.nas = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./hosts/nas ];
    };

    checks.x86_64-linux.nas =
      nixpkgs.legacyPackages.x86_64-linux.testers.runNixOSTest
        (import ./tests/nas.nix);
  };
}
