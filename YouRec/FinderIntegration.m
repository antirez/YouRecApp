#import <AppKit/AppKit.h>

// Mac Catalyst calls this native macOS plug-in through its Objective-C protocol.
@protocol YouRecFinderServing
+ (void)reveal:(NSURL *)url;
+ (id)observeWheel:(BOOL (^)(CGPoint windowFraction, CGFloat delta))handler;
+ (id)observeSecondaryClick:(BOOL (^)(CGPoint windowFraction))handler;
@end

@interface YouRecMouseObservation : NSObject
@property(strong) id monitor;
@end
@implementation YouRecMouseObservation
- (void)dealloc {
    if (_monitor) [NSEvent removeMonitor:_monitor];
}
@end

@interface YouRecFinderIntegration : NSObject <YouRecFinderServing>
@end

static BOOL YouRecWindowPoint(NSEvent *event, CGPoint *fraction) {
    NSWindow *window = NSApp.keyWindow;
    if (!window || (event.window && event.window != window) || NSApp.modalWindow) return NO;
    NSView *view = window.contentView;
    if (NSIsEmptyRect(view.bounds)) return NO;
    NSPoint location = event.window ? event.locationInWindow : [window convertPointFromScreen:event.locationInWindow];
    NSPoint p = [view convertPoint:location fromView:nil];
    if (!NSPointInRect(p, view.bounds)) return NO;
    CGFloat x = (p.x - NSMinX(view.bounds)) / NSWidth(view.bounds);
    CGFloat y = (p.y - NSMinY(view.bounds)) / NSHeight(view.bounds);
    *fraction = CGPointMake(x, view.isFlipped ? y : 1 - y);
    return YES;
}

@implementation YouRecFinderIntegration
+ (void)reveal:(NSURL *)url {
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
}

+ (id)observeWheel:(BOOL (^)(CGPoint, CGFloat))handler {
    YouRecMouseObservation *observation = [YouRecMouseObservation new];
    observation.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *event) {
        // Gesture phases identify two-finger scrolling and its momentum. A high-
        // resolution mouse wheel can also use point deltas, without those phases.
        if (event.phase != NSEventPhaseNone || event.momentumPhase != NSEventPhaseNone ||
            fabs(event.scrollingDeltaY) <= fabs(event.scrollingDeltaX)) return event;
        CGPoint fraction;
        if (!YouRecWindowPoint(event, &fraction)) return event;
        CGFloat delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY;
        // Point-based devices report about ten points for one ordinary wheel line.
        CGFloat lines = event.hasPreciseScrollingDeltas ? delta / 10.0 : delta;
        return handler(fraction, lines) ? nil : event;
    }];
    return observation;
}
+ (id)observeSecondaryClick:(BOOL (^)(CGPoint))handler {
    YouRecMouseObservation *observation = [YouRecMouseObservation new];
    observation.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown handler:^NSEvent *(NSEvent *event) {
        CGPoint fraction;
        return YouRecWindowPoint(event, &fraction) && handler(fraction) ? nil : event;
    }];
    return observation;
}
@end
