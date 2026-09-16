# Android native build

Host development uses the top-level `Makefile` and a system libgit2. This
directory is not yet a working Android NDK build. Do not load ExGit on device
until `arm64-v8a` / `x86_64` shared objects exist here.

Planned output:

```text
native/android/
  arm64-v8a/libex_git_nif.so
  x86_64/libex_git_nif.so
```

Do not compile this NIF inside a user Mix project on device.
