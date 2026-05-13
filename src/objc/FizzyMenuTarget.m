#import <AppKit/AppKit.h>

/* Called from Zig when a native menu item is chosen. Zig exports this and sets a pending action. */
extern void FizzyNativeMenuAction(int id);

@interface FizzyMenuTarget : NSObject
- (void)newFile:(id)sender;
- (void)openFolder:(id)sender;
- (void)openFiles:(id)sender;
- (void)save:(id)sender;
- (void)saveAs:(id)sender;
- (void)copy:(id)sender;
- (void)paste:(id)sender;
- (void)undo:(id)sender;
- (void)redo:(id)sender;
- (void)transform:(id)sender;
- (void)gridLayout:(id)sender;
- (void)toggleExplorer:(id)sender;
- (void)showDvuiDemo:(id)sender;
- (void)about:(id)sender;
- (void)checkForUpdates:(id)sender;
@end

@implementation FizzyMenuTarget
- (void)newFile:(id)sender       { (void)sender; FizzyNativeMenuAction(11); }
- (void)openFolder:(id)sender     { (void)sender; FizzyNativeMenuAction(0); }
- (void)openFiles:(id)sender     { (void)sender; FizzyNativeMenuAction(1); }
- (void)save:(id)sender          { (void)sender; FizzyNativeMenuAction(2); }
- (void)saveAs:(id)sender        { (void)sender; FizzyNativeMenuAction(10); }
- (void)copy:(id)sender          { (void)sender; FizzyNativeMenuAction(3); }
- (void)paste:(id)sender         { (void)sender; FizzyNativeMenuAction(4); }
- (void)undo:(id)sender          { (void)sender; FizzyNativeMenuAction(5); }
- (void)redo:(id)sender         { (void)sender; FizzyNativeMenuAction(6); }
- (void)transform:(id)sender     { (void)sender; FizzyNativeMenuAction(7); }
- (void)gridLayout:(id)sender    { (void)sender; FizzyNativeMenuAction(12); }
- (void)toggleExplorer:(id)sender { (void)sender; FizzyNativeMenuAction(8); }
- (void)showDvuiDemo:(id)sender  { (void)sender; FizzyNativeMenuAction(9); }
- (void)about:(id)sender         { (void)sender; FizzyNativeMenuAction(13); }
- (void)checkForUpdates:(id)sender { (void)sender; FizzyNativeMenuAction(14); }
@end

/* So Zig can get the SEL for setAction: without linking the Objective-C runtime directly. */
void *FizzyGetSelector(const char *name) {
    return (void *)sel_registerName(name);
}
