#import <Foundation/Foundation.h>

@interface MP42TS : NSObject

+ (nullable NSData *)convertMP4ToTS:(nonnull NSData *)mp4Data error:(NSError * _Nullable *)error;

@end
