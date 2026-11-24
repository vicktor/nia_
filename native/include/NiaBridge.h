// SPDX-License-Identifier: MPL-2.0
#ifndef NIA_BRIDGE_H
#define NIA_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *nia_core_new(void);
void nia_core_free(void *core);
void nia_string_free(char *text);
char *nia_last_error(void *core);
char *nia_sessions(void *core);
// Background sync uses its own connection and returns JSON (free with nia_string_free).
char *nia_sync_request(const char *request);
int32_t nia_reload_sessions(void *core);
int32_t nia_rename_session(void *core, const char *session_id, const char *new_title);
char *nia_command_marks(void *core, const char *session);
char *nia_take_ai_queries(void *core);
char *nia_take_exit_requests(void *core);
int32_t nia_confirm_exit(void *core, const char *name);
char *nia_workspace_layout(void *core);
int32_t nia_save_workspace_layout(void *core, const char *layout);
char *nia_window_workspace(void *core, const char *window_id);
int32_t nia_save_window_workspace(void *core, const char *window_id, const char *layout);
int32_t nia_move_session(void *core, const char *source, const char *target);
int32_t nia_move_session_relative(void *core, const char *source, const char *target, int32_t after);
int32_t nia_create_session(void *core, const char *name);
int32_t nia_create_remote_session(void *core, const char *name, const char *ssh_host);
int32_t nia_reconnect_remote_session(void *core, const char *name);
int32_t nia_open_session(void *core, const char *name);
int32_t nia_archive_session(void *core, const char *name);
int32_t nia_send(void *core, const char *name, const uint8_t *data, size_t len);
int32_t nia_resize(void *core, const char *name, uint16_t rows, uint16_t cols);
int32_t nia_resize_fast(void *core, const char *name, uint16_t rows, uint16_t cols);
int32_t nia_reflow(void *core, const char *name);
int32_t nia_set_session_color(void *core, const char *name, const char *color);
int32_t nia_set_scrollback_limit(void *core, uint32_t lines);
int32_t nia_scroll(void *core, const char *name, int32_t delta);
int32_t nia_scroll_at(void *core, const char *name, int32_t delta, uint16_t row, uint16_t col);
int32_t nia_jump_to_command(void *core, const char *session, int64_t command_id);
void nia_poll(void *core);
int32_t nia_maintain(void *core);
int32_t nia_flush_pending(void *core);
// Extract a verified update ZIP into a new directory, without accessing sessions.
int32_t nia_unpack_update(const char *archive, const char *destination);
char *nia_screen(void *core, const char *name);
// NIA1 little-endian binary snapshot; NULL/length 0 when the revision is unchanged.
uint8_t *nia_screen_snapshot(void *core, const char *name, uint64_t known_revision, size_t *out_len);
void nia_snapshot_free(uint8_t *bytes, size_t len);
#ifdef __cplusplus
}
#endif
#endif
