# portage-impurifier

Build Portage overlays that transport Nix applications through native ebuilds
and binpkgs. Portage owns descriptors, configuration and service integration;
the shared [impurifier engine](https://github.com/nix-impurifiers/impurifier)
realizes closures and atomically publishes `/opt/nix/profile`.
Original project code is MIT licensed. Application licenses remain their own.

```nix
let
  impurifier = inputs.portage-impurifier.lib.portage-impurifier { inherit pkgs; };
in impurifier.makeOverlay {
  packages = [
    impurifier.runtimeOverlay
    (impurifier.makeOfflineEbuild { pkg = pkgs.hello; })
  ];
}
```

Install the resulting overlay at a persistent location, register it in
`/etc/portage/repos.conf`, then use `emerge sys-apps/portage-impurifier
app-misc/hello-offline`. Nix and Python must already be available through native
providers. `makeRuntimeOverlay { nixDependency = "your-category/nix"; }`
selects your provider; providing/installing Nix itself is deferred.

`makeNetEbuild`, `makeOfflineEbuild` and `makePackage` accept the shared
application arguments, including configuration, users, directories, lifecycle
hooks and explicit hardware bindings. `makePackage` returns `net` and `offline`
overlays. The two flavors use weak native blockers for automatic replacement.
Offline payloads contain the complete closure; net payloads retain the declared
installable. Neither permits arbitrary remote substitutes during offline import.
Native runtime versions derive from the pinned core source timestamp; emitted
applications require at least that runtime version. These are native dependency
metadata, not SemVer releases.

Optional arguments include `category`, `hostDependencies`, `license` and
`licenseFiles`. Explicit host dependencies apply to CLI applications too.
License metadata defaults to the application's SPDX license IDs; custom native
license names need matching `licenseFiles`. PMS-incompatible upstream versions
need an explicit `version`. `buildEbuild` emits a lower-level payload overlay;
its `activate` flag defaults to false. `makeOverlay` merges versions and Manifest
entries and rejects conflicting files.

The runtime installs Portage's native `/etc/portage/bin/post_emerge` hook to
reconcile after the session. Direct `ebuild ... merge` uses phase activation.
An existing custom hook remains protected by CONFIG_PROTECT; unless it contains
the managed hook marker, phase activation falls back to per-package execution.
Review native protected-file updates when replacing a custom hook. A failed
post_emerge hook can leave emerge reporting success: inspect diagnostics and
run `/usr/sbin/nix-profile-engine reconcile` after repair. Failed realization
keeps the previous published profile. Foreign ROOT and prefix activation are
rejected. This is a host adapter, not a sysroot installer.

OpenRC is the default service protocol, with native shadow account tools.
Explicit systemd and runit declarations select those protocols. Service/admin
intent and retry behavior follow the shared engine. Configuration uses native
CONFIG_PROTECT. Binpkgs retain payloads and phase hooks, so offline installation
does not need the original ebuild source. Native session hooks also refresh
explicit host-library snapshots when unrelated driver ebuilds change; custom
hook users can reconcile explicitly.

`nix flake check -L` boots a QEMU VM with actual pinned Gentoo stage3 userspace,
Portage, shadow and OpenRC. It tests native solving, flavor replacement,
configuration protection, source-free binpkg installation after GC, lifecycle
failure/retry, service admin intent, directory changes without binary changes,
custom hook preservation, direct ebuild activation, foreign-root safety and
native host-driver dependencies/updates. The guest uses a NixOS kernel and
preinstalled Nix; this does not claim a Gentoo boot or installer test.

## Native payloads and bundled Nix

`makeNativeEbuild { name; version; payload; license; dependencies?; ... }` emits
a native PMS overlay from a producer-prepared filesystem tree, with activation
disabled and no implicit Nix dependency. The producer supplies the target layout;
this does not relocate binaries. The Gentoo VM installs, executes, upgrades and
removes a static payload before mounting any Nix store into the native userspace.

`makeRuntimeOverlay` optionally accepts `bundledNixStore` and
`bundledNixNotices` for a static ELF client with upstream notices. This omits
the default native Nix requirement; Python remains required. Compatible external
clients take precedence, explicit `IMPURIFIER_NIX_STORE` disables fallback, and
failed mutations are never retried through another client. A separate bundled
VM repeats the native Gentoo lifecycle suite with an incompatible external
candidate. Nix provisioning remains deferred.
