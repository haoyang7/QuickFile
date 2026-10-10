#import <Foundation/Foundation.h>

// Main-thread startup only. Returns NO for unverified systems or method changes.
FOUNDATION_EXPORT BOOL QuickFileInstallAXCompatibility(void);
// Startup decision only. The disable flag is read once; no runtime uninstallation.
FOUNDATION_EXPORT const char *QuickFileAXCompatibilityStatus(void);
// Diagnostic count only; never used to decide ownership.
FOUNDATION_EXPORT unsigned long QuickFileAXCompensatedCopies(void);
FOUNDATION_EXPORT unsigned long QuickFileAXCompensatedMutableCopies(void);
