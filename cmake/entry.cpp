// Builds the exported `clap_entry` symbol from the functions implemented in
// Zig and linked in through the static library.
//
// This is the only C++ in the project, and it exists solely because
// clap-wrapper recompiles this one file per output format. The Zig build
// deliberately does not export `clap_entry` from the static library, so there
// is nothing here to collide with. See ADR 0003.

#include <clap/clap.h>

#include "entry.h"

extern "C" {

#ifdef __GNUC__
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wattributes"
#endif

const CLAP_EXPORT struct clap_plugin_entry clap_entry = {
    CLAP_VERSION,
    fosforo_clap_init,
    fosforo_clap_deinit,
    fosforo_clap_get_factory,
};

#ifdef __GNUC__
#pragma GCC diagnostic pop
#endif
}
