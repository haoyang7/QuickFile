// Run with MRC to verify owned copy results survive an inner autorelease pool.
#import <AppKit/AppKit.h>
#import "AXCompatibility.h"
#import <mach-o/dyld.h>
#include <assert.h>

// Independent runtime identity check: a broken installer returning NO must fail
// on the supported image, rather than silently turning this into a no-patch test.
static BOOL hasImage(const char *path, const unsigned char expected[16]) {
 for (uint32_t i = 0; i < _dyld_image_count(); i++) {
  if (strcmp(_dyld_get_image_name(i), path)) continue;
  const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
  const struct load_command *command = (const void *)(header + 1);
  for (uint32_t j = 0; j < header->ncmds; j++) {
   if (command->cmd == LC_UUID) return memcmp(((const struct uuid_command *)command)->uuid, expected, 16) == 0;
   command = (const void *)((const char *)command + command->cmdsize);
  }
 }
 return NO;
}
int main(int argc, const char **argv) {
 @autoreleasepool {
  BOOL verified = NO;
#if defined(__arm64__)
  const unsigned char appKit[] = {0x93,0x4e,0x31,0x29,0xa9,0x82,0x32,0x9c,0xba,0xce,0x27,0xcb,0xe7,0x3d,0x63,0x20};
  const unsigned char core[] = {0xbd,0xc8,0x24,0x15,0xa0,0x29,0x34,0x63,0xac,0x49,0x1a,0x79,0x22,0x08,0xce,0x00};
  const unsigned char appKit26[] = {0xb6,0xb4,0xbd,0xad,0x64,0x28,0x3e,0x64,0x87,0x47,0x27,0x57,0x00,0x10,0x9b,0x46};
  const unsigned char core26[] = {0x9b,0x67,0x27,0x62,0x7b,0x1f,0x30,0xbc,0x96,0xde,0xf1,0x76,0xb3,0x72,0xd6,0x6d};
  verified = hasImage("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", appKit)
      && hasImage("/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", core);
  verified |= hasImage("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", appKit26)
      && hasImage("/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", core26);
#endif
  BOOL expectDisabled = [NSProcessInfo.processInfo.arguments containsObject:@"--expect-disabled"];
  BOOL enabled = QuickFileInstallAXCompatibility();
  printf("compatibility=%d\n", enabled);
  printf("verified-system=%d status=%s\n", verified, QuickFileAXCompatibilityStatus());
  if (enabled != (verified && !expectDisabled)) {
   fputs("AX compatibility startup decision did not match the expected runtime identity\n", stderr);
   return 1;
  }
  // The opt-out is startup-only. Later environment changes cannot unload a hook.
  setenv("QUICKFILE_DISABLE_AX_COMPATIBILITY", "1", 1);
  assert(QuickFileInstallAXCompatibility() == enabled);
  dispatch_apply(2000, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t iteration) {
   @autoreleasepool {
    NSMutableArray *source = [[NSMutableArray alloc] initWithObjects:@(iteration), nil];
    NSArray *copy;
    NSMutableArray *mutableCopy;
    @autoreleasepool {
     copy = [source copy];
     mutableCopy = [source mutableCopy];
    }
    [source removeAllObjects];
    [source release];
    assert(copy.count == 1 && [copy[0] unsignedLongValue] == iteration);
    assert(mutableCopy.count == 1 && [mutableCopy[0] unsignedLongValue] == iteration);
    [mutableCopy addObject:@"independent"];
    assert(copy.count == 1 && mutableCopy.count == 2);
    [copy release];
    [mutableCopy release];
   }
  });
  assert(QuickFileAXCompensatedCopies() == 0);
  assert(QuickFileAXCompensatedMutableCopies() == 0);
  puts("2000 concurrent copy/mutableCopy ownership checks passed");
 }
 return 0;
}
