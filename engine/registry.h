/* Persistent Win32 registry/profile adapter. Data lives only in the native app sandbox. */
typedef struct {
  char key[512], name[128];
  uint32_t type, size;
  uint8_t data[4096];
} RegValue;
static RegValue reg_values[1024];
static uint32_t reg_count;
static struct {
  char path[512];
  int used;
} reg_handles[256];
static int registry_save(void) {
  char path[4096], temp[4096];
  snprintf(path, sizeof(path), "%s/registry.bin", save_dir);
  snprintf(temp, sizeof(temp), "%s/registry.tmp", save_dir);
  FILE *f = fopen(temp, "wb");
  if (!f)
    return 0;
  uint32_t header[] = {0x4c524547, 1, reg_count};
  int ok = fwrite(header, sizeof(header), 1, f) == 1 &&
           fwrite(reg_values, sizeof(RegValue), reg_count, f) == reg_count;
  if (fflush(f))
    ok = 0;
  if (fclose(f))
    ok = 0;
  if (ok && rename(temp, path))
    ok = 0;
  return ok;
}
static void registry_load(void) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/registry.bin", save_dir);
  FILE *f = fopen(path, "rb");
  if (!f)
    return;
  uint32_t header[3];
  if (fread(header, sizeof(header), 1, f) == 1 && header[0] == 0x4c524547 && header[1] == 1 &&
      header[2] <= 1024 && fread(reg_values, sizeof(RegValue), header[2], f) == header[2]) {
    int valid = 1;
    for (unsigned i = 0; i < header[2]; i++)
      if (reg_values[i].size > 4096 || !memchr(reg_values[i].key, 0, 512) ||
          !memchr(reg_values[i].name, 0, 128))
        valid = 0;
    if (valid)
      reg_count = header[2];
  }
  fclose(f);
}
static const char *registry_key(uint32_t h) {
  if (h == 0x80000001)
    return "HKCU";
  if (h == 0x80000002)
    return "HKLM";
  if (h == 0x80000000)
    return "HKCR";
  if (h >= 0x300 && h < 0x400 && reg_handles[h - 0x300].used)
    return reg_handles[h - 0x300].path;
  return NULL;
}
static RegValue *registry_value(const char *key, const char *name) {
  for (unsigned i = 0; i < reg_count; i++)
    if (!strcasecmp(reg_values[i].key, key) && !strcasecmp(reg_values[i].name, name))
      return &reg_values[i];
  return NULL;
}
static uint32_t registry_set(const char *key, const char *name, uint32_t type, const void *data,
                             uint32_t n) {
  if (!key)
    return 6;
  if (strlen(key) >= 512 || strlen(name) >= 128 || n > 4096)
    return 234;
  RegValue *v = registry_value(key, name);
  if (!v) {
    if (reg_count == 1024)
      return 8;
    v = &reg_values[reg_count++];
    snprintf(v->key, 512, "%s", key);
    snprintf(v->name, 128, "%s", name);
  }
  v->type = type;
  v->size = n;
  if (n)
    memcpy(v->data, data, n);
  return registry_save() ? 0 : 5;
}
static uint32_t registry_open(uint32_t root, const char *sub, int create, uint32_t *handle,
                              uint32_t *disposition) {
  const char *parent = registry_key(root);
  if (!parent)
    return 6;
  char path[512];
  if (snprintf(path, sizeof(path), "%s%s%s", parent, *sub ? "\\" : "", sub) >= sizeof(path))
    return 234;
  int exists = 0;
  for (unsigned i = 0; i < reg_count; i++)
    if (!strcasecmp(reg_values[i].key, path)) {
      exists = 1;
      break;
    }
  if (!exists && !create)
    return 2;
  if (!exists) {
    uint32_t r = registry_set(path, "", 0xffffffff, NULL, 0);
    if (r)
      return r;
  }
  for (unsigned i = 0; i < 256; i++)
    if (!reg_handles[i].used) {
      reg_handles[i].used = 1;
      snprintf(reg_handles[i].path, 512, "%s", path);
      *handle = 0x300 + i;
      if (disposition)
        *disposition = exists ? 2 : 1;
      return 0;
    }
  return 8;
}
