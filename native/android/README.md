# Android native build

Phase 1 uses the host `Makefile` and a system libgit2. Cross-compiling libgit2
for `arm64-v8a` and `x86_64`, then packaging `ex_git_nif.so` next to the BEAM
runtime, belongs here so Sigil never owns that toolchain.

Planned output:

```text
native/android/
  arm64-v8a/libex_git_nif.so
  x86_64/libex_git_nif.so
```

Do not compile this NIF inside a user Mix project on device.
