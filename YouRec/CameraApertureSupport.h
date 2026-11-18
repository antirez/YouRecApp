#pragma once
#import <AVFoundation/AVFoundation.h>

// Xcode 26 can deploy to iOS 27. Declare the public AVFoundation methods
// missing from its headers. Newer SDKs check the calls against Apple's headers.
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 270000
#import <dlfcn.h>
@interface AVCaptureDeviceFormat (YouRecPublicApertureAPI)
@property(nonatomic, readonly) NSArray<NSNumber *> * _Nonnull recommendedLensApertureStops;
@property(nonatomic, readonly) float minLensAperture, maxLensAperture;
- (BOOL)supportsExposureModeCustomWithLensAperture:(float)aperture duration:(CMTime)duration ISO:(float)iso;
@end
@interface AVCaptureDevice (YouRecPublicApertureAPI)
- (void)setExposureModeCustomWithLensAperture:(float)aperture duration:(CMTime)duration ISO:(float)iso
                           completionHandler:(nullable void (^)(CMTime))completion;
@property(nonatomic, readonly) BOOL automaticallyAdjustsLensAperture, automaticallyAdjustsExposureDuration, automaticallyAdjustsISO;
@end
#endif

NS_ASSUME_NONNULL_BEGIN

// The automatic shutter/ISO constants are exported by AVFoundation at run
// time. Never substitute a numerical guess for either camera setting.
API_AVAILABLE(ios(27.0), macCatalyst(27.0))
static inline BOOL YRApertureAutomaticExposure(CMTime *duration, float *iso) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270000
    *duration = AVCaptureExposureDurationAuto;
    *iso = AVCaptureISOAuto;
#else
    const CMTime *automaticDuration = (const CMTime *)dlsym(RTLD_DEFAULT, "AVCaptureExposureDurationAuto");
    const float *automaticISO = (const float *)dlsym(RTLD_DEFAULT, "AVCaptureISOAuto");
    if (!automaticDuration || !automaticISO) return NO;
    *duration = *automaticDuration;
    *iso = *automaticISO;
#endif
    return YES;
}

API_AVAILABLE(ios(27.0), macCatalyst(27.0))
static inline NSArray<NSNumber *> *YRApertureStops(AVCaptureDeviceFormat *format) {
    return format.recommendedLensApertureStops;
}

API_AVAILABLE(ios(27.0), macCatalyst(27.0))
static inline BOOL YRApertureSupports(AVCaptureDeviceFormat *format, float aperture) {
    CMTime duration; float iso;
    return YRApertureAutomaticExposure(&duration, &iso)
        && [format supportsExposureModeCustomWithLensAperture:aperture duration:duration ISO:iso];
}

API_AVAILABLE(ios(27.0), macCatalyst(27.0))
static inline void YRSetAperture(AVCaptureDevice *device, float aperture) {
    CMTime duration; float iso;
    if (YRApertureAutomaticExposure(&duration, &iso)) {
        [device setExposureModeCustomWithLensAperture:aperture duration:duration ISO:iso completionHandler:nil];
    }
}
NS_ASSUME_NONNULL_END
