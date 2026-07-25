// Declarations for the three functions the Zig static library exports.
// See docs/adr/0003-author-clap-project-outward.md.

#pragma once

extern "C" {
extern bool fosforo_clap_init(const char *plugin_path);
extern void fosforo_clap_deinit(void);
extern const void *fosforo_clap_get_factory(const char *factory_id);
}
