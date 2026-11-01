# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

# Repairs only the reviewed llama binary's missing metadata in Runner's build
# product. The downloaded vendor XCFramework and pub cache remain untouched.
module MaasoEmbeddedLlamaFrameworkMetadata
  class Error < StandardError; end

  MINIMUM_OS_VERSION = "16.4.0"
  BINARY_UUID = "674244A6-1393-3134-8A94-D417FEB45432"
  EXPECTED_INFO = {
    "CFBundleExecutable" => "llama",
    "CFBundleIdentifier" => "dev.leehack.llamadart.native.llama",
    "CFBundleName" => "llama",
    "CFBundlePackageType" => "FMWK",
    "CFBundleShortVersionString" => "1.0",
    "CFBundleVersion" => "1",
  }.freeze

  module_function

  def prepare!(environment: ENV, runner: method(:capture_command))
    platform = environment.fetch("PLATFORM_NAME", "")
    return { skipped: "iOS simulator" } if platform == "iphonesimulator"
    raise Error, "framework metadata preparation requires the iPhoneOS platform" unless platform == "iphoneos"

    signing = environment.fetch("CODE_SIGNING_ALLOWED", "")
    raise Error, "CODE_SIGNING_ALLOWED must be YES or NO" unless %w[YES NO].include?(signing)
    identity = environment.fetch("EXPANDED_CODE_SIGN_IDENTITY", "")
    if signing == "YES" && (identity.empty? || identity == "-")
      raise Error, "a real existing Xcode signing identity is required"
    end

    root = environment.fetch("TARGET_BUILD_DIR", "")
    unless Pathname.new(root).absolute? && File.directory?(root)
      raise Error, "TARGET_BUILD_DIR must be an existing absolute build directory"
    end
    root = File.realpath(root)
    unless environment["FRAMEWORKS_FOLDER_PATH"] == "Runner.app/Frameworks"
      raise Error, "unexpected Runner frameworks directory"
    end
    framework = safe_child!(root, "Runner.app/Frameworks/llama.framework", directory: true)
    info_path = safe_child!(framework, "Info.plist", directory: false)
    binary = safe_child!(framework, "llama", directory: false)
    raise Error, "llama Info.plist is unexpectedly large" unless File.size(info_path).between?(1, 128 * 1024)
    raise Error, "llama binary is unexpectedly large" unless File.size(binary).between?(32, 64 * 1024 * 1024)

    info = read_info!(info_path, runner)
    unless EXPECTED_INFO.all? { |key, value| info[key] == value }
      raise Error, "llama framework version or bundle identity is unreviewed"
    end
    verify_binary!(binary, runner)
    if info.key?("MinimumOSVersion") && version(info["MinimumOSVersion"]) != MINIMUM_OS_VERSION
      raise Error, "llama MinimumOSVersion conflicts with the reviewed binary"
    end

    changed = !info.key?("MinimumOSVersion")
    if changed
      command!(runner, "/usr/bin/plutil", "-insert", "MinimumOSVersion", "-string", MINIMUM_OS_VERSION, info_path)
      unless read_info!(info_path, runner) == info.merge("MinimumOSVersion" => MINIMUM_OS_VERSION)
        raise Error, "llama metadata update changed unexpected values"
      end
    end
    framework_count = verify_embedded_minimum_versions!(File.dirname(framework), runner)

    if signing == "YES"
      command!(runner, "/usr/bin/codesign", "--force", "--sign", identity,
               "--preserve-metadata=identifier,entitlements", framework)
      command!(runner, "/usr/bin/codesign", "--verify", "--strict", framework)
      verify_binary!(binary, runner)
    end
    { metadataUpdated: changed, minimumOSVersion: MINIMUM_OS_VERSION,
      binaryUUID: BINARY_UUID, codesigned: signing == "YES",
      embeddedFrameworksChecked: framework_count }
  rescue SystemCallError, JSON::ParserError => error
    raise Error, "unable to prepare embedded llama metadata: #{error.class}"
  end

  def safe_child!(root, relative, directory:)
    current = root
    relative.split("/").each do |component|
      current = File.join(current, component)
      raise Error, "embedded framework paths must not contain symlinks" if File.symlink?(current)
    end
    valid = directory ? File.directory?(current) : File.file?(current)
    raise Error, "required embedded framework input is unavailable" unless valid
    current
  end

  def read_info!(path, runner)
    output = command!(runner, "/usr/bin/plutil", "-convert", "json", "-o", "-", path)
    value = JSON.parse(output)
    raise Error, "framework Info.plist must be a dictionary" unless value.is_a?(Hash)
    value
  end

  def version(value)
    return nil unless value.is_a?(String) && value.match?(/\A[0-9]+(?:\.[0-9]+){0,2}\z/)
    (value.split(".").map(&:to_i) + [0, 0]).first(3).join(".")
  end

  def verify_binary!(binary, runner)
    header = File.binread(binary, 32).unpack("V8")
    unless header[0] == 0xfeedfacf && header[1] == 0x0100000c && header[2] == 0 && header[3] == 6
      raise Error, "llama must remain the reviewed thin arm64 Mach-O dynamic library"
    end
    build = command!(runner, "/usr/bin/xcrun", "vtool", "-show-build", binary)
    platforms = build.scan(/^\s*platform\s+(\S+)\s*$/).flatten
    minimums = build.scan(/^\s*minos\s+(\S+)\s*$/).flatten
    unless build.scan(/^\s*cmd LC_BUILD_VERSION\s*$/).length == 1 &&
           platforms == ["IOS"] && minimums.length == 1 && version(minimums.first) == MINIMUM_OS_VERSION
      raise Error, "llama Mach-O platform or minimum iOS version is unreviewed"
    end
    uuids = command!(runner, "/usr/bin/xcrun", "dwarfdump", "--uuid", binary)
      .scan(/^UUID: ([0-9A-Fa-f-]+) \(arm64\)/).flatten.map(&:upcase)
    raise Error, "llama Mach-O UUID is unreviewed" unless uuids == [BINARY_UUID]
    true
  end

  def verify_embedded_minimum_versions!(frameworks, runner)
    paths = Dir.glob(File.join(frameworks, "*.framework")).sort
    paths.each do |path|
      raise Error, "embedded framework must not be a symlink" if File.symlink?(path)
      info = safe_child!(path, "Info.plist", directory: false)
      value = read_info!(info, runner)["MinimumOSVersion"]
      normalized = version(value)
      unless normalized && normalized.split(".").map(&:to_i).first >= 8
        raise Error, "embedded framework #{File.basename(path)} has no valid MinimumOSVersion"
      end
    end
    paths.length
  end

  def command!(runner, *arguments)
    output, _error, status = runner.call(*arguments)
    raise Error, "framework metadata tool failed: #{File.basename(arguments.first)}" unless status.success?
    output
  end

  def capture_command(*arguments)
    Open3.capture3(*arguments)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    result = MaasoEmbeddedLlamaFrameworkMetadata.prepare!
    puts "Maaso embedded framework metadata: #{JSON.generate(result.merge(rubyVersion: RUBY_VERSION))}"
  rescue MaasoEmbeddedLlamaFrameworkMetadata::Error => error
    warn "error: #{error.message}"
    exit 1
  end
end
