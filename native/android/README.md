# Android native build

This directory is a reusable Android CMake subdirectory. The embedding host
must create its BEAM target first, then provide:

```cmake
set(EX_GIT_ERTS_INCLUDE_DIR "/path/to/otp/erts/include")
set(EX_GIT_BEAM_LIBRARY handbeam_probe)
add_subdirectory("/path/to/ex-git/native/android" ex_git)
```

`EX_GIT_BEAM_LIBRARY` is a **CMake target name**, not a library path. The
result is the shared target `ex_git_nif` (`libex_git_nif.so`), linked to that
existing BEAM target; this build does not compile or package another BEAM.
Each Android ABI must be configured in its own normal NDK build directory.

The build downloads checksum-pinned libgit2 1.9.7 and Mbed TLS 3.6.6 (the
maintained 3.6 LTS line). Both and the bundled libgit2 dependencies are static,
PIC inputs to the NIF. libgit2 uses Mbed TLS for HTTPS and the host's CA
bundle, builtin regex, HTTP parser and zlib; CLI, tests, examples, fuzzers,
SSH and NTLM are disabled. The NIF is linked for 16 KiB Android pages and its
ELF export surface is restricted to `nif_init`.

The parent remains responsible for choosing the Android ABI/API/toolchain and
for packaging the resulting shared object. Do not compile this NIF inside a
user Mix project on device.

Before first use of `ExGit`, configure the installed library path (without
the `.so` suffix) and a readable PEM CA bundle:

```elixir
Application.put_env(:ex_git, :nif_path, Path.join(native_library_dir, "libex_git_nif"))
Application.put_env(:ex_git, :cacertfile, ca_bundle_path)
```

These are host startup settings, not per-request options. Invalid CA paths
fail NIF loading rather than disabling verification. Desktop callers can
omit both settings to retain the usual `priv/ex_git_nif` and system trust.
