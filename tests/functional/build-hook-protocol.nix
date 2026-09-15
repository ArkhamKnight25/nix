with import ./config.nix;

{
  a = mkDerivation {
    name = "build-hook-protocol-a";
    buildCommand = "echo a > $out";
  };

  b = mkDerivation {
    name = "build-hook-protocol-b";
    buildCommand = "echo b > $out";
  };
}
