# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "plist"
require "tmpdir"
require "xcodeproj"
require_relative "prepare_embedded_llama_framework"

class MaasoEmbeddedLlamaFrameworkMetadataTest < Minitest::Test
  Prep = MaasoEmbeddedLlamaFrameworkMetadata
  ROOT = File.expand_path("../..", __dir__)
  Status = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  def setup
    @directory = File.realpath(Dir.mktmpdir("maaso-llama-test-"))
    @framework = File.join(@directory, "Runner.app/Frameworks/llama.framework")
    FileUtils.mkdir_p(@framework)
    @info = File.join(@framework, "Info.plist")
    @binary = File.join(@framework, "llama")
    File.binwrite(@binary, [0xfeedfacf, 0x0100000c, 0, 6, 0, 0, 0, 0].pack("V8"))
    write_info(Prep::EXPECTED_INFO)
    @environment = { "PLATFORM_NAME" => "iphoneos", "CODE_SIGNING_ALLOWED" => "YES",
                     "EXPANDED_CODE_SIGN_IDENTITY" => "approved-existing-identity",
                     "TARGET_BUILD_DIR" => @directory, "FRAMEWORKS_FOLDER_PATH" => "Runner.app/Frameworks" }
    @build = "Load command 10\n cmd LC_BUILD_VERSION\n platform IOS\n minos 16.4\n sdk 26.5\n"
    @uuid = Prep::BINARY_UUID
    @commands = []
    @sign_failure = false
    @runner = lambda do |*arguments|
      @commands << arguments
      if arguments.first == "/usr/bin/xcrun" && arguments[1] == "vtool"
        [@build, "", Status.new(0)]
      elsif arguments.first == "/usr/bin/xcrun" && arguments[1] == "dwarfdump"
        ["UUID: #{@uuid} (arm64) #{@binary}\n", "", Status.new(0)]
      elsif arguments.first == "/usr/bin/codesign"
        ["", "", Status.new(@sign_failure ? 1 : 0)]
      else
        Open3.capture3(*arguments)
      end
    end
  end

  def teardown
    FileUtils.remove_entry_secure(@directory) if File.exist?(@directory)
  end

  def test_missing_metadata_is_added_and_existing_identity_is_used_before_strict_verification
    result = prepare
    assert result.fetch(:metadataUpdated)
    assert result.fetch(:codesigned)
    assert_equal 1, result.fetch(:embeddedFrameworksChecked)
    assert_equal Prep::EXPECTED_INFO.merge("MinimumOSVersion" => "16.4.0"), read_info
    assert_equal ["/usr/bin/codesign", "--force", "--sign", "approved-existing-identity",
                  "--preserve-metadata=identifier,entitlements", @framework], signing_commands.first
    assert_equal ["/usr/bin/codesign", "--verify", "--strict", @framework], signing_commands.last
  end

  def test_matching_metadata_is_idempotent
    write_info(Prep::EXPECTED_INFO.merge("MinimumOSVersion" => "16.4"))
    original = File.binread(@info)
    refute prepare.fetch(:metadataUpdated)
    assert_equal original, File.binread(@info)
    assert_equal 2, signing_commands.length
  end

  def test_unsigned_build_repairs_metadata_without_inventing_a_signing_identity
    @environment["CODE_SIGNING_ALLOWED"] = "NO"
    @environment.delete("EXPANDED_CODE_SIGN_IDENTITY")
    result = prepare
    refute result.fetch(:codesigned)
    assert_equal "16.4.0", read_info.fetch("MinimumOSVersion")
    assert_empty signing_commands
  end

  def test_conflicting_or_invalid_existing_minimum_versions_are_rejected_without_writing
    ["15.0", "17.0", "", "16.4.0.0", false, ["16.4"]].each do |minimum|
      write_info(Prep::EXPECTED_INFO.merge("MinimumOSVersion" => minimum))
      reject_unchanged(/MinimumOSVersion conflicts/)
    end
  end

  def test_unknown_platform_minimum_uuid_and_binary_shape_are_rejected
    original_build = @build
    @build = original_build.sub("IOS", "IOSSIMULATOR")
    reject_unchanged(/Mach-O platform/)
    @build = original_build.sub("16.4", "17.0")
    reject_unchanged(/Mach-O platform/)
    @build = original_build
    @uuid = "00000000-0000-0000-0000-000000000000"
    reject_unchanged(/UUID is unreviewed/)
    @uuid = Prep::BINARY_UUID
    File.binwrite(@binary, "not a reviewed binary".ljust(32, "x"))
    reject_unchanged(/thin arm64/)
  end

  def test_unknown_vendor_version_or_bundle_identity_is_rejected
    ["CFBundleVersion", "CFBundleIdentifier"].each do |key|
      write_info(Prep::EXPECTED_INFO.merge(key => "unreviewed"))
      reject_unchanged(/version or bundle identity/)
    end
  end

  def test_missing_or_ad_hoc_identity_is_rejected_before_metadata_mutation
    ["", "-"].each do |identity|
      @environment["EXPANDED_CODE_SIGN_IDENTITY"] = identity
      reject_unchanged(/real existing Xcode signing identity/)
    end
  end

  def test_symlinked_metadata_is_rejected
    target = File.join(@directory, "original.plist")
    File.rename(@info, target)
    File.symlink(target, @info)
    error = assert_raises(Prep::Error) { prepare }
    assert_match(/symlinks/, error.message)
    assert_equal Prep::EXPECTED_INFO, Plist.parse_xml(target)
  end

  def test_signing_tool_failure_is_fatal
    @sign_failure = true
    error = assert_raises(Prep::Error) { prepare }
    assert_match(/tool failed: codesign/, error.message)
  end

  def test_another_framework_with_missing_metadata_is_rejected_and_never_repaired
    other = File.join(File.dirname(@framework), "Other.framework")
    FileUtils.mkdir_p(other)
    path = File.join(other, "Info.plist")
    File.binwrite(path, Plist::Emit.dump({ "CFBundleExecutable" => "Other" }))
    original = File.binread(path)
    error = assert_raises(Prep::Error) { prepare }
    assert_match(/Other.framework has no valid MinimumOSVersion/, error.message)
    assert_equal original, File.binread(path)
    assert_empty signing_commands
  end

  def test_simulator_does_not_repair_a_device_binary
    result = Prep.prepare!(environment: { "PLATFORM_NAME" => "iphonesimulator" }, runner: @runner)
    assert_equal({ skipped: "iOS simulator" }, result)
    assert_empty @commands
  end

  def test_phase_has_only_the_signature_or_unsigned_binary_input_and_is_last
    target = runner_target
    phase = target.build_phases.last
    assert_equal "Prepare Embedded Framework Metadata", phase.display_name
    assert_equal ["$(MAASO_LLAMA_SIGNING_INPUT)"], phase.input_paths
    assert_empty phase.output_paths
    assert_equal "1", phase.always_out_of_date
    target.build_configurations.each do |configuration|
      settings = configuration.build_settings
      assert_equal "$(MAASO_LLAMA_SIGNING_INPUT_$(CODE_SIGNING_ALLOWED))", settings.fetch("MAASO_LLAMA_SIGNING_INPUT")
      assert settings.fetch("MAASO_LLAMA_SIGNING_INPUT_YES").end_with?("/llama.framework/_CodeSignature")
      assert settings.fetch("MAASO_LLAMA_SIGNING_INPUT_NO").end_with?("/llama.framework/llama")
    end
  end

  def test_phase_runs_with_inherited_bundle_startup_for_pinned_and_system_ruby
    script = runner_target.build_phases.last.shell_script
    [RbConfig.ruby, nil].each do |interpreter|
      environment = ENV.to_h.merge("SRCROOT" => File.join(ROOT, "ios"), "PLATFORM_NAME" => "iphonesimulator",
                                  "MAASO_RELEASE_RUBY_EXECUTABLE" => interpreter)
      assert_includes environment.fetch("RUBYOPT"), "bundler/setup"
      output, error, status = Open3.capture3(environment, "/bin/sh", "-c", script)
      assert status.success?, error
      assert_includes output, '"skipped":"iOS simulator"'
      assert_includes output, '"rubyVersion":'
    end
  end

  private

  def runner_target
    Xcodeproj::Project.open(File.join(ROOT, "ios/Runner.xcodeproj")).targets.find { |target| target.name == "Runner" }
  end

  def prepare
    Prep.prepare!(environment: @environment, runner: @runner)
  end

  def write_info(value)
    File.binwrite(@info, Plist::Emit.dump(value))
  end

  def read_info
    Plist.parse_xml(@info)
  end

  def signing_commands
    @commands.select { |arguments| arguments.first == "/usr/bin/codesign" }
  end

  def reject_unchanged(message)
    original = File.binread(@info)
    error = assert_raises(Prep::Error) { prepare }
    assert_match message, error.message
    assert_equal original, File.binread(@info)
    assert_empty signing_commands
  end
end
