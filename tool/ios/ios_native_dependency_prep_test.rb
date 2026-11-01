# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "ios_native_dependency_prep"

class MaasoIosNativeDependencyPrepTest < Minitest::Test
  def setup
    @temporary = File.realpath(Dir.mktmpdir("maaso-ios-native-deps-"))
    @repo = File.join(@temporary, "repo")
    @plugin = File.join(@temporary, "pub-cache", "volc_engine_rtc-3.60.6")
    FileUtils.mkdir_p(@repo)
    FileUtils.mkdir_p(@plugin)
    write_plugin
    write_repo(
      MaasoIosNativeDependencyPrep::OVERRIDE_PODSPEC_RELATIVE_PATH,
      File.binread(
        File.expand_path("podspec_overrides/volc_engine_rtc.podspec", __dir__),
      ),
    )
    write_repo(
      MaasoIosNativeDependencyPrep::PLUGINS_CONFIG_RELATIVE_PATH,
      JSON.generate(
        "plugins" => {
          "ios" => [
            {
              "name" => "volc_engine_rtc",
              "path" => @plugin,
              "native_build" => true,
            },
          ],
        },
      ) + "\n",
    )
    link = repo_path(MaasoIosNativeDependencyPrep::PLUGIN_LINK_RELATIVE_PATH)
    FileUtils.mkdir_p(File.dirname(link))
    File.symlink(@plugin, link)
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.exist?(@temporary)
  end

  def test_replaces_only_the_generated_plugin_link_with_reviewed_subspecs
    overlay = MaasoIosNativeDependencyPrep.prepare!(repo_root: @repo)
    link = repo_path(MaasoIosNativeDependencyPrep::PLUGIN_LINK_RELATIVE_PATH)

    assert_equal overlay, File.realpath(link)
    refute File.symlink?(File.join(link, "ios/Classes"))
    assert_equal File.binread(File.join(@plugin, "ios/Classes/ByteRTCPlugin.m")),
                 File.binread(File.join(link, "ios/Classes/ByteRTCPlugin.m"))
    podspec = File.binread(File.join(link, "ios/volc_engine_rtc.podspec"))
    assert_includes podspec, 'spec.dependency "VolcEngineRTC/Core", "3.60.105.2300"'
    assert_includes podspec, 'spec.dependency "VolcEngineRTC/RealXBase", "3.60.105.2300"'
    assert_includes podspec, 'spec.dependency "VolcEngineRTC/RTCFFmpeg", "3.60.105.2300"'
    refute_includes podspec, "ByteRTCVideoDenoiseExtension"
    refute_includes podspec, "ByteRTCVideoSharpenExtension"
    refute_includes podspec, "ByteRTCVideoSRExtension"
    assert_includes File.binread(File.join(@plugin, "ios/volc_engine_rtc.podspec")),
                    "s.dependency rtc_sdk_name, rtc_default_version"

    assert_equal overlay, MaasoIosNativeDependencyPrep.prepare!(repo_root: @repo)
    assert_equal overlay, File.realpath(link)
  end

  def test_fails_closed_on_plugin_version_drift_without_replacing_link
    File.binwrite(File.join(@plugin, "pubspec.yaml"), "name: volc_engine_rtc\nversion: 3.61.0\n")
    link = repo_path(MaasoIosNativeDependencyPrep::PLUGIN_LINK_RELATIVE_PATH)

    error = assert_raises(MaasoIosNativeDependencyPrep::Error) do
      MaasoIosNativeDependencyPrep.prepare!(repo_root: @repo)
    end

    assert_match(/pinned to 3\.60\.6/, error.message)
    assert_equal @plugin, File.realpath(link)
  end

  def test_fails_closed_when_flutter_link_does_not_match_configuration
    other = File.join(@temporary, "other-plugin")
    FileUtils.mkdir_p(other)
    link = repo_path(MaasoIosNativeDependencyPrep::PLUGIN_LINK_RELATIVE_PATH)
    File.unlink(link)
    File.symlink(other, link)

    error = assert_raises(MaasoIosNativeDependencyPrep::Error) do
      MaasoIosNativeDependencyPrep.prepare!(repo_root: @repo)
    end

    assert_match(/does not match package configuration/, error.message)
    assert_equal other, File.realpath(link)
  end

  private

  def write_plugin
    File.binwrite(
      File.join(@plugin, "pubspec.yaml"),
      "name: volc_engine_rtc\nversion: 3.60.6\n",
    )
    required = MaasoIosNativeDependencyPrep::REQUIRED_PLUGIN_FILES - ["pubspec.yaml"]
    required.each do |relative|
      path = File.join(@plugin, relative)
      FileUtils.mkdir_p(File.dirname(path))
      contents = if relative.end_with?("volc_engine_rtc.podspec")
                   "rtc_default_version = is_bp ? '3.60.105.3100' : '3.60.105.2300'\n" \
                     "s.dependency rtc_sdk_name, rtc_default_version\n"
                 else
                   "fixture\n"
                 end
      File.binwrite(path, contents)
    end
    FileUtils.mkdir_p(File.join(@plugin, "ios/Resources"))
    File.binwrite(File.join(@plugin, "ios/Resources/PrivacyInfo.xcprivacy"), "fixture\n")
  end

  def write_repo(relative, contents)
    path = repo_path(relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
  end

  def repo_path(relative)
    File.join(@repo, relative)
  end
end
