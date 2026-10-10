// Self-driven, synthetic fixture only; no actions on QuickFile or Finder.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <mach-o/dyld.h>
#import "AXCompatibility.h"
#ifdef QUICKFILE_AX_OWNERSHIP_PROBE
extern void AXOwnershipProbeInstall(NSString *directory, BOOL balance);
extern NSDictionary *AXOwnershipProbeSnapshot(void);
#endif
static NSDictionary *systemImages(void) {
    NSMutableDictionary *images = [NSMutableDictionary new];
    NSDictionary *wanted = @{
        @"/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit": @"AppKit",
        @"/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation": @"CoreFoundation"
    };
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        NSString *name = wanted[@(_dyld_get_image_name(i))];
        if (!name) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (header->magic != MH_MAGIC_64) continue;
        const struct load_command *command = (const void *)(header + 1);
        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (command->cmd == LC_UUID) {
                images[name] = [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
                break;
            }
            command = (const void *)((const char *)command + command->cmdsize);
        }
    }
    return images;
}
static NSUInteger allocatedButtons = 0, destroyedButtons = 0;
@interface OwnedButton : NSButton @end
@implementation OwnedButton
- (instancetype)initWithFrame:(NSRect)frame { if ((self = [super initWithFrame:frame])) allocatedButtons++; return self; }
- (void)dealloc { destroyedButtons++; }
@end
@interface Owner : NSObject
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSMutableArray<OwnedButton *> *buttons;
@property(nonatomic, copy) NSString *directory;
@property NSInteger lastSequence;
@property(nonatomic, strong) NSTimer *timer;
@end
@implementation Owner
- (void)publish:(NSInteger)sequence action:(NSString *)action {
    NSMutableDictionary *record = [@{@"compensations":@(QuickFileAXCompensatedCopies()), @"mutableCompensations":@(QuickFileAXCompensatedMutableCopies()), @"pid":@(getpid()), @"sequence":@(sequence), @"action":action,
       @"buttons":@(self.buttons.count), @"allocatedButtons":@(allocatedButtons), @"destroyedButtons":@(destroyedButtons)} mutableCopy];
#ifdef QUICKFILE_AX_OWNERSHIP_PROBE
    record[@"ownership"] = AXOwnershipProbeSnapshot();
#endif
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    [data writeToFile:[self.directory stringByAppendingPathComponent:@"ready.json"] atomically:YES];
}
- (void)poll {
 @autoreleasepool {
    if ([[NSFileManager defaultManager] fileExistsAtPath:[self.directory stringByAppendingPathComponent:@"quit"]]) {
        [self.timer invalidate]; [NSApp terminate:nil]; return;
    }
    NSData *data = [NSData dataWithContentsOfFile:[self.directory stringByAppendingPathComponent:@"command.json"]];
    NSDictionary *command = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSInteger sequence = [command[@"sequence"] integerValue];
    if (sequence <= self.lastSequence) return;
    self.lastSequence = sequence;
    NSString *action = command[@"action"];
    if ([action isEqual:@"add"]) {
        NSAssert(self.buttons.count == 0, @"prior buttons must be removed");
        NSUInteger count = [command[@"count"] unsignedIntegerValue]; NSAssert(count <= 100, @"bounded fixture");
        for (NSUInteger i = 0; i < count; i++) {
            OwnedButton *button = [[OwnedButton alloc] initWithFrame:NSMakeRect(20, 20 + 28 * i, 250, 24)];
            button.title = [NSString stringWithFormat:@"Owned AX %lu", (unsigned long)i];
            button.accessibilityIdentifier = [NSString stringWithFormat:@"owned-ax-%lu", (unsigned long)i];
            [self.window.contentView addSubview:button]; [self.buttons addObject:button];
        }
    } else if ([action isEqual:@"remove"]) {
        for (OwnedButton *button in self.buttons) [button removeFromSuperview];
        [self.buttons removeAllObjects];
    } else if ([action isEqual:@"checkpoint"]) {
    } else { [NSException raise:@"Invalid command" format:@"Unknown action"]; }
    [self.window.contentView layoutSubtreeIfNeeded]; [self.window.contentView displayIfNeeded];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self publish:sequence action:action]; });
 }
}
@end
int main(int argc, const char **argv) {
 @autoreleasepool {
    BOOL systemBaseline = argc == 3 && !strcmp(argv[2], "--system-baseline");
    if (argc != 2 && !systemBaseline) return 2;
    // A system baseline never installs or attempts the product compensation.
    BOOL enabled = systemBaseline ? NO : QuickFileInstallAXCompatibility();
    if (!strcmp(argv[1], "--capabilities")) {
        NSDictionary *capabilities = @{@"enabled":@(enabled),
            @"status":systemBaseline ? @"system-baseline" : @(QuickFileAXCompatibilityStatus()), @"images":systemImages()};
        NSData *json = [NSJSONSerialization dataWithJSONObject:capabilities options:NSJSONWritingSortedKeys error:NULL];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        return 0;
    }
    if (!enabled && !systemBaseline) return 3;
#ifdef QUICKFILE_AX_OWNERSHIP_PROBE
    if (!systemBaseline) return 4;
    AXOwnershipProbeInstall(@(argv[1]), QUICKFILE_AX_OWNERSHIP_PROBE == 2);
#endif
    NSApplication *app = NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    Owner *owner = [Owner new]; owner.directory = @(argv[1]); owner.buttons = [NSMutableArray new];
    owner.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,320,380) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    owner.window.title = @"QuickFile AX Compatibility Test"; owner.window.releasedWhenClosed = NO;
    [owner.window orderFront:nil];
    __weak Owner *weakOwner = owner;
    owner.timer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) { [weakOwner poll]; }];
    [owner publish:0 action:@"launched"]; [app run];
 }
 return 0;
}
