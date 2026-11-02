# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
}:
let
  net = impurifier.makeNetEbuild { pkg = pkgs.hello; };
  offline = impurifier.makeOfflineEbuild { pkg = pkgs.hello; };
  closure = pkgs.closureInfo {
    rootPaths = [
      net
      offline
    ];
  };
  overlay = impurifier.makeOverlay {
    packages = [
      net
      offline
      impurifier.runtimeOverlay
    ];
  };
in
{
  unit = impurifier.unit;
  emitter =
    pkgs.runCommand "portage-impurifier-contract"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.gnutar
        ];
      }
      ''
        bash -n ${overlay}/eclass/impurifier.eclass ${overlay}/app-misc/hello-{net,offline}/*.ebuild
        grep '^AUX hello-net-2.12.3-impurifier-payload.tar.gz ' ${overlay}/app-misc/hello-net/Manifest
        grep '^RDEPEND=">=sys-apps/portage-impurifier-${impurifier.runtimeVersion} !app-misc/hello-offline"$' ${net}/app-misc/hello-net/hello-net-2.12.3.ebuild
        test -f ${net}/licenses/GPL-3.0-or-later
        test "$(wc -l < ${closure}/store-paths)" = 2
        touch $out
      '';
  vm = import ./vm.nix {
    inherit pkgs impurifier;
    hardwareFixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  };
}
