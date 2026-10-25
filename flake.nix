{
  description = "Context engine with source criticism: the ce reference implementation";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: {
        default = pkgs.rustPlatform.buildRustPackage {
          pname = "ce";
          version = "0.1.0";
          src = self;
          cargoLock.lockFile = ./Cargo.lock;
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.sqlite ];
          nativeCheckInputs = [
            pkgs.sqlite
            pkgs.perl # shasum, used by the invariant tests
          ];
          # The adapters are part of the package so a host can run them
          # straight from the store path.
          postInstall = ''
            mkdir -p $out/share/ce
            cp -r adapters $out/share/ce/
          '';
        };
      });
    };
}
