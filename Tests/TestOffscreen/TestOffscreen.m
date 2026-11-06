// Every window a test orders in stays invisible, and nothing a test does activates the test process,
// so `swift test`, test.sh and the snapshot checks never appear on Junior's screens or take focus.
// Windows are still ordered in (isVisible, layout, hit tests and offscreen rendering all work); they are
// just fully transparent and let clicks through. Runs when the test bundle loads, before any test.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "TestOffscreen.h"

void TestOffscreenInstalled(void) {}

static void swap(Class type, SEL original, SEL replacement) {
  Method old = class_getInstanceMethod(type, original), new = class_getInstanceMethod(type, replacement);
  if (!old || !new) return;
  if (class_addMethod(type, original, method_getImplementation(new), method_getTypeEncoding(new)))
    class_replaceMethod(type, replacement, method_getImplementation(old), method_getTypeEncoding(old));
  else
    method_exchangeImplementations(old, new);
}

@implementation NSWindow (TestOffscreen)
- (void)testOffscreen_hide { [self testOffscreen_setAlphaValue:0]; self.ignoresMouseEvents = YES; }
- (void)testOffscreen_setAlphaValue:(CGFloat)value { [self testOffscreen_setAlphaValue:0]; }
- (void)testOffscreen_orderWindow:(NSWindowOrderingMode)mode relativeTo:(NSInteger)other {
  [self testOffscreen_hide]; [self testOffscreen_orderWindow:mode relativeTo:other];
}
- (void)testOffscreen_orderFront:(id)sender { [self testOffscreen_hide]; [self testOffscreen_orderFront:sender]; }
- (void)testOffscreen_orderFrontRegardless { [self testOffscreen_hide]; [self testOffscreen_orderFrontRegardless]; }
- (void)testOffscreen_makeKeyAndOrderFront:(id)sender { [self testOffscreen_hide]; [self testOffscreen_makeKeyAndOrderFront:sender]; }
@end

@implementation NSApplication (TestOffscreen)
- (void)testOffscreen_activateIgnoringOtherApps:(BOOL)flag {}
- (void)testOffscreen_activate {}
@end

__attribute__((constructor)) static void installTestOffscreen(void) {
  Class window = NSWindow.class, app = NSApplication.class;
  swap(window, @selector(setAlphaValue:), @selector(testOffscreen_setAlphaValue:));
  swap(window, @selector(orderWindow:relativeTo:), @selector(testOffscreen_orderWindow:relativeTo:));
  swap(window, @selector(orderFront:), @selector(testOffscreen_orderFront:));
  swap(window, @selector(orderFrontRegardless), @selector(testOffscreen_orderFrontRegardless));
  swap(window, @selector(makeKeyAndOrderFront:), @selector(testOffscreen_makeKeyAndOrderFront:));
  swap(app, @selector(activateIgnoringOtherApps:), @selector(testOffscreen_activateIgnoringOtherApps:));
  swap(app, @selector(activate), @selector(testOffscreen_activate));
}
