# Commands

```sh
nix flake check -L
nix fmt
nix build '.#hello-offline-overlay'
```

Use a temporary `--override-input impurifier path:../impurifier --no-write-lock-file` for shared development. Publish core, converge native runtime pins, and verify published inputs before landing.
