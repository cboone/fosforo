# Projects the CLAP authored in Zig out into the formats Zig cannot package on
# its own, principally the AUv2 Audio Unit that Logic Pro requires.
#
# This is NOT the main build. `zig build` alone produces a loadable .clap that
# REAPER and other CLAP-native hosts open directly, and that is the day-to-day
# development loop. CMake is only needed when the Audio Unit or the standalone
# app is wanted. See docs/adr/0003-author-clap-project-outward.md.
#
#   cmake -B build cmake/
#   cmake --build build

cmake_minimum_required(VERSION 3.21)

# OBJC and OBJCXX are required here, not just inside clap-wrapper. The AUv2
# target this project declares pulls in clap-wrapper's .mm sources, and
# enable_language() in a subdirectory does not reach the parent scope. Omitting
# them fails at link time with missing .mm.o files, preceded by three opaque
# "required internal CMake variable not set" errors during generation.
project(fosforo VERSION 0.0.0 LANGUAGES C CXX OBJC OBJCXX)

set(PRODUCT_NAME "Fosforo")
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

set(ZIG_IMPL_LIB "${REPO_ROOT}/zig-out/lib/libfosforo_impl.a")

# Always reruns. Zig maintains its own build cache, so a no-op rebuild is cheap
# and this avoids CMake and Zig disagreeing about what is stale.
add_custom_target(fosforo-zig ALL
    COMMAND ${ZIG_EXECUTABLE} build --release=fast
    WORKING_DIRECTORY ${REPO_ROOT}
    BYPRODUCTS ${ZIG_IMPL_LIB}
    COMMENT "Building the Zig implementation library"
    VERBATIM
)

add_library(fosforo-impl INTERFACE)
add_dependencies(fosforo-impl fosforo-zig)
target_link_libraries(fosforo-impl INTERFACE ${ZIG_IMPL_LIB})

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

# ---------------------------------------------------------------------------
# Narrow the sandbox claims clap-wrapper writes into the Audio Unit.
# ---------------------------------------------------------------------------

# clap-wrapper's AUv2 build helper hardcodes a resourceUsage dictionary claiming
# network.client and temporary-exception.files.all.read-write, and emits it next to
# sandboxSafe = true. Apple's AudioComponent.h treats those as mutually exclusive:
# resourceUsage describes a component that is *not* sandbox safe, and "if the
# sandboxSafe key is true, this dictionary should not be included". fosforo reads no
# files and opens no sockets, so the claims are false as well as contradictory.
#
# make_clapfirst_plugins exposes no override and the plist is written at build time
# by a generated helper executable, so the only seam is the copy that landed in the
# bundle. Registering this after make_clapfirst_plugins() returns puts it behind
# clap-wrapper's own POST_BUILD commands. Nothing signs the .component on this path,
# so there is no signature to invalidate.
#
# Upstream already agrees, just not here: clap-wrapper's AUv3 build helper omits the
# dictionary and says why. Only the AUv2 helper still emits it. Re-check when the
# clap-wrapper pin moves; the script no-ops once upstream drops it.
if(APPLE AND TARGET ${PROJECT_NAME}_auv2)
    add_custom_command(TARGET ${PROJECT_NAME}_auv2 POST_BUILD
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/narrow-au-resource-usage"
                "$<TARGET_FILE_DIR:${PROJECT_NAME}_auv2>/../Info.plist"
        COMMENT "Narrowing the AU sandbox resourceUsage claims"
        VERBATIM
    )
endif()
