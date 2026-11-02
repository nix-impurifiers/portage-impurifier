# Architecture

EAPI 8 eclass functions unpack package-owned payload archives. Versioned AUX filenames and merged Manifest entries support multiple native versions. Runtime ownership includes a CONFIG_PROTECT-managed post_emerge hook. Phase callbacks defer only if a live emerge ancestor will execute that managed hook; direct ebuild and custom-hook cases reconcile immediately. Foreign ROOT/EPREFIX execution is rejected.

Portage post-session hook failures can be diagnostic-only native successes. Engine publication remains atomic and retryable. Native binpkgs preserve all payloads and callbacks. Native accounts, configuration and supervisors retain their own ownership rules. The shared preparation digest detects host-only changes independently of application output or migration revision.
