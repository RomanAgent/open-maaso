Pod::Spec.new do |spec|
  spec.name = "volc_engine_rtc"
  spec.version = "3.60.6"
  spec.summary = "Maaso's reviewed VolcEngine RTC Flutter bridge."
  spec.description = <<-DESC
    The upstream Flutter bridge with the reviewed VolcEngineRTC subspec set.
    Maaso does not ship the optional video denoise, sharpen, or super-resolution
    extensions because version 3.60.105.2300 duplicates Objective-C classes
    already present in VolcEngineRTC.framework.
  DESC
  spec.homepage = "https://www.volcengine.com/product/veRTC"
  spec.license = { :type => "MIT" }
  spec.author = { "bytertc" => "bytertc@bytedance.com" }
  spec.source = { :path => "." }
  spec.source_files = "Classes/**/*"
  spec.public_header_files = "Classes/**/*.h"
  spec.module_map = "volc_engine_rtc.modulemap"
  spec.ios.deployment_target = "16.4"

  spec.dependency "Flutter"
  spec.dependency "VolcApiEngine", "1.7.0"
  # VolcEngine's iOS integration matrix marks these three subspecs as required
  # and the denoise/sharpen/SR/BMF extensions as optional:
  # https://www.volcengine.com/docs/6369/1108726
  spec.dependency "VolcEngineRTC/Core", "3.60.105.2300"
  spec.dependency "VolcEngineRTC/RealXBase", "3.60.105.2300"
  spec.dependency "VolcEngineRTC/RTCFFmpeg", "3.60.105.2300"

  spec.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "arm64",
    "EXCLUDED_ARCHS[sdk=iphoneos*]" => "x86_64",
    "ENABLE_BITCODE" => "NO",
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) IS_BYTEPLUS=0",
  }
end
