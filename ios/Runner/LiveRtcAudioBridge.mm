// Shared avatar texture transport; the retired Live RTC publisher is removed.
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Flutter/Flutter.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

#include <atomic>
#include <cstdint>
#include <dlfcn.h>
#include <mutex>

using MaasoUnitySendMessageFunction = void (*)(const char *, const char *, const char *);

@interface MaasoAvatarPortalTextureBridge : NSObject <FlutterTexture> {
 @private
  std::mutex _frameMutex;
  CVPixelBufferPoolRef _pixelBufferPool;
  CVMetalTextureCacheRef _portalTextureCache;
  CVPixelBufferRef _latestPixelBuffer;
  std::atomic<int32_t> _activeGeneration;
}
@property(nonatomic, strong) id<FlutterTextureRegistry> textureRegistry;
@property(nonatomic, strong) FlutterMethodChannel *channel;
@property(nonatomic, assign) int64_t textureId;
@property(nonatomic, assign) int32_t width;
@property(nonatomic, assign) int32_t height;
@property(nonatomic, assign) int32_t firstFrameGeneration;
@property(nonatomic, strong) dispatch_semaphore_t inFlightFrames;
@property(nonatomic, strong) id<MTLDevice> portalMetalDevice;
@property(nonatomic, strong) id<MTLRenderPipelineState> portalCopyPipeline;
@end

@implementation MaasoAvatarPortalTextureBridge

static void MaasoAvatarPortalAttachSRGBMetadata(CVPixelBufferRef pixelBuffer) {
  if (pixelBuffer == nil) return;
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (colorSpace != nil) {
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferCGColorSpaceKey,
        colorSpace,
        kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRelease(colorSpace);
  }
  CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferColorPrimariesKey,
      kCVImageBufferColorPrimaries_ITU_R_709_2,
      kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_sRGB,
      kCVAttachmentMode_ShouldPropagate);
}

static id<MTLRenderPipelineState> MaasoAvatarPortalCreateCopyPipeline(
    id<MTLDevice> device) {
  if (device == nil) return nil;
  static const char *shaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct MaasoPortalVertexOut {
  float4 position [[position]];
};

vertex MaasoPortalVertexOut maasoPortalCopyVertex(uint vertexId [[vertex_id]]) {
  const float2 positions[3] = {
    float2(-1.0, -1.0),
    float2(3.0, -1.0),
    float2(-1.0, 3.0),
  };
  MaasoPortalVertexOut output;
  output.position = float4(positions[vertexId], 0.0, 1.0);
  return output;
}

fragment float4 maasoPortalCopyFragment(
    MaasoPortalVertexOut input [[stage_in]],
    texture2d<float, access::read> source [[texture(0)]]) {
  return source.read(uint2(input.position.xy));
}
)METAL";
  NSError *libraryError = nil;
  id<MTLLibrary> library = [device
      newLibraryWithSource:[NSString stringWithUTF8String:shaderSource]
                                                options:nil
                                                  error:&libraryError];
  if (library == nil) {
    NSLog(@"[AvatarPortal] Metal copy shader unavailable: %@", libraryError);
    return nil;
  }
  MTLRenderPipelineDescriptor *descriptor =
      [[MTLRenderPipelineDescriptor alloc] init];
  descriptor.label = @"Maaso Avatar Portal Color Copy";
  descriptor.vertexFunction = [library newFunctionWithName:@"maasoPortalCopyVertex"];
  descriptor.fragmentFunction =
      [library newFunctionWithName:@"maasoPortalCopyFragment"];
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
  NSError *pipelineError = nil;
  id<MTLRenderPipelineState> pipeline =
      [device newRenderPipelineStateWithDescriptor:descriptor
                                             error:&pipelineError];
  if (pipeline == nil) {
    NSLog(@"[AvatarPortal] Metal color pipeline unavailable: %@", pipelineError);
  }
  return pipeline;
}

- (instancetype)initWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  self = [super init];
  if (self == nil) return nil;
  _textureRegistry = registrar.textures;
  _channel = [FlutterMethodChannel
      methodChannelWithName:@"maaso/avatar_portal"
            binaryMessenger:registrar.messenger];
  _textureId = -1;
  _width = 0;
  _height = 0;
  _firstFrameGeneration = 0;
  _activeGeneration.store(0);
  _inFlightFrames = dispatch_semaphore_create(3);
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (device != nil) {
    _portalMetalDevice = device;
    CVMetalTextureCacheCreate(
        kCFAllocatorDefault,
        nil,
        device,
        nil,
        &_portalTextureCache);
  }
  __weak MaasoAvatarPortalTextureBridge *weakSelf = self;
  [_channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    [weakSelf handleCall:call result:result];
  }];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(handleMemoryWarning)
             name:UIApplicationDidReceiveMemoryWarningNotification
           object:nil];
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self releaseLeaseAndNotifyUnity:YES];
  if (_portalTextureCache != nil) {
    CFRelease(_portalTextureCache);
    _portalTextureCache = nil;
  }
}

- (void)handleCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *arguments = [call.arguments isKindOfClass:NSDictionary.class]
      ? (NSDictionary *)call.arguments
      : @{};
  NSNumber *generationValue = arguments[@"generation"];
  int32_t generation = generationValue.intValue;
  if ([call.method isEqualToString:@"acquire"]) {
    if (generation <= 0) {
      result([FlutterError errorWithCode:@"invalid_avatar_portal_generation"
                                 message:@"Avatar portal generation must be positive."
                                 details:nil]);
      return;
    }
    NSString *profile = [arguments[@"profile"] isKindOfClass:NSString.class]
        ? arguments[@"profile"]
        : @"compactHigh";
    [self acquireGeneration:generation profile:profile result:result];
    return;
  }
  if ([call.method isEqualToString:@"suspend"] ||
      [call.method isEqualToString:@"resume"]) {
    if (![self generationMatches:generation]) {
      result(nil);
      return;
    }
    [self sendUnityMethod:call.method generation:generation profile:nil];
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"release"]) {
    if (generation <= 0 || [self generationMatches:generation]) {
      [self releaseLeaseAndNotifyUnity:YES];
    }
    result(nil);
    return;
  }
  result(FlutterMethodNotImplemented);
}

- (void)acquireGeneration:(int32_t)generation
                   profile:(NSString *)profile
                    result:(FlutterResult)result {
  [self releaseLeaseAndNotifyUnity:YES];
  [self resolveProfile:profile width:&_width height:&_height];
  if (self.portalCopyPipeline == nil) {
    self.portalCopyPipeline =
        MaasoAvatarPortalCreateCopyPipeline(self.portalMetalDevice);
  }
  if (![self configurePixelBufferPool]) {
    result([FlutterError errorWithCode:@"avatar_portal_texture_unavailable"
                                 message:@"The iOS Avatar portal texture could not be allocated."
                                 details:nil]);
    return;
  }
  self.textureId = [self.textureRegistry registerTexture:self];
  if (self.textureId < 0) {
    [self destroyPixelBufferPool];
    result([FlutterError errorWithCode:@"avatar_portal_registration_failed"
                                 message:@"Flutter rejected the Avatar portal texture."
                                 details:nil]);
    return;
  }
  self.firstFrameGeneration = 0;
  _activeGeneration.store(generation);
  if (![self sendUnityMethod:@"acquire"
                  generation:generation
                     profile:profile]) {
    [self releaseLeaseAndNotifyUnity:NO];
    result([FlutterError errorWithCode:@"avatar_portal_unity_unavailable"
                                 message:@"The existing Unity Avatar runtime is unavailable."
                                 details:nil]);
    return;
  }
  result(@{
    @"textureId" : @(self.textureId),
    @"width" : @(self.width),
    @"height" : @(self.height),
    @"generation" : @(generation),
  });
}

- (BOOL)configurePixelBufferPool {
  [self destroyPixelBufferPool];
  if (_portalTextureCache == nil || self.portalCopyPipeline == nil ||
      self.width <= 0 || self.height <= 0) {
    return NO;
  }
  NSDictionary *pixelBufferAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(self.width),
    (id)kCVPixelBufferHeightKey : @(self.height),
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  NSDictionary *poolAttributes = @{
    (id)kCVPixelBufferPoolMinimumBufferCountKey : @3,
  };
  CVReturn status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      (__bridge CFDictionaryRef)poolAttributes,
      (__bridge CFDictionaryRef)pixelBufferAttributes,
      &_pixelBufferPool);
  return status == kCVReturnSuccess && _pixelBufferPool != nil;
}

- (void)destroyPixelBufferPool {
  {
    std::lock_guard<std::mutex> lock(_frameMutex);
    if (_latestPixelBuffer != nil) {
      CVPixelBufferRelease(_latestPixelBuffer);
      _latestPixelBuffer = nil;
    }
  }
  if (_pixelBufferPool != nil) {
    CVPixelBufferPoolRelease(_pixelBufferPool);
    _pixelBufferPool = nil;
  }
}

- (void)releaseLeaseAndNotifyUnity:(BOOL)notifyUnity {
  int32_t generation = _activeGeneration.exchange(0);
  self.firstFrameGeneration = 0;
  if (notifyUnity && generation > 0) {
    [self sendUnityMethod:@"release" generation:generation profile:nil];
  }
  int64_t textureId = self.textureId;
  self.textureId = -1;
  if (textureId >= 0) {
    [self.textureRegistry unregisterTexture:textureId];
  }
  [self destroyPixelBufferPool];
  self.width = 0;
  self.height = 0;
}

- (void)handleMemoryWarning {
  [self releaseLeaseAndNotifyUnity:YES];
  [self.channel invokeMethod:@"event"
                   arguments:@{
                     @"type" : @"released",
                     @"reason" : @"memoryPressure",
                   }];
}

- (BOOL)generationMatches:(int32_t)generation {
  return generation > 0 && _activeGeneration.load() == generation;
}

- (void)reportEventType:(NSString *)type generation:(int32_t)generation {
  if (type.length == 0 || ![self generationMatches:generation]) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![self generationMatches:generation]) return;
    [self.channel invokeMethod:@"event"
                    arguments:@{
                      @"type" : type,
                      @"generation" : @(generation),
                    }];
  });
}

- (BOOL)sendUnityMethod:(NSString *)method
             generation:(int32_t)generation
                profile:(NSString *)profile {
  static MaasoUnitySendMessageFunction sendMessage =
      reinterpret_cast<MaasoUnitySendMessageFunction>(
          dlsym(RTLD_DEFAULT, "UnitySendMessage"));
  if (sendMessage == nullptr) return NO;
  NSMutableDictionary *payload = [@{
    @"method" : method,
    @"generation" : @(generation),
  } mutableCopy];
  if (profile.length > 0) payload[@"profile"] = profile;
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSString *json = encoded == nil
      ? nil
      : [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
  if (json.length == 0) return NO;
  sendMessage(
      "Maaso Avatar Portal",
      "OnAvatarPortalCommand",
      json.UTF8String);
  return YES;
}

- (void)resolveProfile:(NSString *)profile
                  width:(int32_t *)width
                 height:(int32_t *)height {
  if ([profile isEqualToString:@"compactLow"]) {
    *width = 240;
    *height = 416;
  } else if ([profile isEqualToString:@"compactBalanced"]) {
    *width = 288;
    *height = 496;
  } else {
    *width = 320;
    *height = 560;
  }
}

- (CVPixelBufferRef)copyPixelBuffer {
  std::lock_guard<std::mutex> lock(_frameMutex);
  CVPixelBufferRef pixelBuffer = _latestPixelBuffer;
  _latestPixelBuffer = nil;
  return pixelBuffer;
}

- (void)onTextureUnregistered:(NSObject<FlutterTexture> *)texture {
  (void)texture;
}

- (void)submitMetalTexture:(void *)texture
              commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                      width:(int32_t)width
                     height:(int32_t)height
                 generation:(int32_t)generation {
  if (texture == nullptr || commandBuffer == nil ||
      ![self generationMatches:generation] ||
      width != self.width || height != self.height ||
      _pixelBufferPool == nil || _portalTextureCache == nil ||
      dispatch_semaphore_wait(self.inFlightFrames, DISPATCH_TIME_NOW) != 0) {
    return;
  }
  CVPixelBufferRef pixelBuffer = nil;
  CVReturn bufferStatus = CVPixelBufferPoolCreatePixelBuffer(
      kCFAllocatorDefault,
      _pixelBufferPool,
      &pixelBuffer);
  if (bufferStatus != kCVReturnSuccess || pixelBuffer == nil) {
    dispatch_semaphore_signal(self.inFlightFrames);
    return;
  }
  MaasoAvatarPortalAttachSRGBMetadata(pixelBuffer);
  CVMetalTextureRef cvTexture = nil;
  CVReturn textureStatus = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      _portalTextureCache,
      pixelBuffer,
      nil,
      MTLPixelFormatBGRA8Unorm_sRGB,
      width,
      height,
      0,
      &cvTexture);
  id<MTLTexture> destination = cvTexture == nil
      ? nil
      : CVMetalTextureGetTexture(cvTexture);
  id<MTLTexture> source = (__bridge id<MTLTexture>)texture;
  if (textureStatus != kCVReturnSuccess || destination == nil || source == nil) {
    if (cvTexture != nil) CFRelease(cvTexture);
    CVPixelBufferRelease(pixelBuffer);
    dispatch_semaphore_signal(self.inFlightFrames);
    return;
  }
  MTLRenderPassDescriptor *renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
  renderPass.colorAttachments[0].texture = destination;
  renderPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
  encoder.label = @"Maaso Avatar Portal Color Copy";
  [encoder setRenderPipelineState:self.portalCopyPipeline];
  [encoder setFragmentTexture:source atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:3];
  [encoder endEncoding];
  __weak MaasoAvatarPortalTextureBridge *weakSelf = self;
  dispatch_semaphore_t semaphore = self.inFlightFrames;
  __block CVPixelBufferRef completedPixelBuffer = pixelBuffer;
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _) {
    MaasoAvatarPortalTextureBridge *strongSelf = weakSelf;
    if (strongSelf != nil && [strongSelf generationMatches:generation]) {
      {
        std::lock_guard<std::mutex> lock(strongSelf->_frameMutex);
        if (strongSelf->_latestPixelBuffer != nil) {
          CVPixelBufferRelease(strongSelf->_latestPixelBuffer);
        }
        strongSelf->_latestPixelBuffer = completedPixelBuffer;
        completedPixelBuffer = nil;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        if (![strongSelf generationMatches:generation] ||
            strongSelf.textureId < 0) {
          return;
        }
        [strongSelf.textureRegistry textureFrameAvailable:strongSelf.textureId];
        if (strongSelf.firstFrameGeneration != generation) {
          strongSelf.firstFrameGeneration = generation;
          [strongSelf.channel invokeMethod:@"event"
                                 arguments:@{
                                   @"type" : @"firstFrame",
                                   @"generation" : @(generation),
                                   @"textureId" : @(strongSelf.textureId),
                                   @"width" : @(strongSelf.width),
                                   @"height" : @(strongSelf.height),
                                 }];
        }
      });
    }
    if (completedPixelBuffer != nil) CVPixelBufferRelease(completedPixelBuffer);
    dispatch_semaphore_signal(semaphore);
  }];
  CFRelease(cvTexture);
}

@end

static MaasoAvatarPortalTextureBridge *MaasoAvatarPortalBridgeInstance;
extern "C" void maaso_avatar_portal_register(void *registrar_pointer) {
  if (registrar_pointer == nullptr || MaasoAvatarPortalBridgeInstance != nil) {
    return;
  }
  id<FlutterPluginRegistrar> registrar =
      (__bridge id<FlutterPluginRegistrar>)registrar_pointer;
  MaasoAvatarPortalBridgeInstance =
      [[MaasoAvatarPortalTextureBridge alloc] initWithRegistrar:registrar];
}

extern "C" void MaasoAvatarPortalSubmitMetalTexture(
    void *texture,
    void *command_buffer,
    int width,
    int height,
    int generation) {
  [MaasoAvatarPortalBridgeInstance
      submitMetalTexture:texture
             commandBuffer:(__bridge id<MTLCommandBuffer>)command_buffer
                   width:width
                  height:height
      generation:generation];
}

extern "C" void MaasoAvatarPortalReportEventToFlutter(
    const char *type,
    int generation) {
  if (type == nullptr || generation <= 0) return;
  NSString *eventType = [NSString stringWithUTF8String:type];
  [MaasoAvatarPortalBridgeInstance reportEventType:eventType
                                        generation:generation];
}
