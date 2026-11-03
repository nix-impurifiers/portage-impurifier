# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  hardwareFixture,
  bundled ? false,
  coreSrc ? null,
}:
let
  stage3 = import ./gentoo.nix { inherit pkgs; };
  # Decompress on the build host; keep actual extraction/install behavior in QEMU.
  stageTar = pkgs.runCommand "gentoo-stage3-uncompressed.tar" { nativeBuildInputs = [ pkgs.xz ]; } ''
    xz -dc ${stage3} > "$out"
  '';
  tool =
    version:
    pkgs.runCommand "ebuild-tool-${version}"
      {
        pname = "ebuild-tool";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${version}\n' > $out/bin/ebuild-tool
        chmod +x $out/bin/ebuild-tool
      '';
  app =
    offline: version:
    impurifier.makeEbuild {
      pkg = tool version;
      inherit offline;
      license = "MIT";
      configFiles."/etc/ebuild-tool.conf" = pkgs.writeText "ebuild-config" "version=${version}\n";
    };
  daemon =
    version:
    pkgs.runCommand "ebuild-service-${version}"
      {
        pname = "ebuild-service";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        cat > $out/bin/ebuild-service <<'SCRIPT'
        #!${pkgs.busybox}/bin/sh
        echo ${version} > /var/lib/ebuild-service/version
        exec ${pkgs.busybox}/bin/sleep infinity
        SCRIPT
        chmod +x $out/bin/ebuild-service
      '';
  serviceArgs = version: {
    pkg = daemon version;
    license = "MIT";
    offline = true;
    users.ebuild-service = { };
    directories."/var/lib/ebuild-service" = {
      owner = "ebuild-service:ebuild-service";
      mode = "0750";
    };
    lifecycle = {
      onInstall = ''
        /usr/bin/python3 -c "import pwd; pwd.getpwnam('ebuild-service')"
        test -x /opt/nix/profile/bin/ebuild-service
        echo initialized > /var/lib/ebuild-service/initialized
      '';
      onUpgrade = ''
        test ! -e /run/fail-ebuild-migration
        echo ${version} > /var/lib/ebuild-service/migrated
      '';
    };
    openrc.script = pkgs.writeText "ebuild-service.init" ''
      #!/sbin/openrc-run
      command=/opt/nix/profile/bin/ebuild-service
      command_user=ebuild-service:ebuild-service
      command_background=yes
      pidfile=/run/ebuild-service.pid
    '';
  };
  service = version: impurifier.makeEbuild (serviceArgs version);
  permissionVariant = impurifier.makeEbuild (
    (serviceArgs "2")
    // {
      directories."/var/lib/ebuild-service" = {
        owner = "ebuild-service:ebuild-service";
        mode = "0700";
      };
    }
  );
  permissionOverlay = impurifier.makeOverlay {
    packages = [
      (service "1")
      permissionVariant
    ];
  };
  hostDriver =
    version:
    impurifier.buildEbuild {
      name = "impurifier-host-driver";
      inherit version;
      category = "sys-libs";
      license = "MIT";
      payload = hardwareFixture.driver version;
    };
  hardware = impurifier.makeOfflineEbuild {
    pkg = hardwareFixture.tool;
    license = "MIT";
    hostDependencies = [ "sys-libs/impurifier-host-driver" ];
    inherit (hardwareFixture) hardware;
  };
  provider = impurifier.buildEbuild {
    name = "nix-runtime-provider";
    version = "1";
    category = "sys-apps";
    license = "MIT";
    payload = pkgs.runCommand "portage-runtime-provider" { } ''
      mkdir -p $out/usr/share/impurifier-vm
      echo preinstalled > $out/usr/share/impurifier-vm/runtime
    '';
  };
  native =
    version:
    impurifier.makeNativeEbuild {
      name = "native-proof";
      inherit version;
      license = "MIT";
      payload = pkgs.runCommand "native-portage-${version}" { } ''
        mkdir -p $out/usr/libexec/native-proof $out/usr/share
        cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/usr/libexec/native-proof/busybox
        echo ${version} > $out/usr/share/native-proof-version
      '';
    };
  overlay = impurifier.makeOverlay {
    packages = [
      provider
      (native "1")
      (native "2")
      (hostDriver "1")
      (hostDriver "2")
      hardware
      (impurifier.makeRuntimeOverlay (
        {
          nixDependency = "sys-apps/nix-runtime-provider";
        }
        // pkgs.lib.optionalAttrs bundled {
          bundledNixStore = "${import (coreSrc + "/tests/static-nix.nix") { inherit pkgs; }}/bin/nix-store";
          bundledNixNotices = [ "${pkgs.nix.src}/COPYING" ];
        }
      ))
      (app false "1")
      (app true "1")
      (app true "2")
      (service "1")
      (service "2")
      (impurifier.makeOfflineEbuild {
        pkg = pkgs.hello;
        name = "batch-a";
        version = "1";
      })
      (impurifier.makeOfflineEbuild {
        pkg = pkgs.hello;
        name = "batch-b";
        version = "1";
      })
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "portage-impurifier";
  requiredFeatures = {
    kvm = false;
    devnet = false;
  };
  nodes.machine = { lib, ... }: {
    virtualisation.memorySize = 3072;
    virtualisation.diskSize = 6144;
    virtualisation.useNixStoreImage = true;
    virtualisation.writableStore = true;
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    environment.systemPackages = [
      pkgs.nix
      pkgs.gnutar
      pkgs.xz
    ];
    nix.settings.substituters = lib.mkForce [ ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/gentoo; tar xf ${stageTar} -C /srv/gentoo")
    machine.succeed("mkdir -p /srv/gentoo/nix /srv/gentoo/proc /srv/gentoo/dev /srv/gentoo/sys /srv/gentoo/opt/nix /srv/gentoo/var/lib/portage-impurifier /opt/nix /var/lib/portage-impurifier")
    machine.succeed("mount -t proc proc /srv/gentoo/proc; mount --rbind /dev /srv/gentoo/dev; mount --rbind /sys /srv/gentoo/sys; mount --bind /opt/nix /srv/gentoo/opt/nix; mount --bind /var/lib/portage-impurifier /srv/gentoo/var/lib/portage-impurifier")
    machine.succeed("cp -r ${permissionOverlay} /srv/gentoo/permission-overlay; cp -r ${overlay} /srv/gentoo/impurifiers; chmod -R u+w /srv/gentoo/impurifiers")
    machine.succeed("mkdir -p /srv/gentoo/impurifiers/profiles/test; echo 8 > /srv/gentoo/impurifiers/profiles/test/eapi; rm -f /srv/gentoo/etc/portage/make.profile; ln -s /impurifiers/profiles/test /srv/gentoo/etc/portage/make.profile")
    machine.succeed("printf 'ARCH=amd64\\nCHOST=x86_64-pc-linux-gnu\\nACCEPT_KEYWORDS=amd64\\nCONFIG_PROTECT=/etc\\n' > /srv/gentoo/impurifiers/profiles/test/make.defaults")
    machine.succeed("printf '[DEFAULT]\\nmain-repo = nix-impurifiers\\n[nix-impurifiers]\\nlocation = /impurifiers\\nauto-sync = no\\n' > /srv/gentoo/etc/portage/repos.conf")
    machine.succeed("printf 'FEATURES=\"-sandbox -usersandbox -userpriv -network-sandbox -pid-sandbox -ipc-sandbox -mount-sandbox -news -clean-logs -binpkg-signing -binpkg-request-signature\"\\nACCEPT_LICENSE=\"*\"\\nEMERGE_DEFAULT_OPTS=\"--quiet-build=y --color=n --autounmask=n\"\\n' > /srv/gentoo/etc/portage/make.conf")
    machine.succeed("systemctl stop dhcpcd; ip link set eth0 down")
    import shlex
    repositories = "[DEFAULT]\nmain-repo = nix-impurifiers\n[nix-impurifiers]\nlocation = /impurifiers\nauto-sync = no\n"
    root = "chroot /srv/gentoo /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C " + shlex.quote("PORTAGE_REPOSITORIES=" + repositories) + " "
    emerge = root + "/usr/bin/emerge --oneshot "
    with subtest("native payloads run without target Nix"):
        machine.succeed("test ! -e /srv/gentoo/nix/store && test ! -e /srv/gentoo/usr/bin/nix-store")
        machine.succeed(emerge + "=app-misc/native-proof-1")
        machine.succeed(root + "/usr/libexec/native-proof/busybox echo native-execution | grep native-execution")
        machine.succeed(emerge + "=app-misc/native-proof-2")
        machine.succeed("grep '^2$' /srv/gentoo/usr/share/native-proof-version")
        machine.succeed(root + "emerge --unmerge app-misc/native-proof")
        machine.succeed("test ! -e /srv/gentoo/usr/libexec/native-proof/busybox && test ! -e /srv/gentoo/usr/share/native-proof-version && test ! -e /srv/gentoo/nix/store")
    machine.succeed("mount --rbind /nix /srv/gentoo/nix; ln -s ${
      if bundled then
        pkgs.writeShellScript "incompatible-nix-store" "echo incompatible; exit 1"
      else
        "${pkgs.nix}/bin/nix-store"
    } /srv/gentoo/usr/bin/nix-store")
    machine.succeed(emerge + "sys-apps/portage-impurifier")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "1"))}")
    with subtest("failed substitution preserves the existing profile"):
        before = machine.succeed("readlink /opt/nix/profile").strip()
        code, output = machine.execute(emerge + "=app-misc/ebuild-tool-net-1 2>&1")
        assert "nix-profile-engine:" in output, output
        assert machine.succeed("readlink /opt/nix/profile").strip() == before
    with subtest("native blocker replacement recovers offline"):
        machine.succeed(emerge + "=app-misc/ebuild-tool-offline-1")
        machine.succeed(root + "/opt/nix/profile/bin/ebuild-tool | grep '^1$'")
    with subtest("CONFIG_PROTECT survives native flavor changes and upgrades"):
        machine.succeed("echo local > /srv/gentoo/etc/ebuild-tool.conf")
        machine.succeed(emerge + "=app-misc/ebuild-tool-net-1")
        machine.succeed("grep local /srv/gentoo/etc/ebuild-tool.conf")
        machine.succeed(emerge + "=app-misc/ebuild-tool-offline-2")
        machine.succeed(root + "/opt/nix/profile/bin/ebuild-tool | grep '^2$'")
        machine.succeed("grep local /srv/gentoo/etc/ebuild-tool.conf")
    with subtest("native emerge session batches multiple applications"):
        output = machine.succeed(emerge + "app-misc/batch-a-offline app-misc/batch-b-offline")
        assert output.count("activated ") == 1, output
        machine.succeed(root + "/opt/nix/profile/bin/hello | grep Hello")
        machine.succeed(emerge + "--unmerge app-misc/batch-a-offline app-misc/batch-b-offline")
    with subtest("native binpkg carries a complete offline closure without an ebuild"):
        machine.succeed(emerge + "--buildpkgonly =app-misc/ebuild-tool-offline-2")
        machine.succeed(emerge + "--unmerge app-misc/ebuild-tool-offline")
        machine.succeed("rm -rf /srv/gentoo/impurifiers/app-misc/ebuild-tool-offline")
        machine.succeed(root + "/usr/sbin/nix-profile-engine prune --keep 0")
        machine.succeed("nix-store --gc")
        machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "2"))}")
        machine.succeed(emerge + "--usepkgonly =app-misc/ebuild-tool-offline-2")
        machine.succeed(root + "/opt/nix/profile/bin/ebuild-tool | grep '^2$'")
    with subtest("OpenRC lifecycle uses actual Gentoo account and service tools"):
        machine.succeed("mkdir -p /srv/gentoo/run/openrc; echo default > /srv/gentoo/run/openrc/softlevel")
        machine.succeed(emerge + "=app-misc/ebuild-service-offline-1")
        machine.wait_until_succeeds("grep '^1$' /srv/gentoo/var/lib/ebuild-service/version")
        machine.succeed(root + "/sbin/rc-service ebuild-service status")
        machine.succeed(root + "stat -c %U /var/lib/ebuild-service | grep '^ebuild-service$'")
        machine.succeed("grep initialized /srv/gentoo/var/lib/ebuild-service/initialized")
        machine.succeed("touch /srv/gentoo/run/fail-ebuild-migration")
        code, output = machine.execute(emerge + "=app-misc/ebuild-service-offline-2 2>&1")
        assert "nix-profile-engine:" in output, output
        machine.succeed("grep '^1$' /srv/gentoo/var/lib/ebuild-service/version; rm /srv/gentoo/run/fail-ebuild-migration")
        machine.succeed(root + "/usr/sbin/nix-profile-engine reconcile")
        machine.wait_until_succeeds("grep '^2$' /srv/gentoo/var/lib/ebuild-service/version")
        machine.succeed("grep '^2$' /srv/gentoo/var/lib/ebuild-service/migrated")
    with subtest("host-only permission changes apply without re-running migrations"):
        machine.succeed("echo keep > /srv/gentoo/var/lib/ebuild-service/migrated; cp -r /srv/gentoo/permission-overlay/app-misc/ebuild-service-offline/. /srv/gentoo/impurifiers/app-misc/ebuild-service-offline/")
        machine.succeed(emerge + "=app-misc/ebuild-service-offline-2")
        machine.succeed("test $(stat -c %a /srv/gentoo/var/lib/ebuild-service) = 700; grep keep /srv/gentoo/var/lib/ebuild-service/migrated")
    with subtest("native downgrade preserves service stop and disable choices"):
        machine.succeed(root + "/sbin/rc-service ebuild-service stop")
        machine.succeed(root + "/sbin/rc-update del ebuild-service default")
        machine.succeed(emerge + "=app-misc/ebuild-service-offline-1")
        machine.fail(root + "/sbin/rc-service ebuild-service status")
        machine.fail("test -L /srv/gentoo/etc/runlevels/default/ebuild-service")
        machine.succeed(root + "/sbin/rc-service ebuild-service start")
        machine.succeed(emerge + "--unmerge app-misc/ebuild-service-offline")
        machine.fail(root + "/sbin/rc-service ebuild-service status")
        machine.fail("test -L /srv/gentoo/etc/runlevels/default/ebuild-service")
    with subtest("custom native post-emerge hooks remain usable"):
        machine.succeed("cp /srv/gentoo/etc/portage/bin/post_emerge /srv/gentoo/post-emerge.saved; printf '#!/bin/sh\\necho custom > /run/custom-post-emerge\\n' > /srv/gentoo/etc/portage/bin/post_emerge")
        machine.succeed(emerge + "app-misc/batch-a-offline")
        machine.succeed(root + "/opt/nix/profile/bin/hello | grep Hello")
        machine.succeed("grep custom /srv/gentoo/run/custom-post-emerge")
        machine.succeed(emerge + "sys-apps/portage-impurifier")
        machine.succeed("grep 'echo custom' /srv/gentoo/etc/portage/bin/post_emerge")
        machine.succeed(emerge + "--unmerge app-misc/batch-a-offline")
        machine.fail("test -e /opt/nix/profile/bin/hello")
        machine.succeed("cp /srv/gentoo/post-emerge.saved /srv/gentoo/etc/portage/bin/post_emerge")
    with subtest("foreign ROOT cannot activate the host profile"):
        before = machine.succeed("readlink /opt/nix/profile").strip()
        code, output = machine.execute(root + "ROOT=/foreign-root /usr/bin/emerge --oneshot --nodeps =app-misc/ebuild-tool-net-1 2>&1")
        assert "refusing host activation for a foreign EROOT" in output, output
        assert machine.succeed("readlink /opt/nix/profile").strip() == before
    with subtest("direct ebuild merges activate without an emerge session hook"):
        machine.succeed(root + "/usr/bin/ebuild /impurifiers/app-misc/batch-a-offline/batch-a-offline-1.ebuild clean merge")
        machine.succeed(root + "/opt/nix/profile/bin/hello | grep Hello")
        machine.succeed(emerge + "--unmerge app-misc/batch-a-offline")
    with subtest("explicit host dependencies install a native driver for a CLI application"):
        machine.succeed("mkdir -p /srv/gentoo/etc/portage/package.mask; echo '=sys-libs/impurifier-host-driver-2' > /srv/gentoo/etc/portage/package.mask/driver-fixture")
        machine.succeed(emerge + "app-misc/hardware-tool-offline")
        machine.succeed(root + "/opt/nix/profile/bin/hardware-tool | grep '^1$'")
        machine.succeed("rm /srv/gentoo/etc/portage/package.mask/driver-fixture")
        machine.succeed(emerge + "=sys-libs/impurifier-host-driver-2")
        machine.succeed(root + "/opt/nix/profile/bin/hardware-tool | grep '^2$'")
        machine.succeed(emerge + "--unmerge app-misc/hardware-tool-offline sys-libs/impurifier-host-driver")
    with subtest("native removal releases profile intent while retaining edited config"):
        machine.succeed("nix-store --gc")
        machine.succeed(root + "/opt/nix/profile/bin/ebuild-tool | grep '^2$'")
        machine.succeed(emerge + "--unmerge app-misc/ebuild-tool-offline")
        machine.fail("test -e /opt/nix/profile/bin/ebuild-tool")
        machine.succeed("grep local /srv/gentoo/etc/ebuild-tool.conf")
        machine.succeed(root + "/usr/sbin/nix-profile-engine prune --keep 0")
  '';
}
