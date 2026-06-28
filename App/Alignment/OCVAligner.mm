// Placeholder Objective-C++ wrapper implementation (no OpenCV calls yet).
// Add OpenCV includes and real implementation in a follow-up step.

#import "OCVAligner.h"

@implementation OCVAlignmentResult
@end

@implementation OCVAligner

- (instancetype)init { self = [super init]; return self; }

- (OCVAlignmentResult *)alignMoving:(UIImage *)moving reference:(UIImage *)reference options:(NSDictionary *)options {
    OCVAlignmentResult *res = [OCVAlignmentResult new];
    res.alignedImage = moving; // no-op for now
    res.kind = OCVTransformKindIdentity;
    res.matrix = @[@1,@0,@0, @0,@1,@0, @0,@0,@1];
    res.inliers = 0;
    res.inlierRatio = 0.0;
    res.runtimeMS = 0;
    return res;
}

@end

