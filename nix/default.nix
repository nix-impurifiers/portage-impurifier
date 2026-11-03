# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  sourceInfo ? { },
}:
let
  inherit (pkgs) lib;
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "portage-impurifier";
    sourceInfo = {
      # Native updates must include adapter-only releases, not just engine pins.
      lastModified = pkgs.lib.max (if builtins.isAttrs coreSrc then coreSrc.lastModified or 0 else 0) (
        if builtins.isAttrs sourceInfo then sourceInfo.lastModified or 0 else 0
      );
    };
  };
  keyword =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      "amd64"
    else if pkgs.stdenv.hostPlatform.isAarch64 then
      "arm64"
    else
      throw "unsupported Portage target architecture";
  safeAtom = value: builtins.match "[A-Za-z0-9/_.+<>=!~:*?-]+" value != null;
  sessionHook = pkgs.writeText "post_emerge" ''
    #!/bin/sh
    # portage-impurifier: native-session-hook-v1
    set -eu
    # EAPI 7+ represents the root directory as an empty path variable.
    case "''${EROOT-''${ROOT-__missing__}}" in
      ""|/) [ -z "''${EPREFIX:-}" ] || exit 1 ;;
      *) echo 'portage-impurifier: refusing host activation for a foreign EROOT' >&2; exit 1 ;;
    esac
    exec /usr/sbin/nix-profile-engine reconcile
  '';
  activate = pkgs.writeText "portage-impurifier-activate" ''
    #!/usr/bin/python3
    # SPDX-License-Identifier: MIT
    import os
    from pathlib import Path
    import sys

    if os.environ.get("IMPURIFIER_TARGET_ROOT") != "/":
        print("portage-impurifier: refusing host activation for a foreign EROOT", file=sys.stderr)
        sys.exit(1)
    try:
        managed = "# portage-impurifier: native-session-hook-v1" in Path("/etc/portage/bin/post_emerge").read_text().splitlines()
    except OSError:
        managed = False
    # EMERGE_FROM is also set by the low-level ebuild tool. Only defer when
    # a live emerge ancestor will actually execute the native session hook.
    if managed:
        pid = os.getppid()
        seen = set()
        while pid > 1 and pid not in seen:
            seen.add(pid)
            try:
                args = Path("/proc/%d/cmdline" % pid).read_bytes().split(b"\0")
                if any(os.path.basename(arg) == b"emerge" for arg in args[:2]):
                    sys.exit(0)
                status = Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()
                pid = int(status[1])
            except (OSError, ValueError, IndexError):
                break
    os.execv("/usr/sbin/nix-profile-engine", ["nix-profile-engine", "reconcile"])
  '';
  eclass = pkgs.writeText "impurifier.eclass" ''
    # SPDX-License-Identifier: MIT
    # Prebuilt payload transport; application compilation remains in Nix.
    EXPORT_FUNCTIONS src_unpack src_prepare src_configure src_compile src_install pkg_postinst pkg_postrm
    impurifier_src_unpack() {
      mkdir -p "''${WORKDIR}/payload" || die
      tar -xzf "''${FILESDIR}/''${PF}-impurifier-payload.tar.gz" -C "''${WORKDIR}/payload" || die
    }
    impurifier_src_prepare() { eapply_user; }
    impurifier_src_configure() { :; }
    impurifier_src_compile() { :; }
    impurifier_src_install() { cp -a "''${S}/." "''${D}/" || die; }
    impurifier_pkg_postinst() {
      [[ "''${IMPURIFIER_ACTIVATE:-no}" == yes ]] || return 0
      [[ -x /usr/sbin/portage-impurifier-activate ]] || return 0
      env IMPURIFIER_TARGET_ROOT="''${EROOT}/" /usr/sbin/portage-impurifier-activate || die 'profile activation failed'
    }
    impurifier_pkg_postrm() {
      [[ "''${IMPURIFIER_ACTIVATE:-no}" == yes ]] || return 0
      if [[ -x /usr/sbin/portage-impurifier-activate ]]; then
        env IMPURIFIER_TARGET_ROOT="''${EROOT}/" /usr/sbin/portage-impurifier-activate || die 'profile removal activation failed'
      fi
    }
  '';
  buildEbuild =
    {
      name,
      version,
      payload,
      category ? "app-misc",
      repositoryName ? "nix-impurifiers",
      description ? "Impurified Nix application",
      license,
      licenseFiles ? { },
      activate ? false,
      dependencies ? [ ],
      buildDependencies ? [
        "app-arch/tar"
        "app-arch/gzip"
      ],
      blockers ? [ ],
    }:
    assert lib.assertMsg (
      builtins.match "[a-z0-9][a-z0-9+_-]*" name != null
      && builtins.match "[a-z0-9][a-z0-9+_-]*" category != null
    ) "invalid Portage package/category name";
    assert lib.assertMsg (
      builtins.match "[0-9]+(\\.[0-9]+)*[a-z]?(_(alpha|beta|pre|rc|p)[0-9]*)*(-r[0-9]+)?" version != null
    ) "invalid PMS version; override incompatible upstream version";
    assert lib.assertMsg (
      builtins.match "[a-z0-9][a-z0-9-]*" repositoryName != null
      && builtins.match "[^\n\r\"\\$`]+" description != null
    ) "invalid overlay metadata";
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9_.+|() -]+" license != null
    ) "invalid native license expression";
    assert lib.assertMsg (lib.all safeAtom (
      dependencies ++ buildDependencies ++ blockers
    )) "invalid Portage atom";
    pkgs.runCommand "${name}-${version}-portage-overlay"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        mkdir -p $out/{eclass,metadata,profiles,licenses,${category}/${name}/files}
        echo ${lib.escapeShellArg repositoryName} > $out/profiles/repo_name
        echo ${lib.escapeShellArg category} > $out/profiles/categories
        printf 'masters =\nprofile-formats = portage-2\n' > $out/metadata/layout.conf
        cp ${eclass} $out/eclass/impurifier.eclass
        ${lib.concatMapStringsSep "\n"
          (id: ''
            ${
              if builtins.hasAttr id licenseFiles then
                "cp ${lib.escapeShellArg (toString licenseFiles.${id})} $out/licenses/${id}"
              else
                "test -f ${pkgs.spdx-license-list-data.text}/text/${id}.txt || { echo 'Provide licenseFiles.${id} for this native license' >&2; exit 1; }; cp ${pkgs.spdx-license-list-data.text}/text/${id}.txt $out/licenses/${id}"
            }
          '')
          (
            lib.unique (
              lib.filter (id: builtins.match "[A-Za-z0-9_.+-]+" id != null) (lib.splitString " " license)
            )
          )
        }
        tar -C ${payload} --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -czf $out/${category}/${name}/files/${name}-${version}-impurifier-payload.tar.gz .
        cat > $out/${category}/${name}/${name}-${version}.ebuild <<'EBUILD'
        # SPDX-License-Identifier: MIT
        EAPI=8
        inherit impurifier
        IMPURIFIER_ACTIVATE=${if activate then "yes" else "no"}
        DESCRIPTION="${description}"
        HOMEPAGE="https://github.com/nix-impurifiers/portage-impurifier"
        SRC_URI=""
        LICENSE="${license}"
        SLOT="0"
        KEYWORDS="${keyword}"
        S="''${WORKDIR}/payload"
        BDEPEND="${lib.concatStringsSep " " buildDependencies}"
        RDEPEND="${lib.concatStringsSep " " (dependencies ++ blockers)}"
        RESTRICT="strip"
        EBUILD
        cd $out/${category}/${name}
        for path in files/* *.ebuild; do
          type=EBUILD
          entry="$path"
          case "$path" in files/*) type=AUX; entry="''${path#files/}" ;; esac
          printf '%s %s %s BLAKE2B %s SHA512 %s\n' "$type" "$entry" "$(stat -c %s "$path")" "$(b2sum "$path" | cut -d' ' -f1)" "$(sha512sum "$path" | cut -d' ' -f1)" >> Manifest
        done
      '';
  makeEbuild =
    args@{
      pkg,
      category ? "app-misc",
      hostDependencies ? null,
      license ? null,
      licenseFiles ? { },
      ...
    }:
    let
      hostBackend =
        args.hostBackend or (
          if (args.systemd or null) != null then
            "systemd"
          else if (args.runit or null) != null then
            "runit"
          else
            "openrc"
        );
      hostDeps =
        if hostDependencies != null then
          hostDependencies
        else if hostBackend == "systemd" then
          [ "sys-apps/systemd" ]
        else if hostBackend == "runit" then
          [
            "sys-process/runit"
            "sys-apps/shadow"
          ]
        else
          [
            "sys-apps/openrc"
            "sys-apps/shadow"
          ];
      packageLicenses = lib.toList (pkg.meta.license or [ ]);
      nativeLicense =
        if license != null then
          license
        else
          assert lib.assertMsg (
            packageLicenses != [ ] && lib.all (value: value ? spdxId) packageLicenses
          ) "Portage needs explicit license metadata for this application";
          lib.concatMapStringsSep " " (value: value.spdxId) packageLicenses;
      payload = core.makePayload (
        (builtins.removeAttrs args [
          "category"
          "hostDependencies"
          "license"
          "licenseFiles"
        ])
        // {
          inherit hostBackend;
        }
      );
    in
    buildEbuild {
      name = payload.packageName;
      inherit (payload) version description;
      inherit payload category licenseFiles;
      license = nativeLicense;
      activate = true;
      dependencies = [
        ">=sys-apps/portage-impurifier-${core.runtimeVersion}"
      ]
      ++ lib.optionals (payload.hostEnabled || (args.hostDependencies or null) != null) hostDeps;
      blockers = [ "!${category}/${payload.name}-${if payload.offline then "net" else "offline"}" ];
    };
  makeRuntimeOverlay =
    {
      bundledNixStore ? null,
      bundledNixNotices ? [ ],
      nixDependency ? (if bundledNixStore == null then "sys-apps/nix" else null),
      pythonDependency ? "dev-lang/python",
    }:
    let
      payload = pkgs.runCommand "portage-impurifier-runtime-payload" { } ''
        mkdir -p $out
        cp -r ${core.makeRuntimeTree { inherit bundledNixStore bundledNixNotices; }}/. $out/
        chmod -R u+w $out
        install -Dm755 ${activate} $out/usr/sbin/portage-impurifier-activate
        install -Dm755 ${sessionHook} $out/etc/portage/bin/post_emerge
      '';
    in
    buildEbuild {
      name = "portage-impurifier";
      version = core.runtimeVersion;
      category = "sys-apps";
      inherit payload;
      license = "MIT";
      activate = true;
      dependencies = lib.optional (nixDependency != null) nixDependency ++ [ pythonDependency ];
    };
  makeOverlay =
    {
      packages,
      name ? "impurifier-portage-overlay",
    }:
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.python3 ];
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        python3 - "$out" ${
          lib.concatMapStringsSep " " (value: lib.escapeShellArg (toString value)) packages
        } <<'PYTHON'
        from pathlib import Path
        import shutil, sys
        output = Path(sys.argv[1])
        categories = set()
        manifests = {}
        for source_name in sys.argv[2:]:
            source = Path(source_name)
            for path in sorted(source.rglob("*")):
                relative = path.relative_to(source)
                target = output / relative
                if path.is_symlink():
                    raise ValueError("overlay inputs must not contain symlinks: " + str(relative))
                if path.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                if str(relative) == "profiles/categories":
                    categories.update(path.read_text().splitlines())
                    continue
                if relative.name == "Manifest":
                    entries = manifests.setdefault(relative, {})
                    for entry in path.read_text().splitlines():
                        key = tuple(entry.split()[:2])
                        if key in entries and entries[key] != entry:
                            raise ValueError("conflicting manifest entry: " + str(relative))
                        entries[key] = entry
                    continue
                if target.exists() and target.read_bytes() != path.read_bytes():
                    raise ValueError("conflicting overlay file: " + str(relative))
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
        for relative, entries in manifests.items():
            (output / relative).write_text("\n".join(entries[key] for key in sorted(entries)) + "\n")
        (output / "profiles/categories").write_text("\n".join(sorted(categories)) + "\n")
        PYTHON
      '';

in
{
  inherit (core)
    engine
    offlineCache
    unit
    runtimeVersion
    ;
  inherit
    buildEbuild
    makeEbuild
    makeRuntimeOverlay
    makeOverlay
    ;
  makeNativeEbuild = args: buildEbuild (args // { activate = false; });
  runtimeOverlay = makeRuntimeOverlay { };
  makeNetEbuild = args: makeEbuild (args // { offline = false; });
  makeOfflineEbuild = args: makeEbuild (args // { offline = true; });
  makePackage = args: {
    net = makeEbuild (args // { offline = false; });
    offline = makeEbuild (args // { offline = true; });
  };
}
