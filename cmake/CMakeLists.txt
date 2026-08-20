# Projects the CLAP authored in Zig out into the formats Zig cannot package on
# its own, principally the AUv2 Audio Unit that Logic Pro requires.
#
# This is NOT the main build. `zig build` alone produces a loadable .clap that
# REAPER and other CLAP-native hosts open directly, and that is the day-to-day
# development loop. CMake is only needed when the Audio Unit or the standalone
# app is wanted. See docs/adr/0003-author-clap-project-outward.md.
#
# `scripts/build-audio-unit` is how to reach this, and `zig build audio-unit` is
# how to reach that. It configures only when build/ is absent and builds
# fosforo_all, which are the two things worth getting right here:
#
#   cmake -B build cmake/                            # once per worktree
#   cmake --build build --target fosforo_all         # every time, and not fosforo_auv2

cmake_minimum_required(VERSION 3.21)

# OBJC and OBJCXX are required here, not just inside clap-wrapper. The AUv2
# target this project declares pulls in clap-wrapper's .mm sources, and
# enable_language() in a subdirectory does not reach the parent scope. Omitting
# them fails at link time with missing .mm.o files, preceded by three opaque
# "required internal CMake variable not set" errors during generation.
project(fosforo VERSION 0.0.0 LANGUAGES C CXX OBJC OBJCXX)

# Two names, deliberately different. PRODUCT_NAME is the ASCII one: it feeds
# OUTPUT_NAME below, which names the bundle files (Fosforo.clap, Fosforo.component)
# and the binaries inside them. DISPLAY_NAME is what a human reads, and matches the
# CLAP descriptor in src/clap/plugin.zig. make_clapfirst_plugins offers only the
# first, so the second is applied afterwards. See cmake/set-au-display-name.
set(PRODUCT_NAME "Fosforo")
set(DISPLAY_NAME "Fósforo")
set(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")

# Must be set before clap-wrapper is pulled in. Its shared_prologue.cmake
# compares this unguarded, so leaving it empty fails configuration with a
# confusing "Unknown arguments specified" error. Keep in step with
# LSMinimumSystemVersion in macos/Info.plist.
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Minimum macOS version" FORCE)
endif()

# clap-wrapper only selects a C++ standard when it is the top-level project,
# so pulling it in through FetchContent leaves CMAKE_CXX_STANDARD unset. Its
# sources then compile with no -std flag, std::filesystem resolves to an empty
# namespace, and the build fails deep inside clap_proxy.cpp. Setting it here is
# the consuming project's responsibility.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Let clap-wrapper fetch the SDKs it needs (AudioUnitSDK for AUv2, RtAudio and
# RtMidi for the standalone) rather than requiring them to be present.
set(CLAP_WRAPPER_DOWNLOAD_DEPENDENCIES TRUE CACHE BOOL "" FORCE)

# Pinned to a commit rather than a release tag deliberately: the clap-first
# entry point, make_clapfirst_plugins, postdates v0.9.1 and is not in any
# tagged release yet. Move to a tag once one ships that contains it.
include(FetchContent)
FetchContent_Declare(clap-wrapper
    GIT_REPOSITORY https://github.com/free-audio/clap-wrapper.git
    GIT_TAG 35f524b771ec09f54c164720bb90f271273b37d3
)
FetchContent_MakeAvailable(clap-wrapper)

# ---------------------------------------------------------------------------
# The implementation, built by Zig rather than by CMake.
# ---------------------------------------------------------------------------

find_program(ZIG_EXECUTABLE zig REQUIRED)

# Its own prefix, not the repository's zig-out, and the `impl` step rather than a
# bare `zig build`. Both halves of that exist to keep this target inside its own
# build directory.
#
# A bare `zig build` here would build far more than the archive: it also reassembles
# and ad-hoc signs zig-out/Fosforo.clap, with no identity, because the custom target
# passes none. So a CMake build silently replaced whatever `zig build
# -Dcodesign-identity=` had produced, and every check that ran afterwards read a
# different file than the one that had been signed. `scripts/build-release-bundles`
# existed in AU-then-CLAP order for exactly that reason.
#
# The prefix is the other half. `impl` alone would still write
# zig-out/lib/libfosforo_impl.a, at ReleaseFast, racing a Debug archive from any
# `zig build` running concurrently. Under its own prefix the two never meet, so this
# target has no ordering relationship with the Zig build at all.
set(ZIG_PREFIX "${CMAKE_BINARY_DIR}/zig")
set(ZIG_IMPL_LIB "${ZIG_PREFIX}/lib/libfosforo_impl.a")

# Always reruns. Zig maintains its own build cache, so a no-op rebuild is cheap
# and this avoids CMake and Zig disagreeing about what is stale.
#
# The paths are quoted for consistency with the rest of this file, and the reason
# usually given for it is wrong, which is worth recording so it is not re-argued. An
# unquoted `${VAR}` inside COMMAND splits on **semicolons**, CMake's list separator,
# and not on whitespace: measured by reading the generated build.make, where an
# unquoted variable holding `one two` emits the single argument `"one two"`, byte for
# byte what the quoted form emits, while one holding `one;two` emits two. So a
# checkout under a path containing spaces, which is ordinary on macOS, was never at
# risk here. What quoting actually buys is a path containing a semicolon, which would
# break CMake in a dozen places before reaching this one.
add_custom_target(fosforo-zig ALL
    COMMAND "${ZIG_EXECUTABLE}" build --release=fast --prefix "${ZIG_PREFIX}" impl
    WORKING_DIRECTORY "${REPO_ROOT}"
    BYPRODUCTS "${ZIG_IMPL_LIB}"
    COMMENT "Building the Zig implementation library"
    VERBATIM
)

add_library(fosforo-impl INTERFACE)
add_dependencies(fosforo-impl fosforo-zig)
target_link_libraries(fosforo-impl INTERFACE "${ZIG_IMPL_LIB}")

# Carries the CLAP headers through to entry.cpp. clap-wrapper defines this
# target when it resolves its own SDK dependencies.
target_link_libraries(fosforo-impl INTERFACE clap)

# The Apple frameworks the Zig code links against. A static archive carries no
# link dependencies of its own, so they have to be restated for the consumer.
target_link_libraries(fosforo-impl INTERFACE
    "-framework Foundation"
    "-framework Cocoa"
    "-framework Metal"
    "-framework QuartzCore"
    "-framework CoreVideo"
)

# ---------------------------------------------------------------------------
# Fan out into the plugin formats.
# ---------------------------------------------------------------------------

# AUv3 is deliberately absent: it requires the Xcode generator and buys nothing
# for output quality. See docs/adr/0011-auv2-first.md.
set(FOSFORO_FORMATS CLAP AUV2)

make_clapfirst_plugins(
    TARGET_NAME ${PROJECT_NAME}
    IMPL_TARGET fosforo-impl

    OUTPUT_NAME "${PRODUCT_NAME}"

    ENTRY_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/entry.cpp"

    BUNDLE_IDENTIFIER "com.cboone.fosforo"
    BUNDLE_VERSION ${PROJECT_VERSION}

    COPY_AFTER_BUILD FALSE

    PLUGIN_FORMATS ${FOSFORO_FORMATS}

    ASSET_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/assets

    # Effectively permanent. Logic stores the type/subtype/manufacturer triple
    # in project files, so changing either code after release makes the plugin
    # read as missing in every project that used it. The manufacturer code must
    # not be all-lowercase; those are reserved by Apple.
    AUV2_MANUFACTURER_NAME "Catamount"
    AUV2_MANUFACTURER_CODE "Ctmn"
    AUV2_SUBTYPE_CODE "Fsfr"
    AUV2_INSTRUMENT_TYPE "aufx"
)

# The CLAP built here gets CMake's default bundle plist, where CFBundleName comes
# from this property, which target_add_clap_configuration set to OUTPUT_NAME. The
# Zig-built bundle uses macos/Info.plist and already reads Fósforo, so this is what
# keeps the two agreeing. LIBRARY_OUTPUT_NAME is untouched: the file stays
# Fosforo.clap. Finder-only polish, since CLAP hosts read the descriptor, not the
# plist.
if(TARGET ${PROJECT_NAME}_clap)
    set_target_properties(${PROJECT_NAME}_clap PROPERTIES
        MACOSX_BUNDLE_BUNDLE_NAME "${DISPLAY_NAME}"
    )
endif()

# ---------------------------------------------------------------------------
# Correct the Info.plist clap-wrapper generates for the Audio Unit.
# ---------------------------------------------------------------------------

# Two passes over the same file, kept as separate scripts because they have
# different lifetimes: one is a workaround for an upstream bug that should someday
# no-op away, the other is permanent product metadata. They touch disjoint keys, so
# their order does not matter.
#
# make_clapfirst_plugins exposes no override for either, and the plist is written at
# build time by a generated helper executable, so the only seam is the copy that
# landed in the bundle. Registering these after make_clapfirst_plugins() returns puts
# them behind clap-wrapper's own POST_BUILD commands.
#
# Both must also stay *ahead* of the signing step at the end of this file. Signing
# seals Contents/Info.plist into _CodeSignature/CodeResources, so a rewrite landing
# after it invalidates the signature that sealed it.
if(APPLE AND TARGET ${PROJECT_NAME}_auv2)
    # clap-wrapper's AUv2 build helper hardcodes a resourceUsage dictionary claiming
    # network.client and temporary-exception.files.all.read-write, and emits it next to
    # sandboxSafe = true. Apple's AudioComponent.h treats those as mutually exclusive:
    # resourceUsage describes a component that is *not* sandbox safe, and "if the
    # sandboxSafe key is true, this dictionary should not be included". fosforo reads no
    # files and opens no sockets, so the claims are false as well as contradictory.
    #
    # Upstream already agrees, just not here: clap-wrapper's AUv3 build helper omits the
    # dictionary and says why. Only the AUv2 helper still emits it. Re-check when the
    # clap-wrapper pin moves; the script no-ops once upstream drops it.
    add_custom_command(TARGET ${PROJECT_NAME}_auv2 POST_BUILD
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/narrow-au-resource-usage"
                "$<TARGET_FILE_DIR:${PROJECT_NAME}_auv2>/../Info.plist"
        COMMENT "Narrowing the AU sandbox resourceUsage claims"
        VERBATIM
    )

    # The helper composes the AudioComponents name from OUTPUT_NAME, which has to stay
    # ASCII because it also names the bundle file, and describes every plugin it wraps
    # as "<name> CLAP to AU Wrapper". Neither is a string to show a user. The script
    # carries the replacements; see its header for why they are restated there rather
    # than passed from here.
    add_custom_command(TARGET ${PROJECT_NAME}_auv2 POST_BUILD
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/set-au-display-name"
                "$<TARGET_FILE_DIR:${PROJECT_NAME}_auv2>/../Info.plist"
        COMMENT "Writing the display name and description into the AU"
        VERBATIM
    )
endif()

# ---------------------------------------------------------------------------
# Sign the bundles.
# ---------------------------------------------------------------------------

# Ad-hoc by default, so a plain `cmake --build` needs no keychain, no certificate and
# no network. A release identity is a configure-time override:
#
#   cmake -B build cmake/ -DFOSFORO_CODESIGN_IDENTITY="Developer ID Application: ..."
#
# build.zig carries the same switch for the bundle it assembles, spelled
# `zig build -Dcodesign-identity=`.
set(FOSFORO_CODESIGN_IDENTITY "-" CACHE STRING
    "codesign identity for the built bundles; '-' signs ad-hoc")

# A real identity additionally gets --timestamp and --options runtime, which
# notarization rejects a submission for missing. Conditional on the identity rather
# than separate switches, so a distributable signature cannot be half-configured.
#
# Neither belongs on the ad-hoc path, for two different reasons. --timestamp contacts
# Apple's timestamp server, so it would make a plain `cmake --build` need the network,
# and an ad-hoc signature has no certificate whose expiry a timestamp could outlive.
# The hardened runtime is inert either way: entitlements and runtime restrictions
# attach to a process, and a plugin is loaded into the host's, so the host's apply. It
# is set because notarization checks for it, not because it changes how this runs.
#
# An empty list expands to nothing inside COMMAND, including under VERBATIM, so the
# ad-hoc invocation is byte-identical to what it was before this existed.
if(FOSFORO_CODESIGN_IDENTITY STREQUAL "-")
    set(FOSFORO_CODESIGN_FLAGS "")
else()
    set(FOSFORO_CODESIGN_FLAGS --timestamp --options runtime)
endif()

# The linker ad-hoc signs the Mach-O binary on arm64, which is automatic and is why
# these bundles load at all. It leaves the *bundle* unsigned: with no
# Contents/_CodeSignature, `codesign --verify` reports "code has no resources but
# signature indicates they must be present".
#
# clap-wrapper does not close this and is not going to. Its only codesign calls sign
# the generated AUv2 build helper executable, wrap_clap.cmake has none at all, and
# make_clapfirst.cmake says outright that signing is the consuming project's decision.
#
# $<TARGET_BUNDLE_DIR> rather than the $<TARGET_FILE_DIR>/.. the plist commands use,
# because those name a file inside Contents and this names the bundle itself. The
# sibling $<TARGET_BUNDLE_DIR_NAME> would read better in the COMMENT but needs CMake
# 3.24, above the floor declared at the top of this file.
#
# /usr/bin/codesign by absolute path rather than through PATH, and not via
# find_program the way ZIG_EXECUTABLE above is found. Zig's location genuinely varies;
# this one does not, and resolving it through PATH would let a wrapper or shim sign
# these bundles instead, silently, while the comment above still claimed the base-OS
# tool had run. ADR 0001 makes this macOS-only, so the path costs no portability.
function(fosforo_sign_bundle target)
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND /usr/bin/codesign --force --sign "${FOSFORO_CODESIGN_IDENTITY}"
                ${FOSFORO_CODESIGN_FLAGS} "$<TARGET_BUNDLE_DIR:${target}>"
        COMMENT "Signing the ${target} bundle"
        VERBATIM
    )
endfunction()

if(APPLE AND TARGET ${PROJECT_NAME}_auv2)
    # Last, and that is the whole point. POST_BUILD commands run in registration
    # order, and the two above rewrite Contents/Info.plist, which this seals into
    # CodeResources. Signing first would leave a component whose signature no longer
    # matches its own plist: `codesign --verify` would then report tampering rather
    # than a missing signature, which is worse than not signing at all.
    #
    # A fourth POST_BUILD command on this target belongs above this call, not below.
    fosforo_sign_bundle(${PROJECT_NAME}_auv2)
endif()

if(APPLE AND TARGET ${PROJECT_NAME}_clap)
    # Nothing rewrites this bundle after make_clapfirst_plugins() returns, so there is
    # no ordering hazard here. It is signed for the same reason the component is: it
    # fails `codesign --verify` identically without it, and one rule covering every
    # bundle is worth more than an exception that has to be explained.
    fosforo_sign_bundle(${PROJECT_NAME}_clap)
endif()
