// Non-AX shared-cache SPI capability fixture. These are SPI, not public SDK APIs.
// Apple dyld declarations and full-cache enumeration contract, fixed revision:
// https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/include/mach-o/dyld_priv.h#L454
// https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/dyld/DyldAPIs.cpp#L2273
// The entry point may lazily initialize introspection dependencies:
// https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/libdyld/libdyldGlue.cpp#L595
// https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/libdyld_introspection/dyld_introspection.cpp#L78
// A successful API traversal is the completeness contract; this fixture does
// not independently parse every cache file or prove object ownership.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include <errno.h>
#include <fcntl.h>

struct dyld_shared_cache_dylib_text_info {
    uint64_t version, loadAddressUnslid, textSegmentSize;
    uuid_t dylibUuid;
    const char *path;
    uint64_t textSegmentOffset;
};
extern bool _dyld_get_shared_cache_uuid(uuid_t) __attribute__((weak_import));
extern int dyld_shared_cache_iterate_text(const uuid_t,
    void (^)(const struct dyld_shared_cache_dylib_text_info *)) __attribute__((weak_import));

enum { MAX_IMAGES = 16384, MAX_LOADED = 512, MAX_COMMANDS = 65536, SAMPLE_LIMIT = 8, OUTPUT_LIMIT = 16384, DETAIL_LIMIT = 8192 };
enum { REQUEST_LIMIT = 96, LOOKUP_OUTPUT_LIMIT = 24576, LOOKUP_DETAIL_LIMIT = 22000 };
static uuid_t requests[REQUEST_LIMIT];
static size_t request_count;
struct row { uuid_t uuid; char basename[97]; bool eligible; };
static struct row rows[MAX_IMAGES];
// One record per dyld add callback; UUIDs need not be unique.
static uuid_t loaded[MAX_LOADED];
static size_t count, callbacks, loaded_records, versions[3], path_excluded, membership_excluded;
static const char *error_code;
enum phase { REGISTRATION, SETUP, CENSUS, ENUMERATION, FORMATTING, CLOSED };
static const char *phase_names[] = {"observer_registration", "setup", "census", "enumeration", "formatting"};
struct event_counts { size_t add, remove; };
struct event_snapshot { struct event_counts counts[CLOSED]; bool overflow; };
static struct event_snapshot events;
static enum phase phase;
static atomic_flag event_lock = ATOMIC_FLAG_INIT;
static _Thread_local bool collecting_census;
static bool census_invalid;

// Never hold this lock across dyld, formatting, allocation, or another callback.
static void lock_events(void) { while (atomic_flag_test_and_set(&event_lock)) {} }
static void unlock_events(void) { atomic_flag_clear(&event_lock); }
static void set_phase(enum phase next) { lock_events(); phase = next; unlock_events(); }
static struct event_snapshot snapshot_events(bool close) {
    lock_events();
    if (close) phase = CLOSED; // Linearization point; later notifications are outside this measurement.
    struct event_snapshot result = events;
    unlock_events();
    return result;
}
static void image_event(bool removed) {
    lock_events();
    if (phase != CLOSED) {
        size_t *value = removed ? &events.counts[phase].remove : &events.counts[phase].add;
        if (*value == MAX_IMAGES) events.overflow = true;
        else (*value)++;
    }
    unlock_events();
}
static bool inventory_unchanged(struct event_snapshot value) {
    for (size_t i = CENSUS; i < CLOSED; i++)
        if (value.counts[i].add || value.counts[i].remove) return false;
    return true;
}
static bool begin_enumeration(bool census_valid) {
    lock_events();
    bool allowed = census_valid && !events.overflow && inventory_unchanged(events);
    // The final census check and phase change share one linearization point.
    // A notification cannot enter the census after it has been accepted.
    if (allowed) phase = ENUMERATION;
    unlock_events();
    return allowed;
}

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

static void observer_added(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide; image_event(false);
}
static void observer_removed(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide; image_event(true);
}
static void census_added(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    // Registration replays synchronously on this thread. Future/other-thread
    // notifications are counted by the separate observer, never mutate this list.
    if (!collecting_census) return;
    if (loaded_records == MAX_LOADED || !header_uuid(header, loaded[loaded_records])) {
        census_invalid = true; return;
    }
    loaded_records++;
}

static void consume(const struct dyld_shared_cache_dylib_text_info *info, bool (*contains)(const char *)) {
    if (callbacks < MAX_IMAGES + 1) callbacks++;
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
    if (!contains(info->path)) { membership_excluded++; return; }
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

struct buffer { char *data; size_t capacity, used; bool failed; };
static void append(struct buffer *out, const char *format, ...) {
    if (out->failed) return;
    va_list args; va_start(args, format);
    int size = vsnprintf(out->data + out->used, out->capacity - out->used, format, args);
    va_end(args);
    if (size < 0 || (size_t)size >= out->capacity - out->used) out->failed = true;
    else out->used += (size_t)size;
}
static void samples(struct buffer *out, bool want_loaded) {
    append(out, "[");
    size_t emitted = 0;
    for (size_t i = 0; i < count && emitted < SAMPLE_LIMIT; i++) {
        if (!rows[i].eligible || !unique_at(i) || is_loaded(rows[i].uuid) != want_loaded) continue;
        char identifier[37]; uuid_unparse_upper(rows[i].uuid, identifier);
        append(out, "%s{\"basename\":\"%s\",\"uuid\":\"%s\"}", emitted++ ? "," : "", rows[i].basename, identifier);
    }
    append(out, "]");
}

struct traversal {
    size_t calls, callbacks, records, versions[3];
    int api_code;
    const char *schema_error;
    bool cache_stable;
};
// These narrow seams let --self-test exercise the actual sequencing without
// loading libraries or performing additional native cache traversals.
struct operations {
    bool (*cache_uuid)(uuid_t);
    int (*iterate)(const uuid_t, void (^)(const struct dyld_shared_cache_dylib_text_info *));
    bool (*contains)(const char *);
    void (*observe)(void);
    void (*census)(void);
    void (*after_format)(void);
    void (*before_enumeration)(void);
};
static struct traversal traverse(const struct operations *ops, const uuid_t expected) {
    // No setup rows, eligibility bits, errors or counters survive into measurement.
    memset(rows, 0, sizeof(rows)); memset(versions, 0, sizeof(versions));
    count = callbacks = path_excluded = membership_excluded = 0; error_code = NULL;
    struct traversal result = {.schema_error = "not-run"};
    uuid_t current;
    if (!ops->cache_uuid(current) || uuid_compare(expected, current)) return result;
    result.calls = 1;
    result.api_code = ops->iterate(expected, ^(const struct dyld_shared_cache_dylib_text_info *info) { consume(info, ops->contains); });
    result.cache_stable = ops->cache_uuid(current) && !uuid_compare(expected, current);
    result.callbacks = callbacks; result.records = count;
    memcpy(result.versions, versions, sizeof(versions));
    result.schema_error = error_code ? error_code : !count || count != callbacks ? "enumeration_incomplete" : "none";
    return result;
}
static bool traversal_ok(struct traversal value) {
    return value.calls == 1 && !value.api_code && value.cache_stable && !strcmp(value.schema_error, "none");
}
struct experiment {
    struct traversal setup, measured;
    bool census_started, measured_started, census_valid, format_complete, final_cache_stable;
    struct event_snapshot events;
    char details[LOOKUP_DETAIL_LIMIT];
};
static bool experiment_ok(const struct experiment *value) {
    return traversal_ok(value->setup) && value->measured_started && traversal_ok(value->measured)
        && value->census_valid && value->format_complete && value->final_cache_stable
        && !value->events.overflow && inventory_unchanged(value->events);
}
static void format_details(struct experiment *value, size_t capacity) {
    qsort(rows, count, sizeof(*rows), compare_rows);
    if (request_count) {
        struct buffer out = {value->details, capacity, 0, false};
        append(&out, "[");
        for (size_t r = 0; r < request_count; r++) {
            size_t matches = 0, found = 0;
            for (size_t i = 0; i < count; i++) if (!uuid_compare(requests[r], rows[i].uuid)) { matches++; found = i; }
            const char *reason = !matches ? "uuid_missing" : matches != 1 ? "uuid_duplicate" :
                                 !rows[found].eligible ? "image_excluded" : "verified";
            append(&out, "%s{\"request_index\":%zu,\"reason\":\"%s\"", r ? "," : "", r, reason);
            if (!strcmp(reason, "verified")) {
                char identifier[37]; uuid_unparse_upper(rows[found].uuid, identifier);
                append(&out, ",\"basename\":\"%s\",\"uuid\":\"%s\"", rows[found].basename, identifier);
            }
            append(&out, "}");
        }
        append(&out, "]"); value->format_complete = !out.failed;
        return;
    }
    size_t duplicate_groups = 0, duplicate_rows = 0, duplicate_excluded = 0, unique = 0, matched_loaded = 0;
    for (size_t i = 0; i < count; i++) {
        if (!unique_at(i)) {
            duplicate_rows++;
            if (!rows[i].eligible) duplicate_excluded++;
            if (!i || uuid_compare(rows[i-1].uuid, rows[i].uuid)) duplicate_groups++;
        } else if (rows[i].eligible) { unique++; if (is_loaded(rows[i].uuid)) matched_loaded++; }
    }
    struct buffer out = {value->details, capacity, 0, false};
    append(&out, "{\"path_excluded\":%zu,\"membership_excluded\":%zu,\"duplicate_uuid_groups\":%zu,"
           "\"duplicate_rows\":%zu,\"duplicate_excluded_rows\":%zu,\"unique_system_uuid_count\":%zu,"
           "\"unique_system_loaded\":%zu,\"unique_system_not_loaded\":%zu,\"loaded_samples\":",
           path_excluded, membership_excluded, duplicate_groups, duplicate_rows, duplicate_excluded, unique,
           matched_loaded, unique - matched_loaded);
    samples(&out, true); append(&out, ",\"not_loaded_samples\":"); samples(&out, false); append(&out, "}");
    value->format_complete = !out.failed;
}
static void format_traversal(struct buffer *out, struct traversal value) {
    append(out, "{\"calls\":%zu,\"api_return_code\":", value.calls);
    if (value.calls) append(out, "%d", value.api_code); else append(out, "null");
    append(out, ",\"callbacks\":%zu,\"records\":%zu,\"version_1\":%zu,\"version_2\":%zu,"
           "\"schema_error\":\"%s\",\"active_uuid_unchanged\":%s}", value.callbacks, value.records,
           value.versions[1], value.versions[2], value.schema_error, value.cache_stable ? "true" : "false");
}
static bool format_report(char output[OUTPUT_LIMIT], const uuid_t expected, const struct experiment *value) {
    char identifier[37]; uuid_unparse_upper(expected, identifier);
    if (request_count) {
        struct buffer out = {output, LOOKUP_OUTPUT_LIMIT, 0, false};
        append(&out, "{\"schema\":1,\"mode\":\"lookup\",\"status\":\"%s\",\"active_cache_uuid\":\"%s\","
               "\"requests\":%zu,\"setup_calls\":%zu,\"measurement_calls\":%zu,\"callbacks\":%zu,"
               "\"measurement_closed\":true,\"result\":%s}\n",
               experiment_ok(value) ? "complete" : "failed", identifier, request_count,
               value->setup.calls, value->measured.calls, value->measured.callbacks,
               experiment_ok(value) ? value->details : "null");
        return !out.failed;
    }
    struct buffer out = {output, OUTPUT_LIMIT, 0, false};
    append(&out, "{\"schema\":2,\"status\":\"%s\",\"active_cache_uuid\":\"%s\",\"image_budget\":%d,\"setup\":",
           experiment_ok(value) ? "complete" : "failed", identifier, MAX_IMAGES);
    format_traversal(&out, value->setup); append(&out, ",\"measurement\":");
    if (value->measured_started) format_traversal(&out, value->measured); else append(&out, "null");
    append(&out, ",\"loaded_uuid_records\":%zu,\"loaded_inventory_valid\":%s,\"loaded_inventory_unchanged\":%s,"
           "\"format_complete\":%s,\"final_active_uuid_unchanged\":%s,\"measurement_closed\":true,"
           "\"event_overflow\":%s,\"events\":{", loaded_records,
           !value->census_started ? "null" : value->census_valid ? "true" : "false",
           !value->census_started ? "null" : inventory_unchanged(value->events) ? "true" : "false",
           value->format_complete ? "true" : "false", value->final_cache_stable ? "true" : "false",
           value->events.overflow ? "true" : "false");
    for (size_t i = 0; i < CLOSED; i++)
        append(&out, "%s\"%s\":{\"add\":%zu,\"remove\":%zu}", i ? "," : "", phase_names[i],
               value->events.counts[i].add, value->events.counts[i].remove);
    append(&out, "},\"result\":%s}\n", experiment_ok(value) ? value->details : "null");
    return !out.failed;
}
static bool same_events(struct event_snapshot a, struct event_snapshot b) {
    if (a.overflow != b.overflow) return false;
    for (size_t i = 0; i < CLOSED; i++)
        if (a.counts[i].add != b.counts[i].add || a.counts[i].remove != b.counts[i].remove) return false;
    return true;
}
static bool execute(const struct operations *ops, const uuid_t expected, struct experiment *value,
                    char output[OUTPUT_LIMIT], size_t detail_capacity) {
    memset(value, 0, sizeof(*value));
    lock_events(); memset(&events, 0, sizeof(events)); phase = REGISTRATION; unlock_events();
    loaded_records = 0; census_invalid = false;
    ops->observe();
    set_phase(SETUP); value->setup = traverse(ops, expected);
    if (traversal_ok(value->setup) && !snapshot_events(false).overflow) {
        set_phase(CENSUS); value->census_started = true;
        collecting_census = true; ops->census(); collecting_census = false;
        value->census_valid = !census_invalid && loaded_records > 0;
        if (ops->before_enumeration) ops->before_enumeration();
        if (begin_enumeration(value->census_valid)) {
            value->measured_started = true;
            value->measured = traverse(ops, expected);
        }
    }
    set_phase(FORMATTING);
    value->format_complete = true;
    if (value->measured_started && traversal_ok(value->measured)) format_details(value, detail_capacity);
    value->events = snapshot_events(false);
    value->final_cache_stable = true; // Checked after the full candidate output is formatted.
    if (!format_report(output, expected, value)) {
        value->events = snapshot_events(true);
        return false;
    }
    if (ops->after_format) ops->after_format();
    uuid_t current;
    value->final_cache_stable = ops->cache_uuid(current) && !uuid_compare(expected, current);
    struct event_snapshot final_events = snapshot_events(true);
    bool changed = !same_events(value->events, final_events) || !value->final_cache_stable;
    value->events = final_events;
    // Never publish a pre-check success buffer after a late change. Failure
    // serialization uses the immutable closed snapshot; earlier pass evidence stays.
    return !changed || format_report(output, expected, value);
}
static void observe_native(void) {
    _dyld_register_func_for_remove_image(observer_removed);
    _dyld_register_func_for_add_image(observer_added);
}
static void census_native(void) { _dyld_register_func_for_add_image(census_added); }
static const struct operations native = {_dyld_get_shared_cache_uuid, dyld_shared_cache_iterate_text,
    _dyld_shared_cache_contains_path, observe_native, census_native, NULL, NULL};

// Synthetic pipeline tests share execute(), callbacks, traversal and output gate.
enum scenario { VALID, SETUP_API, SETUP_SCHEMA, SETUP_BUDGET, SETUP_EMPTY, SETUP_CACHE, SETUP_MULTIPLE,
                SETUP_PRECACHE, SETUP_UUID_UNAVAILABLE,
                CENSUS_ADD, CENSUS_REMOVE, CENSUS_LATE_ADD, CENSUS_LATE_REMOVE, CENSUS_INVALID, ENUM_ADD, ENUM_REMOVE, ENUM_API,
                ENUM_SCHEMA, ENUM_CACHE, ENUM_MULTIPLE, ENUM_PRECACHE,
                FORMAT_ADD, FORMAT_REMOVE, FORMAT_CACHE, FORMAT_BUDGET, EVENT_OVERFLOW, SCENARIOS };
static enum scenario scenario;
static size_t setup_calls, measured_calls, cache_reads;
static bool lookup_late_duplicate;
static bool fake_contains(const char *path) { (void)path; return true; }
static bool fake_cache_uuid(uuid_t value) {
    uuid_parse("11111111-1111-1111-1111-111111111111", value);
    cache_reads++;
    if (scenario == SETUP_UUID_UNAVAILABLE && phase == SETUP) return false;
    if ((scenario == SETUP_PRECACHE && phase == SETUP && cache_reads == 1)
        || (scenario == ENUM_PRECACHE && phase == ENUMERATION && cache_reads == 3)
        || ((scenario == SETUP_CACHE || scenario == SETUP_MULTIPLE) && phase == SETUP && cache_reads == 2)
        || ((scenario == ENUM_CACHE || scenario == ENUM_MULTIPLE) && phase == ENUMERATION && cache_reads == 4)
        || (scenario == FORMAT_CACHE && phase == FORMATTING)) value[0] = 9;
    return true;
}
static void fake_observe(void) { for (size_t i = 0; i < 3; i++) observer_added(NULL, 0); }
static void fake_census(void) {
    struct { struct mach_header_64 header; struct uuid_command command; } image = {
        .header = {.magic = MH_MAGIC_64, .ncmds = 1, .sizeofcmds = sizeof(struct uuid_command)},
        .command = {.cmd = LC_UUID, .cmdsize = sizeof(struct uuid_command)}};
    uuid_parse("11111111-1111-1111-1111-111111111111", image.command.uuid);
    if (scenario == CENSUS_INVALID) image.header.magic = 0;
    census_added((const struct mach_header *)&image, 0);
    if (scenario == CENSUS_ADD) observer_added(NULL, 0);
    if (scenario == CENSUS_REMOVE) observer_removed(NULL, 0);
}
static int fake_iterate(const uuid_t expected, void (^callback)(const struct dyld_shared_cache_dylib_text_info *)) {
    (void)expected;
    bool setup = phase == SETUP;
    if (setup) { setup_calls++; observer_added(NULL, 0); observer_removed(NULL, 0); }
    else measured_calls++;
    if (scenario == SETUP_EMPTY && setup) return 0;
    struct dyld_shared_cache_dylib_text_info info = {.version = 2, .textSegmentSize = 32, .path = "/usr/lib/libSystem.B.dylib"};
    uuid_parse(setup ? "33333333-3333-3333-3333-333333333333" : "11111111-1111-1111-1111-111111111111", info.dylibUuid);
    if (((scenario == SETUP_SCHEMA || scenario == SETUP_MULTIPLE) && setup) || ((scenario == ENUM_SCHEMA || scenario == ENUM_MULTIPLE) && !setup)) info.version = 99;
    size_t total = scenario == SETUP_BUDGET && setup ? MAX_IMAGES + 1 : setup ? 1 : 2;
    for (size_t i = 0; i < total; i++) { callback(&info); info.dylibUuid[0]++; }
    if (!setup && lookup_late_duplicate) {
        uuid_copy(info.dylibUuid, requests[0]); info.path = "/private/excluded"; callback(&info);
    }
    if (!setup && (scenario == ENUM_ADD || scenario == ENUM_MULTIPLE)) observer_added(NULL, 0);
    if (!setup && (scenario == ENUM_REMOVE || scenario == ENUM_MULTIPLE)) observer_removed(NULL, 0);
    if (setup && scenario == EVENT_OVERFLOW) for (size_t i = 0; i < MAX_IMAGES; i++) observer_added(NULL, 0);
    return (setup && (scenario == SETUP_API || scenario == SETUP_MULTIPLE)) || (!setup && (scenario == ENUM_API || scenario == ENUM_MULTIPLE)) ? -1 : 0;
}
static void fake_after_format(void) {
    if (scenario == FORMAT_ADD) observer_added(NULL, 0);
    if (scenario == FORMAT_REMOVE) observer_removed(NULL, 0);
}
static void fake_before_enumeration(void) {
    // Deterministic notification at the former snapshot/check transition gap.
    if (scenario == CENSUS_LATE_ADD) observer_added(NULL, 0);
    if (scenario == CENSUS_LATE_REMOVE) observer_removed(NULL, 0);
}
static const struct operations fake = {fake_cache_uuid, fake_iterate, fake_contains,
    fake_observe, fake_census, fake_after_format, fake_before_enumeration};
static int census_race_test(bool removed) {
    scenario = removed ? CENSUS_LATE_REMOVE : CENSUS_LATE_ADD;
    setup_calls = measured_calls = cache_reads = 0;
    uuid_t expected; uuid_parse("11111111-1111-1111-1111-111111111111", expected);
    struct experiment value; char output[OUTPUT_LIMIT];
    if (!execute(&fake, expected, &value, output, DETAIL_LIMIT)) return 2;
    size_t size = strlen(output);
    if (fwrite(output, 1, size, stdout) != size || fflush(stdout)) return 2;
    // Publish the actual failed packet for the Python gate, not a hand-built sample.
    return setup_calls == 1 && measured_calls == 0 && !value.measured_started && !experiment_ok(&value)
        && value.events.counts[CENSUS].add == (removed ? 0 : 1)
        && value.events.counts[CENSUS].remove == (removed ? 1 : 0) ? 1 : 2;
}
static int self_test(void) {
    size_t tests = 0;
    const char *bad[] = {"/private/secret", "/usr/lib/../Foo", "/usr/lib//Foo", "/usr/lib/Foo\n", "/System/LibraryFake/Foo"};
    for (size_t i = 0; i < sizeof(bad)/sizeof(*bad); i++) { if (safe_basename(bad[i])) return 1; tests++; }
    if (!safe_basename("/usr/lib/system/libsystem_pthread.dylib")) return 1; tests++;
    count = 3;
    uuid_parse("11111111-1111-1111-1111-111111111111", rows[0].uuid); uuid_copy(rows[1].uuid, rows[0].uuid);
    uuid_parse("22222222-2222-2222-2222-222222222222", rows[2].uuid);
    qsort(rows, count, sizeof(*rows), compare_rows);
    if (unique_at(0) || unique_at(1) || !unique_at(2)) return 1; tests++;
    uuid_t expected; uuid_parse("11111111-1111-1111-1111-111111111111", expected);
    for (scenario = VALID; scenario < SCENARIOS; scenario++) {
        setup_calls = measured_calls = cache_reads = 0;
        struct experiment value; char output[OUTPUT_LIMIT];
        if (!execute(&fake, expected, &value, output, scenario == FORMAT_BUDGET ? 8 : DETAIL_LIMIT)) return 1;
        bool stop_before_measurement = (scenario >= SETUP_API && scenario <= CENSUS_INVALID) || scenario == EVENT_OVERFLOW;
        bool skip_setup = scenario == SETUP_PRECACHE || scenario == SETUP_UUID_UNAVAILABLE;
        if (setup_calls != (skip_setup ? 0 : 1) || measured_calls != (stop_before_measurement || scenario == ENUM_PRECACHE ? 0 : 1)
            || experiment_ok(&value) != (scenario == VALID) || phase != CLOSED
            || value.events.counts[REGISTRATION].add != 3
            || value.events.counts[SETUP].remove != (skip_setup ? 0 : 1)
            || !strstr(output, scenario == VALID ? "\"status\":\"complete\"" : "\"status\":\"failed\"")) return 1;
        if (scenario == VALID && (value.setup.records != 1 || value.measured.records != 2
            || !strstr(value.details, "\"unique_system_uuid_count\":2") || loaded_records != 1)) return 1;
        if ((scenario == FORMAT_ADD || scenario == FORMAT_REMOVE) && !strstr(output, "\"loaded_inventory_unchanged\":false")) return 1;
        if (scenario == SETUP_MULTIPLE && (!value.setup.api_code || value.setup.cache_stable
            || strcmp(value.setup.schema_error, "callback_schema") || value.measured_started)) return 1;
        if (scenario == ENUM_MULTIPLE && (!value.measured.api_code || value.measured.cache_stable
            || strcmp(value.measured.schema_error, "callback_schema") || inventory_unchanged(value.events))) return 1;
        // Closed callbacks must not change the serialized measurement snapshot.
        struct event_snapshot closed = snapshot_events(false); observer_added(NULL, 0);
        if (!same_events(closed, snapshot_events(false))) return 1;
        tests++;
    }
    printf("{\"mode\":\"self-test\",\"tests\":%zu,\"passed\":true}\n", tests);
    return 0;
}
static int lookup_test(void) {
    uuid_t expected; uuid_parse("11111111-1111-1111-1111-111111111111", expected);
    request_count = 1; uuid_copy(requests[0], expected);
    for (size_t i = 0; i < 4; i++) {
        scenario = i == 2 ? FORMAT_CACHE : VALID;
        lookup_late_duplicate = i == 1;
        setup_calls = measured_calls = cache_reads = 0;
        struct experiment value; char output[LOOKUP_OUTPUT_LIMIT];
        if (!execute(&fake, expected, &value, output, i == 3 ? 8 : LOOKUP_DETAIL_LIMIT)
            || setup_calls != 1 || measured_calls != 1 || phase != CLOSED
            || !strstr(output, i >= 2 ? "\"result\":null" : i == 1 ? "uuid_duplicate" : "verified")
            || (i == 1 && strstr(output, "basename")) || (i >= 2 && experiment_ok(&value))) return 1;
    }
    printf("{\"mode\":\"lookup-self-test\",\"tests\":4,\"passed\":true}\n");
    return 0;
}
static int lookup(int argc, const char **argv) {
    if (argc < 4 || argc > REQUEST_LIMIT + 3) return 2;
    request_count = (size_t)argc - 3;
    for (size_t i = 0; i < request_count; i++) {
        char canonical[37];
        if (strlen(argv[i + 3]) != 36 || uuid_parse(argv[i + 3], requests[i]) || uuid_is_null(requests[i])) return 2;
        uuid_unparse_upper(requests[i], canonical);
        if (strcmp(canonical, argv[i + 3])) return 2;
        for (size_t j = 0; j < i; j++) if (!uuid_compare(requests[j], requests[i])) return 2;
    }
    if (!_dyld_get_shared_cache_uuid || !dyld_shared_cache_iterate_text) return 78;
    uuid_t expected;
    if (!_dyld_get_shared_cache_uuid(expected) || uuid_is_null(expected)) return 1;
    struct experiment value; char output[LOOKUP_OUTPUT_LIMIT];
    if (!execute(&native, expected, &value, output, LOOKUP_DETAIL_LIMIT)) return 1;
    // The private output is separate from stdout/stderr; no partial file is a success.
    int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return 1;
    size_t size = strlen(output), done = 0;
    while (done < size) {
        ssize_t n = write(fd, output + done, size - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return 1; }
        done += (size_t)n;
    }
    if (close(fd)) return 1;
    return experiment_ok(&value) ? 0 : 1;
}
int main(int argc, const char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "--lookup")) return lookup(argc, argv);
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "--lookup-self-test")) return lookup_test();
    if (!strcmp(argv[1], "--self-test")) return self_test();
    if (!strcmp(argv[1], "--census-race-add")) return census_race_test(false);
    if (!strcmp(argv[1], "--census-race-remove")) return census_race_test(true);
    if (!strcmp(argv[1], "--timeout")) {
        printf("{\"mode\":\"timeout\"}\n"); fflush(stdout);
        for (;;) pause();
    }
    if (!strcmp(argv[1], "--invalid-schema")) {
        struct dyld_shared_cache_dylib_text_info invalid = {.version = 99}; consume(&invalid, fake_contains);
        printf("{\"mode\":\"invalid-schema\",\"reason\":\"%s\"}\n", error_code); return 1;
    }
    if (strcmp(argv[1], "--probe")) return 2;
    if (!_dyld_get_shared_cache_uuid || !dyld_shared_cache_iterate_text) {
        printf("{\"status\":\"unavailable\",\"reason\":\"spi_missing\"}\n"); return 78;
    }
    uuid_t expected;
    if (!_dyld_get_shared_cache_uuid(expected) || uuid_is_null(expected)) {
        printf("{\"status\":\"unavailable\",\"reason\":\"active_uuid_unavailable\"}\n"); return 1;
    }
    struct experiment value; char output[OUTPUT_LIMIT];
    if (!execute(&native, expected, &value, output, DETAIL_LIMIT)) return 1;
    size_t size = strlen(output);
    if (fwrite(output, 1, size, stdout) != size || fflush(stdout)) return 1;
    return experiment_ok(&value) ? 0 : 1;
}
