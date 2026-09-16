# iOS native build

Phase 1 uses the host `Makefile` and a system libgit2. Device and simulator
libgit2 builds, linked into an XCFramework consumed by the host app, belong
here so Sigil never owns that toolchain.

Planned output:

```text
native/ios/ExGit.xcframework
```

The NIF loader already tolerates a flattened BEAM `priv` layout. Do not compile
this NIF inside a user Mix project on device.
