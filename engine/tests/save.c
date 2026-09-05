#include "../save.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static unsigned char first[80] = {1, 1, 7}, second[100] = {1, 1, 9};
static void expect(const char *path, const void *bytes, size_t n) {
  unsigned char buffer[200];
  FILE *f = fopen(path, "rb");
  assert(f);
  assert(fread(buffer, 1, sizeof(buffer), f) == n && !memcmp(buffer, bytes, n));
  fclose(f);
}
int main(void) {
  char dir[] = "/tmp/lemon-save-XXXXXX", other[] = "/tmp/lemon-transfer-XXXXXX";
  assert(mkdtemp(dir) && mkdtemp(other));
  char current[256], backup[256], imported[256], before[256], archive[256];
  snprintf(current, sizeof(current), "%s/Lemonade.dat", dir);
  snprintf(backup, sizeof(backup), "%s/Lemonade.dat.bak", dir);
  snprintf(imported, sizeof(imported), "%s/Lemonade.dat", other);
  snprintf(before, sizeof(before), "%s/Lemonade.before-import.dat", other);
  snprintf(archive, sizeof(archive), "%s/transfer.lemonade-save", dir);
  FILE *f = lemon_save_open(dir, 1);
  assert(f);
  fwrite(first, 1, sizeof(first), f);
  assert(lemon_save_close(f, 1));
  expect(current, first, sizeof(first));
  f = lemon_save_open(dir, 5);
  assert(f);
  fwrite(second, 1, 30, f);
  /* An interrupted worker has not reached the original CloseHandle. */
  expect(current, first, sizeof(first));
  assert(!lemon_save_close(f, 0));
  expect(current, first, sizeof(first));
  f = lemon_save_open(dir, 5);
  assert(f);
  fwrite(second, 1, sizeof(second), f);
  assert(lemon_save_close(f, 1));
  expect(current, second, sizeof(second));
  expect(backup, first, sizeof(first));
  assert(!lemon_save_export(dir, archive, 0));
  assert(!lemon_save_validate(archive));
  lemon_save_running(1);
  assert(lemon_save_import(other, archive) == LEMON_SAVE_BUSY);
  lemon_save_running(0);
  assert(!lemon_save_import(other, archive));
  expect(imported, second, sizeof(second));
  assert(!lemon_save_export(dir, archive, 1));
  assert(!lemon_save_import(other, archive));
  expect(imported, first, sizeof(first));
  expect(before, second, sizeof(second));
  f = fopen(archive, "r+b");
  assert(f);
  fseek(f, 25, SEEK_SET);
  fputc(42, f);
  fclose(f);
  assert(lemon_save_import(other, archive) == LEMON_SAVE_INVALID);
  expect(imported, first, sizeof(first));
  f = fopen(archive, "wb");
  assert(f);
  fwrite("LEMONSV1", 1, 8, f);
  fclose(f);
  assert(lemon_save_validate(archive) == LEMON_SAVE_INVALID);
  expect(imported, first, sizeof(first));
  LemonSaveStatus s;
  lemon_save_status(dir, &s);
  assert(s.available == 3 && s.revision >= 2);
  puts("PASS: interrupted save preserves checkpoint; previous backup, cross-directory transfer, "
       "pre-import recovery, busy and corrupt-file rejection");
}
