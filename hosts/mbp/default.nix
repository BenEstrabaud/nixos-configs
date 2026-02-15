{ pkgs, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "@admin" ];
  };

  nix.linux-builder = {
    enable = true;
    maxJobs = 4;
    config = {
      virtualisation = {
        darwin-builder = {
          diskSize = 40 * 1024;   # 40 GiB
          memorySize = 8 * 1024;  # 8 GiB
        };
        cores = 4;
      };
    };
  };

  system.stateVersion = 5;
}
