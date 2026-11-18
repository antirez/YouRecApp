// A borderless, app-owned chart for ScreenCaptureKit hardware tests.
#import <AppKit/AppKit.h>

static NSWindow *chart;

uint32_t YouRecOpenChart(void) {
    if (chart) return (uint32_t)chart.windowNumber;
    NSWindow *recorder = NSApp.keyWindow ?: NSApp.mainWindow;
    chart = [[NSWindow alloc] initWithContentRect:NSMakeRect(20, 50, 640, 360)
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered defer:NO];
    chart.title = @"YouRec PiP regression chart";
    chart.backgroundColor = [NSColor colorWithSRGBRed:0.92 green:0.05 blue:0.87 alpha:1];
    chart.hasShadow = NO;
    chart.ignoresMouseEvents = YES;
    chart.level = NSNormalWindowLevel - 1;
    [chart orderBack:nil];
    if (recorder) [recorder orderWindow:NSWindowAbove relativeTo:chart.windowNumber];
    [chart displayIfNeeded];
    return (uint32_t)chart.windowNumber;
}
