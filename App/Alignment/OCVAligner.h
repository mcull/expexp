// Placeholder Objective-C++ wrapper header for OpenCV alignment.
// Not wired into the build yet. Implementation to follow when OpenCV is added.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OCVTransformKind) {
    OCVTransformKindIdentity = 0,
    OCVTransformKindHomography,
    OCVTransformKindAffinePartial,
};

@interface OCVAlignmentResult : NSObject
@property(nonatomic, strong) UIImage *alignedImage;
@property(nonatomic, assign) OCVTransformKind kind;
@property(nonatomic, strong) NSArray<NSNumber *> *matrix; // 3x3 (9) for H or 2x3 (6) for affine
@property(nonatomic, assign) NSInteger inliers;
@property(nonatomic, assign) double inlierRatio;
@property(nonatomic, assign) NSInteger runtimeMS;
@end

@interface OCVAligner : NSObject
- (instancetype)init;
- (OCVAlignmentResult *)alignMoving:(UIImage *)moving
                          reference:(UIImage *)reference
                           options:(NSDictionary *)options; // keys TBD
@end

NS_ASSUME_NONNULL_END

