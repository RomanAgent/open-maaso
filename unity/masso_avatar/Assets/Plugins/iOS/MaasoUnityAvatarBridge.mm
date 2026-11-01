#import <Foundation/Foundation.h>

extern "C" void MaasoUnityAvatarReady(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"MaasoUnityAvatarReady"
                      object:nil];
  });
}

extern "C" void MaasoUnityAvatarCommandResult(const char* payload) {
  NSString* value = payload == nullptr ? @"" : [NSString stringWithUTF8String:payload];
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"MaasoUnityAvatarCommandResult"
                      object:nil
                    userInfo:@{ @"payload": value ?: @"" }];
  });
}
