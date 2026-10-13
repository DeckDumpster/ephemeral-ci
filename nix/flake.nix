{
  # runner-env -- the container engine and git the CI runner images carry, pinned through the
  # SAME nixpkgs revision as spira's spira-env (spira/flake.nix), so the Proxmox template (107)
  # and the EC2 spill AMI resolve identical versions and an identical store path.
  # Design: brain wiki/projects/spira/designs/locked-system-deps-v3-2026-10-12.md (items 5-6).
  #
  # Bump the revision here only together with spira's flake.nix; both images are then rebuilt
  # and the spill probe (scripts/runner-env.sh expected-path) refuses an image built from any
  # other revision. uidmap (newuidmap/newgidmap) stays the distro's: it must be setuid.
  description = "runner-env: pinned container engine for the ephemeral-ci runner images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";

  # podman alone comes from an older revision: the Proxmox template runs podman 5.7.x
  # (PODMAN_SERIES in template-substrate.sh) and the shared revision above carries 5.8.8, which
  # the substrate check refuses ("MISSING podman 5.7.x -- found 5.8.8", sp-b6w7uo). This revision
  # is nixpkgs' "podman: 5.7.0 -> 5.7.1" (#469715). Move podman to 5.8.x only together with
  # PODMAN_SERIES and a rebuilt template.
  inputs.nixpkgs-podman.url = "github:NixOS/nixpkgs/326648e7d0fad79d0a6c6ff8e0d62450eb372cf2";

  outputs = { self, nixpkgs, nixpkgs-podman }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      podmanPkgs = import nixpkgs-podman { inherit system; };
    in {
      packages.${system} = {
        runner-env = pkgs.buildEnv {
          name = "runner-env";
          paths = [ podmanPkgs.podman ] ++ (with pkgs; [
            crun
            conmon
            netavark
            aardvark-dns
            slirp4netns
            passt            # provides pasta
            fuse-overlayfs
            catatonit
            git
          ]);
        };
        default = self.packages.${system}.runner-env;
      };
    };
}
