// Non-AX shared-cache SPI capability fixture. These are SPI, not public SDK APIs.
// Apple dyld declarations and full-cache enumeration contract, fixed revision:
// https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/include/mach-o/dyld_priv.h#L454
// https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/dyld/DyldAPIs.cpp#L2273
// A successful API traversal is the completeness contract; this fixture does
// not independently parse every cache file or prove object ownership.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <uuid/uuid.h>

struct dyld_shared_cache_dylib_text_info {
    uint64_t version, loadAddressUnslid, textSegmentSize;
    uuid_t dylibUuid;
    const char *path;
    uint64_t textSegmentOffset;
};
extern bool _dyld_get_shared_cache_uuid(uuid_t) __attribute__((weak_import));
extern int dyld_shared_cache_iterate_text(const uuid_t,
    void (^)(const struct dyld_shared_cache_dylib_text_info *)) __attribute__((weak_import));

enum { MAX_IMAGES = 16384, MAX_LOADED = 512, MAX_COMMANDS = 65536, SAMPLE_LIMIT = 8 };
struct row { uuid_t uuid; char basename[97]; bool eligible; };
static struct row rows[MAX_IMAGES];
// One record per dyld add callback; UUIDs need not be unique.
static uuid_t loaded[MAX_LOADED];
static size_t count, callbacks, loaded_records, versions[3], path_excluded, membership_excluded;
static const char *error_code;
static _Atomic bool loaded_sealed, loaded_changed;

static bool safe_component(const char *s, size_t length) {
    if (!length || length > 96 || (length == 1 && s[0] == '.') ||
        (length == 2 && s[0] == '.' && s[1] == '.')) return false;
    for (size_t i = 0; i < length; i++) {
        char c = s[i];
        bool alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        if (!(alnum || c == '_' || (i && (c == '.' || c == '+' || c == '-')))) return false;
    }
    return true;
}

static const char *safe_basename(const char *path) {
    if (!path || strnlen(path, 1025) > 1024 ||
        (strncmp(path, "/System/Library/", 16) && strncmp(path, "/usr/lib/", 9))) return NULL;
    const char *part = path + 1;
    for (;;) {
        const char *end = strchr(part, '/');
        size_t n = end ? (size_t)(end - part) : strlen(part);
        if (!safe_component(part, n)) return NULL;
        if (!end) return part;
        part = end + 1;
    }
}

static bool header_uuid(const struct mach_header *pointer, uuid_t result) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)pointer;
    if (header->magic != MH_MAGIC_64 || !header->ncmds || header->sizeofcmds > MAX_COMMANDS ||
        header->ncmds > header->sizeofcmds / sizeof(struct load_command)) return false;
    const unsigned char *commands = (const unsigned char *)(header + 1);
    size_t offset = 0, found = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (header->sizeofcmds - offset < sizeof(struct load_command)) return false;
        struct load_command command;
        memcpy(&command, commands + offset, sizeof(command));
        if (command.cmdsize < 8 || command.cmdsize % 8 || command.cmdsize > header->sizeofcmds - offset) return false;
        if (command.cmd == LC_UUID) {
            if (command.cmdsize != sizeof(struct uuid_command) || found++) return false;
            memcpy(result, commands + offset + 8, sizeof(uuid_t));
        }
        offset += command.cmdsize;
    }
    return offset == header->sizeofcmds && found == 1 && !uuid_is_null(result);
}

static void image_added(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (atomic_load(&loaded_sealed)) { atomic_store(&loaded_changed, true); return; }
    if (loaded_records == MAX_LOADED || !header_uuid(header, loaded[loaded_records])) {
        error_code = "loaded_inventory_invalid"; return;
    }
    loaded_records++;
}
static void image_removed(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide; atomic_store(&loaded_changed, true);
}

static void consume(const struct dyld_shared_cache_dylib_text_info *info) {
    callbacks++;
    if (error_code) return;
    if (count == MAX_IMAGES) { error_code = "image_budget"; return; }
    if (!info || (info->version != 1 && info->version != 2) || uuid_is_null(info->dylibUuid) ||
        !info->textSegmentSize || info->textSegmentSize > UINT64_MAX - info->loadAddressUnslid || !info->path) {
        error_code = "callback_schema"; return;
    }
    versions[info->version]++;
    struct row *row = &rows[count++];
    uuid_copy(row->uuid, info->dylibUuid);
    const char *name = safe_basename(info->path);
    if (!name) { path_excluded++; return; }
    if (!_dyld_shared_cache_contains_path(info->path)) { membership_excluded++; return; }
    memcpy(row->basename, name, strlen(name) + 1);
    row->eligible = true;
}

static int compare_rows(const void *a, const void *b) {
    return uuid_compare(((const struct row *)a)->uuid, ((const struct row *)b)->uuid);
}
static bool is_loaded(const uuid_t identifier) {
    for (size_t i = 0; i < loaded_records; i++) if (!uuid_compare(loaded[i], identifier)) return true;
    return false;
}
static bool unique_at(size_t i) {
    return (!i || uuid_compare(rows[i - 1].uuid, rows[i].uuid)) &&
           (i + 1 == count || uuid_compare(rows[i + 1].uuid, rows[i].uuid));
}

static void samples(bool want_loaded) {
    printf("[");
    size_t emitted = 0;
    for (size_t i = 0; i < count && emitted < SAMPLE_LIMIT; i++) {
        if (!rows[i].eligible || !unique_at(i) || is_loaded(rows[i].uuid) != want_loaded) continue;
        char identifier[37]; uuid_unparse_upper(rows[i].uuid, identifier);
        printf("%s{\"basename\":\"%s\",\"uuid\":\"%s\"}", emitted++ ? "," : "", rows[i].basename, identifier);
    }
    printf("]");
}

static int self_test(void) {
    size_t tests = 0;
    const char *bad[] = {"/private/secret", "/usr/lib/../Foo", "/usr/lib//Foo", "/usr/lib/Foo\n", "/System/LibraryFake/Foo"};
    for (size_t i = 0; i < sizeof(bad)/sizeof(*bad); i++) { if (safe_basename(bad[i])) return 1; tests++; }
    if (!safe_basename("/usr/lib/system/libsystem_pthread.dylib")) return 1; tests++;
    count = 3;
    uuid_parse("11111111-1111-1111-1111-111111111111", rows[0].uuid);
    uuid_copy(rows[1].uuid, rows[0].uuid);
    uuid_parse("22222222-2222-2222-2222-222222222222", rows[2].uuid);
    qsort(rows, count, sizeof(*rows), compare_rows);
    if (unique_at(0) || unique_at(1) || !unique_at(2)) return 1; tests++;
    struct dyld_shared_cache_dylib_text_info invalid = {.version = 99};
    consume(&invalid);
    if (!error_code || strcmp(error_code, "callback_schema")) return 1; tests++;
    error_code = NULL; count = MAX_IMAGES; consume(&invalid);
    if (!error_code || strcmp(error_code, "image_budget")) return 1; tests++;
    printf("{\"mode\":\"self-test\",\"tests\":%zu,\"passed\":true}\n", tests);
    return 0;
}

int main(int argc, const char **argv) {
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "--self-test")) return self_test();
    if (!strcmp(argv[1], "--timeout")) {
        printf("{\"mode\":\"timeout\"}\n"); fflush(stdout);
        for (;;) pause();
    }
    if (!strcmp(argv[1], "--invalid-schema")) {
        struct dyld_shared_cache_dylib_text_info invalid = {.version = 99}; consume(&invalid);
        printf("{\"mode\":\"invalid-schema\",\"reason\":\"%s\"}\n", error_code);
        return 1;
    }
    if (strcmp(argv[1], "--probe")) return 2;
    if (!_dyld_get_shared_cache_uuid || !dyld_shared_cache_iterate_text) {
        printf("{\"status\":\"unavailable\",\"reason\":\"spi_missing\"}\n"); return 78;
    }
    uuid_t before, after;
    if (!_dyld_get_shared_cache_uuid(before) || uuid_is_null(before)) {
        printf("{\"status\":\"unavailable\",\"reason\":\"active_uuid_unavailable\"}\n"); return 1;
    }
    _dyld_register_func_for_remove_image(image_removed);
    _dyld_register_func_for_add_image(image_added);
    atomic_store(&loaded_sealed, true);
    int result = dyld_shared_cache_iterate_text(before, ^(const struct dyld_shared_cache_dylib_text_info *info) { consume(info); });
    bool stable = _dyld_get_shared_cache_uuid(after) && !uuid_compare(before, after);
    if (!stable) error_code = "active_uuid_changed";
    if (atomic_load(&loaded_changed)) error_code = "loaded_inventory_changed";
    if (!count || count != callbacks) { if (!error_code) error_code = "enumeration_incomplete"; }
    char cache_uuid[37]; uuid_unparse_upper(before, cache_uuid);
    if (result || error_code) {
        printf("{\"status\":\"failed\",\"api_return_code\":%d,\"callbacks\":%zu,\"reason\":\"%s\"}\n",
               result, callbacks, error_code ? error_code : "api_failed"); return 1;
    }
    qsort(rows, count, sizeof(*rows), compare_rows);
    size_t duplicate_groups = 0, duplicate_rows = 0, duplicate_excluded = 0, unique = 0, matched_loaded = 0;
    for (size_t i = 0; i < count; i++) {
        if (!unique_at(i)) {
            duplicate_rows++;
            if (!rows[i].eligible) duplicate_excluded++;
            if (!i || uuid_compare(rows[i-1].uuid, rows[i].uuid)) duplicate_groups++;
        } else if (rows[i].eligible) { unique++; if (is_loaded(rows[i].uuid)) matched_loaded++; }
    }
    printf("{\"schema\":1,\"status\":\"complete\",\"active_cache_uuid\":\"%s\","
           "\"active_uuid_unchanged\":true,\"loaded_inventory_unchanged\":true,\"api_return_code\":%d,"
           "\"callbacks\":%zu,\"image_budget\":%d,\"version_1\":%zu,\"version_2\":%zu,"
           "\"path_excluded\":%zu,\"membership_excluded\":%zu,\"duplicate_uuid_groups\":%zu,\"duplicate_rows\":%zu,\"duplicate_excluded_rows\":%zu,"
           "\"unique_system_uuid_count\":%zu,\"loaded_uuid_records\":%zu,\"unique_system_loaded\":%zu,"
           "\"unique_system_not_loaded\":%zu,\"loaded_samples\":",
           cache_uuid, result, callbacks, MAX_IMAGES, versions[1], versions[2], path_excluded,
           membership_excluded, duplicate_groups, duplicate_rows, duplicate_excluded, unique, loaded_records, matched_loaded, unique - matched_loaded);
    samples(true); printf(",\"not_loaded_samples\":"); samples(false); printf("}\n");
    return fflush(stdout) ? 1 : 0;
}
