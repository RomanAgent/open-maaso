# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "xcodeproj"

class MaasoAlternateIconAssetsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_each_runner_configuration_compiles_the_declared_alternate_icon
    info = Xcodeproj::Plist.read_from_path(File.join(ROOT, "ios/Runner/Info.plist"))
    names = info.fetch("CFBundleIcons").fetch("CFBundleAlternateIcons").keys
    assert_equal ["AppIconLight"], names
    assert_equal names, info.fetch("CFBundleIcons~ipad").fetch("CFBundleAlternateIcons").keys
    runner = Xcodeproj::Project.open(File.join(ROOT, "ios/Runner.xcodeproj")).targets.find { |target| target.name == "Runner" }
    runner.build_configurations.each do |configuration|
      assert_equal "AppIcon", configuration.build_settings.fetch("ASSETCATALOG_COMPILER_APPICON_NAME")
      assert_equal names, Array(configuration.build_settings["ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES"])
    end
  end

  def test_alternate_catalog_does_not_keep_an_invalid_loose_png_reference
    info = Xcodeproj::Plist.read_from_path(File.join(ROOT, "ios/Runner/Info.plist"))
    ["CFBundleIcons", "CFBundleIcons~ipad"].each do |key|
      alternate = info.fetch(key).fetch("CFBundleAlternateIcons").fetch("AppIconLight")
      refute alternate.key?("CFBundleIconFiles"), "actool supplies the catalog CFBundleIconName; AppIconLight is not a loose PNG"
    end
  end

  def test_alternate_source_contains_the_required_iphone_ipad_and_store_pixels
    folder = File.join(ROOT, "ios/Runner/Assets.xcassets/AppIconLight.appiconset")
    images = JSON.parse(File.read(File.join(folder, "Contents.json"))).fetch("images")
    [["iphone", "60x60", "2x", 120], ["iphone", "60x60", "3x", 180],
     ["ipad", "76x76", "2x", 152], ["ipad", "83.5x83.5", "2x", 167],
     ["ios-marketing", "1024x1024", "1x", 1024]].each do |idiom, size, scale, pixels|
      image = images.find { |entry| entry["idiom"] == idiom && entry["size"] == size && entry["scale"] == scale }
      refute_nil image, "missing #{idiom} #{size} #{scale}"
      bytes = File.binread(File.join(folder, image.fetch("filename")), 24)
      assert_equal "\x89PNG\r\n\x1a\n".b, bytes.byteslice(0, 8)
      assert_equal "IHDR", bytes.byteslice(12, 4)
      assert_equal [pixels, pixels], bytes.byteslice(16, 8).unpack("N2")
    end
  end
end
