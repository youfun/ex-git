# iOS native build

Host development uses the top-level `Makefile` and a system libgit2. This
directory is not yet a working iOS XCFramework. Do not load ExGit in the
iOS app until device and simulator slices exist here.

Planned output:

```text
native/ios/ExGit.xcframework
```

The NIF loader already tolerates a flattened BEAM `priv` layout. Do not compile
this NIF inside a user Mix project on device.
