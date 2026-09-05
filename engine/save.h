#ifndef LEMON_SAVE_H
#define LEMON_SAVE_H
#include <stdio.h>
#include <stdint.h>

enum { LEMON_SAVE_OK, LEMON_SAVE_MISSING, LEMON_SAVE_INVALID, LEMON_SAVE_BUSY, LEMON_SAVE_IO };
typedef struct {
  unsigned revision;
  int result, available; /* bit 0: current, 1: previous, 2: before import */
  int64_t saved_at;
} LemonSaveStatus;
const char *lemon_save_message(int result);
void lemon_save_status(const char *directory, LemonSaveStatus *status);
/* Archives transfer all careers, without device preferences. source is 0..2.
 * Export is allowed during play; import is rejected while the engine runs. */
int lemon_save_export(const char *directory, const char *archive, unsigned source);
int lemon_save_import(const char *directory, const char *archive);
int lemon_save_validate(const char *archive);

/* Platform adapter only: save writes go to a staging file. Only the original
 * CloseHandle commits it; shutdown/fault cleanup discards an incomplete write. */
FILE *lemon_save_open(const char *directory, unsigned creation);
int lemon_save_close(FILE *file, int commit);
void lemon_save_running(int running);
#endif
