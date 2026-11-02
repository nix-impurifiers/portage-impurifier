# Testing

Emitter contracts check PMS metadata, license text, Manifest entries and absence of Nix references from native archives. QEMU boots real Gentoo userspace and tests actual emerge, ebuild and binpkg transactions with network disabled and application closures initially absent. The README lists failure/recovery coverage. Preinstalled Nix is represented by a native inventory provider, not an installer. Actual Gentoo OpenRC/shadow run inside the guest; the kernel and outer boot are NixOS.
