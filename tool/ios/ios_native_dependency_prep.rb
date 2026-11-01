# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "tmpdir"

# Creates a build-ephemeral, repository-controlled podspec overlay for the
# VolcEngine RTC Flutter plugin. The pub cache remains read-only and untouched.
module MaasoIosNativeDependencyPrep
  class Error < StandardError; end

  PLUGIN_NAME = "volc_engine_rtc"
  PLUGIN_VERSION = "3.60.6"
  PLUGINS_CONFIG_RELATIVE_PATH = ".flutter-plugins-dependencies"
  PLUGIN_LINK_RELATIVE_PATH = "ios/.symlinks/plugins/#{PLUGIN_NAME}"
  OVERLAY_PARENT_RELATIVE_PATH = "ios/Flutter/ephemeral/MaasoPodOverrides"
  OVERLAY_RELATIVE_PATH = "#{OVERLAY_PARENT_RELATIVE_PATH}/#{PLUGIN_NAME}"
  OVERRIDE_PODSPEC_RELATIVE_PATH =
    "tool/ios/podspec_overrides/#{PLUGIN_NAME}.podspec"

  REQUIRED_PLUGIN_FILES = [
    "pubspec.yaml",
    "ios/Classes/ByteRTCHelper.h",
    "ios/Classes/ByteRTCHelper.m",
    "ios/Classes/ByteRTCPlugin.h",
    "ios/Classes/ByteRTCPlugin.m",
    "ios/volc_engine_rtc.modulemap",
    "ios/volc_engine_rtc.podspec",
  ].freeze

  OVERLAY_COPIES = {
    "ios/Classes" => "ios/Classes",
    "ios/Resources" => "ios/Resources",
    "ios/volc_engine_rtc.modulemap" => "ios/volc_engine_rtc.modulemap",
  }.freeze

  module_function

  def prepare!(repo_root:)
    root = canonical_directory!(repo_root, "repository root")
    plugin_root = configured_plugin_root!(root)
    validate_plugin!(plugin_root)
    validate_flutter_plugin_link!(root, plugin_root)

    overlay_parent = File.join(root, OVERLAY_PARENT_RELATIVE_PATH)
    FileUtils.mkdir_p(overlay_parent, mode: 0o755)
    overlay = File.join(root, OVERLAY_RELATIVE_PATH)
    temporary = Dir.mktmpdir(".maaso-volc-override-", overlay_parent)
    begin
      build_overlay!(
        root: root,
        plugin_root: plugin_root,
        temporary: temporary,
      )
      replace_overlay!(overlay: overlay, temporary: temporary)
      temporary = nil
      replace_plugin_link!(root: root, overlay: overlay)
      verify_overlay!(root: root, plugin_root: plugin_root, overlay: overlay)
    ensure
      FileUtils.remove_entry_secure(temporary) if temporary && File.exist?(temporary)
    end
    overlay
  rescue JSON::ParserError, KeyError => error
    raise Error, "invalid Flutter plugin configuration: #{error.message}"
  rescue SystemCallError => error
    raise Error, "unable to prepare the iOS RTC podspec override: #{error.message}"
  end

  def configured_plugin_root!(root)
    config_path = File.join(root, PLUGINS_CONFIG_RELATIVE_PATH)
    config_stat = File.lstat(config_path)
    unless config_stat.file? && !config_stat.symlink? && config_stat.size.between?(1, 4 * 1024 * 1024)
      raise Error, "Flutter plugin configuration must be a bounded regular file"
    end
    config = JSON.parse(File.binread(config_path))
    plugins = config.fetch("plugins").fetch("ios")
    matches = plugins.select do |entry|
      entry.is_a?(Hash) && entry["name"] == PLUGIN_NAME
    end
    unless matches.length == 1 && matches.first["native_build"] == true
      raise Error, "Flutter plugin configuration must contain one native #{PLUGIN_NAME} plugin"
    end
    canonical_directory!(matches.first.fetch("path"), "#{PLUGIN_NAME} package root")
  rescue Errno::ENOENT
    raise Error, "required Flutter plugin configuration is missing"
  end

  def validate_plugin!(plugin_root)
    pubspec = File.binread(File.join(plugin_root, "pubspec.yaml"))
    unless pubspec.match?(/^name: #{Regexp.escape(PLUGIN_NAME)}$/) &&
           pubspec.match?(/^version: #{Regexp.escape(PLUGIN_VERSION)}$/)
      raise Error, "#{PLUGIN_NAME} must remain pinned to #{PLUGIN_VERSION}"
    end

    REQUIRED_PLUGIN_FILES.each do |relative|
      path = File.join(plugin_root, relative)
      stat = File.lstat(path)
      raise Error, "#{PLUGIN_NAME} input #{relative} must be a regular file" unless stat.file?
    end

    upstream_podspec = File.binread(
      File.join(plugin_root, "ios/volc_engine_rtc.podspec"),
    )
    unless upstream_podspec.include?("s.dependency rtc_sdk_name, rtc_default_version") &&
           upstream_podspec.include?("rtc_default_version = is_bp ? '3.60.105.3100' : '3.60.105.2300'")
      raise Error, "#{PLUGIN_NAME} upstream podspec has an unreviewed dependency shape"
    end
    true
  rescue Errno::ENOENT
    raise Error, "required #{PLUGIN_NAME} package input is missing"
  end

  def validate_flutter_plugin_link!(root, plugin_root)
    link = File.join(root, PLUGIN_LINK_RELATIVE_PATH)
    expected_overlay = File.join(root, OVERLAY_RELATIVE_PATH)
    valid_targets = [plugin_root]
    if File.exist?(expected_overlay) &&
       File.lstat(expected_overlay).directory? &&
       !File.symlink?(expected_overlay)
      valid_targets << File.realpath(expected_overlay)
    end
    unless File.symlink?(link) && valid_targets.include?(File.realpath(link))
      raise Error, "Flutter's #{PLUGIN_NAME} plugin link does not match package configuration"
    end
    true
  rescue Errno::ENOENT
    raise Error, "Flutter's #{PLUGIN_NAME} plugin link is missing"
  end

  def build_overlay!(root:, plugin_root:, temporary:)
    ios = File.join(temporary, "ios")
    FileUtils.mkdir_p(ios, mode: 0o755)
    OVERLAY_COPIES.each do |destination_relative, source_relative|
      destination = File.join(temporary, destination_relative)
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o755)
      FileUtils.cp_r(File.join(plugin_root, source_relative), destination)
    end
    FileUtils.copy_file(
      File.join(root, OVERRIDE_PODSPEC_RELATIVE_PATH),
      File.join(ios, "volc_engine_rtc.podspec"),
    )
    true
  end

  def replace_overlay!(overlay:, temporary:)
    if File.exist?(overlay) || File.symlink?(overlay)
      stat = File.lstat(overlay)
      unless stat.directory? && !stat.symlink?
        raise Error, "existing RTC podspec override is not a safe directory"
      end
      FileUtils.remove_entry_secure(overlay)
    end
    File.rename(temporary, overlay)
    true
  end

  def replace_plugin_link!(root:, overlay:)
    link = File.join(root, PLUGIN_LINK_RELATIVE_PATH)
    raise Error, "Flutter's RTC plugin link changed during preparation" unless File.symlink?(link)

    File.unlink(link)
    File.symlink(overlay, link)
    true
  end

  def verify_overlay!(root:, plugin_root:, overlay:)
    link = File.join(root, PLUGIN_LINK_RELATIVE_PATH)
    unless File.symlink?(link) && File.realpath(link) == overlay
      raise Error, "prepared RTC plugin link did not persist"
    end
    OVERLAY_COPIES.each do |destination_relative, source_relative|
      destination = File.join(overlay, destination_relative)
      source = File.join(plugin_root, source_relative)
      unless !File.symlink?(destination) && overlay_input_matches?(source, destination)
        raise Error, "prepared RTC input #{destination_relative} is invalid"
      end
    end
    podspec = File.binread(File.join(overlay, "ios/volc_engine_rtc.podspec"))
    unless podspec.include?('spec.dependency "VolcEngineRTC/Core", "3.60.105.2300"') &&
           podspec.include?('spec.dependency "VolcEngineRTC/RealXBase", "3.60.105.2300"') &&
           podspec.include?('spec.dependency "VolcEngineRTC/RTCFFmpeg", "3.60.105.2300"') &&
           !podspec.include?("ByteRTCVideoDenoiseExtension") &&
           !podspec.include?("ByteRTCVideoSharpenExtension") &&
           !podspec.include?("ByteRTCVideoSRExtension")
      raise Error, "prepared RTC podspec does not contain the reviewed dependency set"
    end
    true
  end

  def overlay_input_matches?(source, destination)
    if File.directory?(source)
      source_files = Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH)
                        .select { |path| File.file?(path) }
                        .map { |path| path.delete_prefix("#{source}/") }
      destination_files = Dir.glob(
        File.join(destination, "**", "*"),
        File::FNM_DOTMATCH,
      ).select { |path| File.file?(path) }
       .map { |path| path.delete_prefix("#{destination}/") }
      return false unless source_files == destination_files

      source_files.all? do |relative|
        File.binread(File.join(source, relative)) ==
          File.binread(File.join(destination, relative))
      end
    else
      File.file?(destination) && File.binread(source) == File.binread(destination)
    end
  end

  def canonical_directory!(path, label)
    unless path.is_a?(String) && !path.empty? && Pathname.new(path).absolute? &&
           path.valid_encoding? && !path.include?("\0")
      raise Error, "#{label} path must be absolute"
    end
    expanded = File.expand_path(path)
    real = File.realpath(expanded)
    raise Error, "#{label} path must be canonical" unless expanded == real
    raise Error, "#{label} must be a directory" unless File.lstat(real).directory?

    real
  rescue SystemCallError => error
    raise Error, "unable to resolve #{label}: #{error.message}"
  end
end
