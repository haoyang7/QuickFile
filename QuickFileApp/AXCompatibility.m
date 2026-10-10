// Compatibility for the verified macOS 15.7.9 / 26.6.2 arm64 AppKit ownership defect.
// See the AX compatibility section in ARCHITECTURE.md for scope and verification.
// Compile with -fno-objc-arc: the original IMP returns an owned copy.
// Other OS images and architectures deliberately keep the system behavior.
#import "AXCompatibility.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <stdatomic.h>

static id (*originalCopy)(id, SEL);
static id (*originalMutableCopy)(id, SEL);
static uintptr_t destroyedReturn, mergedReturn;
static atomic_ulong compensated;
static atomic_ulong compensatedMutable;
static _Atomic(const char *) installationStatus = "not-attempted";
#ifdef QUICKFILE_AX_COPY_LIFETIME
extern void QuickFileAXObserveCopyLifetime(id result, BOOL mutableCopy);
#endif

// The verified helper tail-calls copy, so the immediate return PC identifies
// the exact destroyed-notification call site. Ordinary array copies are untouched.
static id correctedCopy(id object, SEL selector) {
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    id result = originalCopy(object, selector);
    if (caller == destroyedReturn) {
#ifdef QUICKFILE_AX_COPY_LIFETIME
        QuickFileAXObserveCopyLifetime(result, NO);
#endif
        [result autorelease];
        atomic_fetch_add_explicit(&compensated, 1, memory_order_relaxed);
    }
    return result;
}

// The merge branch does not tail-call. Require both exact return PCs, rather
// than matching an arbitrary ancestor anywhere in a backtrace.
static id correctedMutableCopy(id object, SEL selector) {
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    BOOL matches = NO;
    if (caller == mergedReturn) {
        void *frames[4];
        int count = backtrace(frames, 4);
        matches = count > 2 && (uintptr_t)frames[1] == mergedReturn && (uintptr_t)frames[2] == destroyedReturn;
    }
    id result = originalMutableCopy(object, selector);
    if (matches) {
#ifdef QUICKFILE_AX_COPY_LIFETIME
        QuickFileAXObserveCopyLifetime(result, YES);
#endif
        [result autorelease];
        atomic_fetch_add_explicit(&compensated, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&compensatedMutable, 1, memory_order_relaxed);
    }
    return result;
}

static const struct mach_header_64 *matchingImage(const char *path, const unsigned char uuid[16]) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), path) != 0) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (header->magic != MH_MAGIC_64) return NULL;
        const struct load_command *command = (const void *)(header + 1);
        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (command->cmd == LC_UUID) return memcmp(((const struct uuid_command *)command)->uuid, uuid, 16) == 0 ? header : NULL;
            command = (const void *)((const char *)command + command->cmdsize);
        }
    }
    return NULL;
}

BOOL QuickFileInstallAXCompatibility(void) {
    if (![NSThread isMainThread]) return NO;
    static dispatch_once_t once;
    static BOOL installed;
    dispatch_once(&once, ^{
        const char *disabled = getenv("QUICKFILE_DISABLE_AX_COMPATIBILITY");
        if ((disabled && strcmp(disabled, "1") == 0) ||
            [NSProcessInfo.processInfo.arguments containsObject:@"--disable-ax-compatibility"]) {
            atomic_store(&installationStatus, "disabled-at-startup");
            return;
        }
#if defined(__arm64__)
        // Each pair and both return PCs were independently verified in that exact
        // runtime image. A major OS version alone never enables compensation.
        const struct {
            unsigned char appKitUUID[16], coreUUID[16];
            uintptr_t destroyedOffset, mergedOffset;
        } verifiedImages[] = {
            {{0x93,0x4e,0x31,0x29,0xa9,0x82,0x32,0x9c,0xba,0xce,0x27,0xcb,0xe7,0x3d,0x63,0x20},
             {0xbd,0xc8,0x24,0x15,0xa0,0x29,0x34,0x63,0xac,0x49,0x1a,0x79,0x22,0x08,0xce,0x00},
             0x1b5b1c, 0x5b10ec},
            {{0xb6,0xb4,0xbd,0xad,0x64,0x28,0x3e,0x64,0x87,0x47,0x27,0x57,0x00,0x10,0x9b,0x46},
             {0x9b,0x67,0x27,0x62,0x7b,0x1f,0x30,0xbc,0x96,0xde,0xf1,0x76,0xb3,0x72,0xd6,0x6d},
             0x1b0238, 0x7ec5b4}
        };
        const struct mach_header_64 *appKit = NULL, *core = NULL;
        for (size_t index = 0; index < sizeof(verifiedImages) / sizeof(verifiedImages[0]); index++) {
            appKit = matchingImage("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", verifiedImages[index].appKitUUID);
            core = matchingImage("/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", verifiedImages[index].coreUUID);
            if (appKit && core) {
                destroyedReturn = (uintptr_t)appKit + verifiedImages[index].destroyedOffset;
                mergedReturn = (uintptr_t)appKit + verifiedImages[index].mergedOffset;
                break;
            }
        }
        if (!appKit || !core) { atomic_store(&installationStatus, "unsupported-images"); return; }
        Dl_info site = {0};
        if (!dladdr((void *)destroyedReturn, &site) || !site.dli_sname || strcmp(site.dli_sname, "_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification") || destroyedReturn - (uintptr_t)site.dli_saddr != 608) {
            atomic_store(&installationStatus, "unsupported-call-site"); return;
        }
        Class cls = object_getClass([NSMutableArray arrayWithObject:@"probe"]);
        Method copy = class_getInstanceMethod(cls, @selector(copy));
        Method mutableCopy = class_getInstanceMethod(cls, @selector(mutableCopy));
        if (!copy || !mutableCopy || strcmp(class_getName(cls), "__NSArrayM") || strcmp(method_getTypeEncoding(copy), "@16@0:8") || strcmp(method_getTypeEncoding(mutableCopy), "@16@0:8")) {
            atomic_store(&installationStatus, "unsupported-array-methods"); return;
        }
        Dl_info copyImage = {0}, mutableImage = {0};
        if (!dladdr((void *)method_getImplementation(copy), &copyImage) || !dladdr((void *)method_getImplementation(mutableCopy), &mutableImage) || copyImage.dli_fbase != (const void *)core || mutableImage.dli_fbase != (const void *)core) {
            atomic_store(&installationStatus, "non-system-methods"); return;
        }
        originalCopy = (void *)method_getImplementation(copy);
        originalMutableCopy = (void *)method_getImplementation(mutableCopy);
        if (!class_addMethod(cls, @selector(copy), (IMP)correctedCopy, method_getTypeEncoding(copy))) method_setImplementation(copy, (IMP)correctedCopy);
        if (!class_addMethod(cls, @selector(mutableCopy), (IMP)correctedMutableCopy, method_getTypeEncoding(mutableCopy))) method_setImplementation(mutableCopy, (IMP)correctedMutableCopy);
        installed = YES;
        atomic_store(&installationStatus, "enabled");
#else
        atomic_store(&installationStatus, "unsupported-architecture");
#endif
    });
    return installed;
}
const char *QuickFileAXCompatibilityStatus(void) { return atomic_load(&installationStatus); }
unsigned long QuickFileAXCompensatedCopies(void) { return atomic_load_explicit(&compensated, memory_order_relaxed); }
unsigned long QuickFileAXCompensatedMutableCopies(void) { return atomic_load_explicit(&compensatedMutable, memory_order_relaxed); }
