cmake_minimum_required(VERSION 3.22)

include(FetchContent)

if(NOT ANDROID)
  message(FATAL_ERROR "ex_git_nif is an Android-only target")
endif()

if(NOT DEFINED EX_GIT_ERTS_INCLUDE_DIR OR NOT IS_DIRECTORY "${EX_GIT_ERTS_INCLUDE_DIR}")
  message(FATAL_ERROR "EX_GIT_ERTS_INCLUDE_DIR must name the directory containing erl_nif.h")
endif()

if(NOT DEFINED EX_GIT_BEAM_LIBRARY OR NOT TARGET "${EX_GIT_BEAM_LIBRARY}")
  message(FATAL_ERROR "EX_GIT_BEAM_LIBRARY must name an existing BEAM CMake target")
endif()

set(EX_GIT_LIBGIT2_VERSION "1.9.7")
set(EX_GIT_MBEDTLS_VERSION "3.6.6")

# Both upstream projects have old cmake_minimum_required declarations. Keep
# their option() calls honoring this subdirectory's normal (non-cache) values.
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)

FetchContent_Declare(
  ex_git_mbedtls
  URL "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${EX_GIT_MBEDTLS_VERSION}/mbedtls-${EX_GIT_MBEDTLS_VERSION}.tar.bz2"
  URL_HASH "SHA256=8fb65fae8dcae5840f793c0a334860a411f884cc537ea290ce1c52bb64ca007a"
)

set(ENABLE_PROGRAMS OFF)
set(ENABLE_TESTING OFF)
set(MBEDTLS_FATAL_WARNINGS OFF)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON)
set(BUILD_SHARED_LIBS OFF)
FetchContent_MakeAvailable(ex_git_mbedtls)

foreach(ex_git_mbedtls_target IN ITEMS mbedcrypto mbedx509 mbedtls)
  set_property(TARGET "${ex_git_mbedtls_target}" PROPERTY POSITION_INDEPENDENT_CODE ON)
endforeach()

FetchContent_Declare(
  ex_git_libgit2
  URL "https://github.com/libgit2/libgit2/archive/refs/tags/v${EX_GIT_LIBGIT2_VERSION}.tar.gz"
  URL_HASH "SHA256=1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7"
)
FetchContent_GetProperties(ex_git_libgit2)
if(NOT ex_git_libgit2_POPULATED)
  FetchContent_Populate(ex_git_libgit2)
endif()

# libgit2 1.9.7's finder predates mbed TLS's in-tree CMake targets. Point it
# at the archives produced above and add explicit target dependencies below.
set(EX_GIT_MBEDTLS_ARCHIVE_DIR "${ex_git_mbedtls_BINARY_DIR}/library")
set(MBEDTLS_INCLUDE_DIR "${ex_git_mbedtls_SOURCE_DIR}/include")
set(MBEDTLS_LIBRARY "${EX_GIT_MBEDTLS_ARCHIVE_DIR}/libmbedtls.a")
set(MBEDX509_LIBRARY "${EX_GIT_MBEDTLS_ARCHIVE_DIR}/libmbedx509.a")
set(MBEDCRYPTO_LIBRARY "${EX_GIT_MBEDTLS_ARCHIVE_DIR}/libmbedcrypto.a")

set(BUILD_TESTS OFF)
set(BUILD_CLI OFF)
set(BUILD_EXAMPLES OFF)
set(BUILD_FUZZERS OFF)
set(USE_SSH OFF)
set(USE_HTTPS "mbedTLS")
set(USE_HTTP_PARSER "builtin")
set(REGEX_BACKEND "builtin")
set(USE_BUNDLED_ZLIB "Bundled")
set(USE_NTLMCLIENT OFF)
set(SONAME OFF)

# The host supplies a CA bundle through :ex_git, :cacertfile before NIF load.
# Never discover the build machine's trust store for the Android target.
set(CERT_LOCATION "")
set(EX_GIT_HTTPS_SELECTOR "${ex_git_libgit2_SOURCE_DIR}/cmake/SelectHTTPSBackend.cmake")
file(READ "${EX_GIT_HTTPS_SELECTOR}" EX_GIT_HTTPS_SOURCE)
string(REPLACE "if(NOT CERT_LOCATION)" "if(NOT CERT_LOCATION AND NOT CMAKE_CROSSCOMPILING)"
  EX_GIT_HTTPS_SOURCE "${EX_GIT_HTTPS_SOURCE}")
file(WRITE "${EX_GIT_HTTPS_SELECTOR}" "${EX_GIT_HTTPS_SOURCE}")

add_subdirectory(
  "${ex_git_libgit2_SOURCE_DIR}"
  "${ex_git_libgit2_BINARY_DIR}"
  EXCLUDE_FROM_ALL
)
set_property(TARGET libgit2package PROPERTY POSITION_INDEPENDENT_CODE ON)
add_dependencies(libgit2package mbedtls mbedx509 mbedcrypto)

add_library(ex_git_nif SHARED ../../c_src/ex_git_nif.c)
target_include_directories(ex_git_nif PRIVATE
  "${EX_GIT_ERTS_INCLUDE_DIR}"
  "${ex_git_libgit2_SOURCE_DIR}/include"
)
target_compile_features(ex_git_nif PRIVATE c_std_11)
target_compile_options(ex_git_nif PRIVATE
  -Wall
  -Wextra
  -Wmissing-prototypes
  -Wno-missing-field-initializers
  -fvisibility=hidden
)
target_link_libraries(ex_git_nif PRIVATE libgit2package "${EX_GIT_BEAM_LIBRARY}")
set_target_properties(ex_git_nif PROPERTIES
  OUTPUT_NAME "ex_git_nif"
  POSITION_INDEPENDENT_CODE ON
)

set(EX_GIT_NIF_VERSION_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/ex_git_nif.exports")
file(WRITE "${EX_GIT_NIF_VERSION_SCRIPT}" "{ global: nif_init; local: *; };\n")
target_link_options(ex_git_nif PRIVATE
  "LINKER:--version-script=${EX_GIT_NIF_VERSION_SCRIPT}"
  "LINKER:-z,max-page-size=16384"
)
