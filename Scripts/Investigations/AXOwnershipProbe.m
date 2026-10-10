// Diagnostic-only, MRC. Linked only into the owned synthetic fixture.
// Observe the actual call stack; never reuse a different OS image's offsets.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <pthread.h>
#import <ptrauth.h>
#import <mach/mach_vm.h>

static const char *destroyedName = "_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification";
static const char *helperName = "-[NSAccessibilityNotificationTable _copyAllObserversForNotificationLocked:specifier:appSpecifier:]";
static id (*originalCopy)(id, SEL), (*originalMutableCopy)(id, SEL);
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static const uintptr_t addressMask = 0xa6d94f31782bc50eULL;
static struct { uintptr_t encoded; unsigned kind; BOOL freed; CFIndex initialRC; } generations[4096];
static struct { Class cls; void (*original)(id, SEL); } classes[8];
static unsigned created, freed, classCount, reused, duplicateLive, offMain;
static uintptr_t destroyedStart, helperStart, returnOffsets[2];
static unsigned changedOffsets[2];
static NSString *outputDirectory;
static BOOL codeWritten, balanceCopies;

static void recordDealloc(id object, SEL selector, unsigned slot) {
    uintptr_t encoded = (uintptr_t)object ^ addressMask;
    pthread_mutex_lock(&lock);
    for (unsigned i = created; i > 0; i--) {
        if (generations[i - 1].encoded == encoded && !generations[i - 1].freed) {
            generations[i - 1].freed = YES;
            freed++;
            break;
        }
    }
    pthread_mutex_unlock(&lock);
    classes[slot].original(object, selector);
}
#define DEALLOC_SLOT(N) static void dealloc##N(id object, SEL selector) { recordDealloc(object, selector, N); }
DEALLOC_SLOT(0) DEALLOC_SLOT(1) DEALLOC_SLOT(2) DEALLOC_SLOT(3)
DEALLOC_SLOT(4) DEALLOC_SLOT(5) DEALLOC_SLOT(6) DEALLOC_SLOT(7)
static IMP deallocations[] = {(IMP)dealloc0, (IMP)dealloc1, (IMP)dealloc2, (IMP)dealloc3,
                            (IMP)dealloc4, (IMP)dealloc5, (IMP)dealloc6, (IMP)dealloc7};

static void watchClass(Class cls) {
    for (unsigned i = 0; i < classCount; i++) if (classes[i].cls == cls) return;
    NSCAssert(classCount < 8, @"bounded concrete array classes");
    Method method = class_getInstanceMethod(cls, sel_registerName("dealloc"));
    NSCAssert(method != NULL, @"array dealloc available");
    unsigned slot = classCount++;
    classes[slot].cls = cls;
    classes[slot].original = (void *)method_getImplementation(method);
    if (!class_addMethod(cls, sel_registerName("dealloc"), deallocations[slot], method_getTypeEncoding(method)))
        method_setImplementation(method, deallocations[slot]);
}

__attribute__((noinline)) static void traceResult(id result, uintptr_t caller, unsigned kind) {
    if (!result) return;
    Dl_info immediate = {0};
    if (!dladdr((void *)caller, &immediate) || !immediate.dli_sname) return;
    BOOL direct = strcmp(immediate.dli_sname, destroyedName) == 0;
    BOOL merged = strcmp(immediate.dli_sname, helperName) == 0;
    if (!direct && !merged) return;
    uintptr_t target = direct ? caller : 0, start = direct ? (uintptr_t)immediate.dli_saddr : 0;
    if (merged) {
        void *frames[16]; int count = backtrace(frames, 16);
        for (int i = 1; i < count; i++) {
            Dl_info info = {0};
            if (dladdr(frames[i], &info) && info.dli_sname && !strcmp(info.dli_sname, destroyedName)) {
                target = (uintptr_t)frames[i]; start = (uintptr_t)info.dli_saddr; break;
            }
        }
    }
    if (!target) return;
    // The fixture tears down views on the main thread. Reject other paths.
    if (![NSThread isMainThread]) { __atomic_fetch_add(&offMain, 1, __ATOMIC_RELAXED); return; }
    watchClass(object_getClass(result));
    CFIndex rc = CFGetRetainCount((CFTypeRef)result);
    uintptr_t encoded = (uintptr_t)result ^ addressMask;
    pthread_mutex_lock(&lock);
    NSCAssert(created < 4096, @"bounded generations");
    BOOL seen = NO;
    for (unsigned i = 0; i < created; i++) {
        if (generations[i].encoded == encoded) {
            seen = YES;
            if (!generations[i].freed) duplicateLive++;
        }
    }
    if (seen) reused++;
    generations[created++] = (typeof(generations[0])){encoded, kind, NO, rc};
    if (returnOffsets[kind] && returnOffsets[kind] != target - start) changedOffsets[kind]++;
    returnOffsets[kind] = target - start;
    destroyedStart = start;
    if (merged) helperStart = (uintptr_t)immediate.dli_saddr;
    pthread_mutex_unlock(&lock);
    // Explicit causal experiment in the disposable fixture, never the product.
    if (balanceCopies) [result autorelease];
}

__attribute__((noinline)) static id tracedCopy(id object, SEL selector) {
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    id result = originalCopy(object, selector);
    traceResult(result, caller, 0);
    return result;
}
__attribute__((noinline)) static id tracedMutableCopy(id object, SEL selector) {
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    id result = originalMutableCopy(object, selector);
    traceResult(result, caller, 1);
    return result;
}

static uintptr_t adrpPage(uintptr_t pc, uint32_t instruction) {
    int64_t immediate = ((instruction >> 5) & 0x7ffff) << 2 | ((instruction >> 29) & 3);
    if (immediate & (1 << 20)) immediate -= 1 << 21;
    return (pc & ~(uintptr_t)4095) + immediate * 4096;
}
static BOOL readOwnMemory(uintptr_t address, void *buffer, size_t size) {
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), address, size, (mach_vm_address_t)buffer, &copied) == KERN_SUCCESS
        && copied == size;
}
static NSString *resolvedStub(uintptr_t target) {
    uint32_t words[4];
    if (!readOwnMemory(target, words, sizeof(words))) return nil;
    // ARM64 authenticated import stub: adrp x17; add x17; ldr x16; braa.
    if ((words[0] & 0x9f00001f) != 0x90000011 || (words[1] & 0xffc003ff) != 0x91000231 ||
        words[2] != 0xf9400230 || words[3] != 0xd71f0a11) return nil;
    uintptr_t slot = adrpPage(target, words[0]) + ((words[1] >> 10) & 4095);
    void *address = NULL;
    if (!readOwnMemory(slot, &address, sizeof(address))) return nil;
    address = ptrauth_strip(address, ptrauth_key_function_pointer);
    Dl_info info = {0};
    return dladdr(address, &info) && info.dli_sname ? @(info.dli_sname) : nil;
}
static NSArray *stubReferences(uintptr_t target) {
    // New shared-cache stubs need not have a dladdr symbol. Decode only their
    // bounded ADRP/LDR references, ending at the first tail transfer so a
    // neighbouring stub cannot supply a misleading selector or function name.
    uint32_t words[8];
    if (!readOwnMemory(target, words, sizeof(words))) return @[];
    unsigned length = 0;
    for (unsigned i = 0; i < 8; i++) {
        uint32_t word = words[i];
        if ((word & 0xfc000000) == 0x14000000 || (word & 0xfffffc1f) == 0xd61f0000 ||
            (word & 0xfffffc00) == 0xd71f0800 || (word & 0xfffffc00) == 0xd71f0c00 ||
            (word & 0xfffffc1f) == 0xd61f081f || (word & 0xfffffc1f) == 0xd61f0c1f) {
            length = i + 1; break;
        }
    }
    if (!length) return @[];
    NSMutableArray *references = [NSMutableArray array];
    for (unsigned i = 0; i + 1 < length; i++) {
        uint32_t word = words[i], next = words[i + 1];
        if ((word & 0x9f000000) != 0x90000000 || (next & 0xffc00000) != 0xf9400000 ||
            ((next >> 5) & 31) != (word & 31)) continue;
        uintptr_t slot = adrpPage(target + i * 4, word) + ((next >> 10) & 4095) * 8;
        void *value = NULL;
        if (!readOwnMemory(slot, &value, sizeof(value))) continue;
        unsigned reg = next & 31;
        if (reg == 1 && sel_isMapped((SEL)value)) {
            [references addObject:@{@"offset":@((i + 1) * 4), @"register":@(reg), @"selector":@(sel_getName((SEL)value))}];
        } else {
            Dl_info info = {0};
            value = ptrauth_strip(value, ptrauth_key_function_pointer);
            if (dladdr(value, &info) && info.dli_sname)
                [references addObject:@{@"offset":@((i + 1) * 4), @"register":@(reg), @"symbol":@(info.dli_sname)}];
        }
    }
    return references;
}
static NSDictionary *symbolCode(uintptr_t start) {
    Dl_info info = {0};
    if (!start || !dladdr((void *)start, &info) || !info.dli_sname) return nil;
    NSMutableArray *words = [NSMutableArray array], *branches = [NSMutableArray array], *references = [NSMutableArray array];
    BOOL boundedBySymbol = NO;
    for (unsigned offset = 0; offset < 4096; offset += 4) {
        Dl_info current = {0};
        if (!dladdr((void *)(start + offset), &current) || current.dli_saddr != info.dli_saddr) { boundedBySymbol = YES; break; }
        uint32_t word = *(uint32_t *)(start + offset);
        [words addObject:@(word)];
        if ((word & 0x7c000000) == 0x14000000) {
            int64_t delta = (int64_t)(int32_t)(word << 6) >> 4;
            uintptr_t target = start + offset + delta;
            Dl_info destination = {0};
            dladdr((void *)target, &destination);
            NSString *name = destination.dli_sname ? @(destination.dli_sname) : @"unknown";
            NSString *resolved = resolvedStub(target);
            [branches addObject:@{@"offset":@(offset), @"target":@(target), @"symbol":name,
                @"symbolOffset":@(destination.dli_saddr ? target - (uintptr_t)destination.dli_saddr : 0),
                @"resolved":resolved ?: @"", @"stubReferences":destination.dli_sname ? @[] : stubReferences(target)}];
            if (!strcmp(name.UTF8String, helperName)) helperStart = (uintptr_t)destination.dli_saddr;
        }
        if ((word & 0x9f000000) == 0x90000000) {
            uint32_t next = *(uint32_t *)(start + offset + 4);
            if ((next & 0xffc00000) == 0xf9400000 && ((next >> 5) & 31) == (word & 31)) {
                uintptr_t slot = adrpPage(start + offset, word) + ((next >> 10) & 4095) * 8;
                void *value = ptrauth_strip(*(void **)slot, ptrauth_key_function_pointer);
                Dl_info reference = {0};
                if (dladdr(value, &reference) && reference.dli_sname)
                    [references addObject:@{@"offset":@(offset + 4), @"symbol":@(reference.dli_sname)}];
            }
        }
    }
    return @{@"name":@(info.dli_sname), @"start":@(start), @"imageOffset":@(start - (uintptr_t)info.dli_fbase),
        @"words":words, @"branches":branches, @"references":references, @"boundedBySymbol":@(boundedBySymbol)};
}

void AXOwnershipProbeInstall(NSString *directory, BOOL balance) {
    outputDirectory = [directory copy];
    balanceCopies = balance;
    Class cls = object_getClass([NSMutableArray arrayWithObject:@"probe"]);
    Method copy = class_getInstanceMethod(cls, @selector(copy));
    Method mutableCopy = class_getInstanceMethod(cls, @selector(mutableCopy));
    NSCAssert(copy && mutableCopy && !strcmp(method_getTypeEncoding(copy), "@16@0:8") &&
        !strcmp(method_getTypeEncoding(mutableCopy), "@16@0:8"), @"verified array method ABI");
    originalCopy = (void *)method_getImplementation(copy);
    originalMutableCopy = (void *)method_getImplementation(mutableCopy);
    if (!class_addMethod(cls, @selector(copy), (IMP)tracedCopy, method_getTypeEncoding(copy)))
        method_setImplementation(copy, (IMP)tracedCopy);
    if (!class_addMethod(cls, @selector(mutableCopy), (IMP)tracedMutableCopy, method_getTypeEncoding(mutableCopy)))
        method_setImplementation(mutableCopy, (IMP)tracedMutableCopy);
}

NSDictionary *AXOwnershipProbeSnapshot(void) {
    unsigned counts[2] = {0}, released[2] = {0}, rcOne[2] = {0};
    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < created; i++) {
        unsigned kind = generations[i].kind;
        counts[kind]++;
        if (generations[i].freed) released[kind]++;
        if (generations[i].initialRC == 1) rcOne[kind]++;
    }
    unsigned total = created, destroyed = freed;
    pthread_mutex_unlock(&lock);
    if (!codeWritten && destroyedStart) {
        NSDictionary *destroy = symbolCode(destroyedStart), *helper = symbolCode(helperStart);
        if (destroy && helper) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:@[destroy, helper] options:0 error:NULL];
            [data writeToFile:[outputDirectory stringByAppendingPathComponent:@"symbol-code.json"] atomically:YES];
            codeWritten = YES;
        }
    }
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned i = 0; i < classCount; i++) [names addObject:@(class_getName(classes[i].cls))];
    NSMutableDictionary *kinds = [NSMutableDictionary dictionary];
    for (unsigned i = 0; i < 2; i++) kinds[i ? @"mutableCopy" : @"copy"] = @{
        @"created":@(counts[i]), @"deallocated":@(released[i]), @"initialRCOne":@(rcOne[i]),
        @"destroyedReturnOffset":@(returnOffsets[i]), @"changedReturnOffsets":@(changedOffsets[i])};
    return @{@"created":@(total), @"deallocated":@(destroyed), @"live":@(total - destroyed),
        @"reusedAddresses":@(reused), @"duplicateLiveAddresses":@(duplicateLive), @"offMainHits":@(__atomic_load_n(&offMain, __ATOMIC_RELAXED)),
        @"classes":names, @"kinds":kinds, @"codeCaptured":@(codeWritten), @"compensationApplied":@(balanceCopies)};
}
