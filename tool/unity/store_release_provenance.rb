# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tempfile"

# Produces and verifies the reviewed Unity inputs consumed by store builds.
#
# The Unity exports themselves are intentionally ignored by Git. The checked-in
# manifest binds them to the current tracked Unity project/export tooling and to
# a deterministic digest of each platform's consumed export tree.
module MaasoUnityExportProvenance
  class Error < StandardError; end

  SCHEMA_VERSION = 1
  CANONICALIZATION = "maaso-unity-export-provenance-v1"
  MANIFEST_RELATIVE_PATH = "release/unity-export-provenance.json"
  SOURCE_ROOTS = [
    "tool/unity",
    "unity/masso_avatar",
  ].freeze
  IOS_ROOTS = [
    "unity/masso_avatar/Builds/iOS",
  ].freeze
  ANDROID_ROOTS = [
    "unity/masso_avatar/Builds/Android/gradle.properties",
    "unity/masso_avatar/Builds/Android/shared",
    "unity/masso_avatar/Builds/Android/unityLibrary",
  ].freeze
  # --profiler-report rewrites these diagnostics during the native Xcode build.
  # Match only the two output files; source, metadata and other JSON stay hashed.
  IOS_PROFILER_OUTPUT_PATHS = [
    "Il2CppOutputProject/Source/il2cppOutput/profile.json",
    "Il2CppOutputProject/Source/il2cppOutput/il2cpp-compile.traceevents",
  ].freeze
  IOS_EXCLUSION_RULES = [
    "**/xcuserdata/**",
    "Il2CppTempDirArtifacts/**",
    "*_BurstDebugInformation_DoNotShip/**",
    *IOS_PROFILER_OUTPUT_PATHS,
  ].freeze
  ANDROID_EXCLUSION_RULES = [
    "unityLibrary/.cxx/**",
    "unityLibrary/build/**",
    "unityLibrary/symbols/**",
    "unityLibrary/src/main/jniLibs/*/libil2cpp*.so",
  ].freeze
  ANDROID_GENERATED_DIRECTORY_PATHS = [
    "unity/masso_avatar/Builds/Android/unityLibrary/.cxx",
    "unity/masso_avatar/Builds/Android/unityLibrary/build",
    "unity/masso_avatar/Builds/Android/unityLibrary/symbols",
  ].freeze
  ANDROID_JNI_LIBS_RELATIVE_PATH =
    "unity/masso_avatar/Builds/Android/unityLibrary/src/main/jniLibs"
  ANDROID_GENERATED_LIBIL2CPP = /\Alibil2cpp[^\/]*\.so\z/
  FORBIDDEN_GIT_REPOSITORY_ENV = %w[
    GIT_DIR
    GIT_WORK_TREE
    GIT_INDEX_FILE
    GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_COMMON_DIR
    GIT_NAMESPACE
  ].freeze
  EMPTY_SHA256 = Digest::SHA256.hexdigest("").freeze
  MAX_MANIFEST_BYTES = 64 * 1024

  module_function

  def verify!(repo_root:, platform:)
    platform_name = normalize_platform!(platform)
    root = canonical_repo_root!(repo_root)
    manifest = read_committed_manifest!(root)
    validate_manifest_shape!(manifest)

    current_source = tracked_source_summary(root)
    unless manifest.fetch("source") == current_source
      raise Error,
            "tracked Unity source or export tooling differs from the committed provenance manifest"
    end

    current_export = export_summary(root, platform_name)
    unless manifest.fetch("exports").fetch(platform_name) == current_export
      raise Error,
            "#{platform_name} Unity export differs from the committed provenance manifest"
    end

    true
  end

  def build_manifest(repo_root:)
    root = canonical_repo_root!(repo_root)
    {
      "schema_version" => SCHEMA_VERSION,
      "canonicalization" => CANONICALIZATION,
      "source" => tracked_source_summary(root),
      "exports" => {
        "android" => export_summary(root, "android"),
        "ios" => export_summary(root, "ios"),
      },
    }
  end

  # Verifies the reviewed Android inputs, then removes only the generated
  # outputs excluded from the digest. This forces Gradle to rebuild libil2cpp
  # from the hashed Il2CppOutputProject instead of reusing stale output bytes.
  def verify_and_clean_android_generated_outputs!(repo_root:)
    verify!(repo_root: repo_root, platform: :android)
    clean_android_generated_outputs!(repo_root: repo_root)
  end

  # Call only after verify!(platform: :android). Fastlane intentionally keeps
  # those as adjacent explicit gates so the build sequence is auditable.
  def clean_android_generated_outputs!(repo_root:)
    root = canonical_repo_root!(repo_root)

    ANDROID_GENERATED_DIRECTORY_PATHS.each do |relative|
      inspected = inspect_generated_path_if_present!(root, relative)
      next if inspected.nil?

      stat = inspected.fetch(:chain).last.fetch(:stat)
      raise Error, "generated Unity output is not a directory: #{relative}" unless stat.directory?

      with_verified_generated_parent_directory!(
        root: root,
        inspected: inspected,
        relative: relative,
      ) do |basename|
        confirmed = File.lstat(basename)
        unless !confirmed.symlink? && confirmed.directory? &&
               same_file_identity?(stat, confirmed)
          raise Error, "generated Unity output changed before cleanup: #{relative}"
        end

        FileUtils.remove_entry_secure(basename)
        assert_generated_entry_missing!(basename, relative)
      end

      unless inspect_generated_path_if_present!(root, relative).nil?
        raise Error, "generated Unity output still exists after cleanup: #{relative}"
      end
    end

    remove_generated_libil2cpp_files!(root)
    true
  rescue SystemCallError => error
    raise Error, "unable to clean generated Android Unity output: #{error.message}"
  end

  def write_manifest!(repo_root:)
    root = canonical_repo_root!(repo_root)
    destination = File.join(root, MANIFEST_RELATIVE_PATH)
    parent = File.dirname(destination)
    assert_no_symlink_components!(root, File.dirname(MANIFEST_RELATIVE_PATH), allow_missing_leaf: true)
    Dir.mkdir(parent) unless Dir.exist?(parent)
    raise Error, "manifest parent is not a directory" unless File.directory?(parent)
    if File.exist?(destination) || File.symlink?(destination)
      destination_stat = File.lstat(destination)
      raise Error, "Unity export provenance manifest must not be a symlink" if destination_stat.symlink?
      unless destination_stat.file?
        raise Error, "Unity export provenance manifest must be a regular file"
      end
    end

    bytes = JSON.pretty_generate(build_manifest(repo_root: root)) << "\n"
    Tempfile.create(["unity-export-provenance-", ".json"], parent) do |temporary|
      temporary.binmode
      temporary.write(bytes)
      temporary.flush
      temporary.fsync
      File.chmod(0o644, temporary.path)
      File.rename(temporary.path, destination)
    end
    destination
  rescue SystemCallError => error
    raise Error, "unable to write Unity export provenance manifest: #{error.message}"
  end

  def tracked_source_summary(root)
    stdout, stderr, status = git_capture(
      root,
      "ls-files",
      "-z",
      "--",
      *SOURCE_ROOTS,
    )
    unless status.success?
      raise Error, "unable to enumerate tracked Unity source: #{stderr.lines.first&.strip}"
    end

    paths = stdout.split("\0", -1)
    paths.pop if paths.last == ""
    raise Error, "no tracked Unity source files were found" if paths.empty?
    raise Error, "Git returned duplicate tracked Unity source paths" unless paths.uniq.length == paths.length

    entries = paths.map do |relative|
      validate_relative_path!(relative)
      unless SOURCE_ROOTS.any? { |source_root| relative == source_root || relative.start_with?("#{source_root}/") }
        raise Error, "tracked Unity source escaped the configured roots: #{relative.inspect}"
      end
      snapshot_path!(root, relative, expected: :file)
    end
    summarize(entries, roots: SOURCE_ROOTS, excluded: [])
  end

  def export_summary(root, platform_name)
    case platform_name
    when "ios"
      entries = snapshot_roots!(root, IOS_ROOTS) do |relative, stat|
        ios_exclusion(relative, stat)
      end
      summarize(entries, roots: IOS_ROOTS, excluded: IOS_EXCLUSION_RULES)
    when "android"
      entries = snapshot_roots!(root, ANDROID_ROOTS) do |relative, stat|
        android_exclusion(relative, stat)
      end
      summarize(entries, roots: ANDROID_ROOTS, excluded: ANDROID_EXCLUSION_RULES)
    else
      raise Error, "unsupported Unity export platform: #{platform_name.inspect}"
    end
  end

  def snapshot_roots!(root, relative_roots, &exclusion)
    entries = []
    relative_roots.each do |relative_root|
      validate_relative_path!(relative_root)
      assert_no_symlink_components!(root, relative_root)
      absolute_root = File.join(root, relative_root)
      stat = safe_lstat!(absolute_root, relative_root)
      if stat.directory?
        entries.concat(snapshot_directory!(root, relative_root, &exclusion))
      elsif stat.file?
        entries << snapshot_regular_file!(root, relative_root, stat)
      else
        raise Error, "consumed Unity input has unsupported type: #{relative_root}"
      end
    end
    entries
  end

  def snapshot_directory!(root, relative_directory, &exclusion)
    absolute_directory = File.join(root, relative_directory)
    stat = safe_lstat!(absolute_directory, relative_directory)
    reject_symlink_or_special!(relative_directory, stat, allow_directory: true)

    exclusion_kind = exclusion&.call(relative_directory, stat)
    return [] if exclusion_kind == :directory
    raise Error, "file-only exclusion matched a directory: #{relative_directory}" if exclusion_kind == :file

    initial_children = sorted_children!(absolute_directory, relative_directory)
    entries = [directory_entry(relative_directory)]
    initial_children.each do |name|
      validate_child_name!(name, relative_directory)
      relative = "#{relative_directory}/#{name}"
      absolute = File.join(root, relative)
      child_stat = safe_lstat!(absolute, relative)
      reject_symlink_or_special!(relative, child_stat, allow_directory: true)

      exclusion_kind = exclusion&.call(relative, child_stat)
      if exclusion_kind
        expected_directory = exclusion_kind == :directory
        if child_stat.directory? != expected_directory
          raise Error, "Unity exclusion type mismatch for #{relative}"
        end
        next
      end

      if child_stat.directory?
        entries.concat(snapshot_directory!(root, relative, &exclusion))
      else
        entries << snapshot_regular_file!(root, relative, child_stat)
      end
    end

    unless initial_children == sorted_children!(absolute_directory, relative_directory)
      raise Error, "Unity input directory changed while it was being hashed: #{relative_directory}"
    end
    entries
  end

  def snapshot_path!(root, relative, expected:)
    assert_no_symlink_components!(root, relative)
    stat = safe_lstat!(File.join(root, relative), relative)
    if expected == :file
      raise Error, "tracked Unity source is not a regular file: #{relative}" unless stat.file?
      snapshot_regular_file!(root, relative, stat)
    else
      raise Error, "unsupported expected path type: #{expected.inspect}"
    end
  end

  def snapshot_regular_file!(root, relative, initial_lstat)
    reject_symlink_or_special!(relative, initial_lstat, allow_directory: false)
    path = File.join(root, relative)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    digest = Digest::SHA256.new
    bytes = 0

    File.open(path, flags) do |file|
      before = file.stat
      unless before.file? && same_file?(initial_lstat, before)
        raise Error, "Unity input changed before hashing: #{relative}"
      end
      while (chunk = file.read(1024 * 1024))
        bytes += chunk.bytesize
        digest.update(chunk)
      end
      after = file.stat
      unless same_snapshot?(before, after) && bytes == after.size
        raise Error, "Unity input changed while it was being hashed: #{relative}"
      end
    end

    {
      "path" => relative,
      "type" => executable?(initial_lstat) ? "executable" : "file",
      "size" => bytes,
      "sha256" => digest.hexdigest,
    }
  rescue Errno::ELOOP
    raise Error, "symlinked Unity inputs are forbidden: #{relative}"
  rescue SystemCallError => error
    raise Error, "unable to hash Unity input #{relative}: #{error.message}"
  end

  def directory_entry(relative)
    {
      "path" => relative,
      "type" => "directory",
      "size" => 0,
      "sha256" => EMPTY_SHA256,
    }
  end

  def summarize(entries, roots:, excluded:)
    sorted = entries.sort_by { |entry| entry.fetch("path").b }
    paths = sorted.map { |entry| entry.fetch("path") }
    raise Error, "Unity provenance contains duplicate paths" unless paths.uniq.length == paths.length

    digest = Digest::SHA256.new
    digest.update("#{CANONICALIZATION}\0")
    sorted.each do |entry|
      digest.update(JSON.generate([
        entry.fetch("path"),
        entry.fetch("type"),
        entry.fetch("size"),
        entry.fetch("sha256"),
      ]))
      digest.update("\n")
    end

    files = sorted.reject { |entry| entry.fetch("type") == "directory" }
    {
      "roots" => roots,
      "excluded" => excluded,
      "entry_count" => sorted.length,
      "file_count" => files.length,
      "total_size" => files.sum { |entry| entry.fetch("size") },
      "sha256" => digest.hexdigest,
    }
  end

  def read_committed_manifest!(root)
    relative = MANIFEST_RELATIVE_PATH
    assert_no_symlink_components!(root, relative)
    path = File.join(root, relative)
    stat = safe_lstat!(path, relative)
    raise Error, "Unity export provenance manifest is not a regular file" unless stat.file?
    raise Error, "Unity export provenance manifest is too large" if stat.size > MAX_MANIFEST_BYTES

    _, _, tracked_status = git_capture(
      root,
      "cat-file",
      "-e",
      "HEAD:#{relative}",
    )
    unless tracked_status.success?
      raise Error, "Unity export provenance manifest must be committed at HEAD"
    end

    head_bytes, _, show_status = git_capture(
      root,
      "show",
      "HEAD:#{relative}",
    )
    raise Error, "unable to read committed Unity export provenance manifest" unless show_status.success?

    current_bytes = File.binread(path)
    unless current_bytes == head_bytes
      raise Error, "Unity export provenance manifest differs from the committed HEAD version"
    end

    parsed = JSON.parse(current_bytes)
    canonical_bytes = JSON.pretty_generate(parsed) << "\n"
    unless current_bytes == canonical_bytes
      raise Error, "Unity export provenance manifest is not canonical JSON"
    end
    parsed
  rescue JSON::ParserError
    raise Error, "Unity export provenance manifest is not valid JSON"
  rescue SystemCallError => error
    raise Error, "unable to read Unity export provenance manifest: #{error.message}"
  end

  def validate_manifest_shape!(manifest)
    unless manifest.is_a?(Hash) && manifest.keys == %w[schema_version canonicalization source exports]
      raise Error, "Unity export provenance manifest has an unexpected top-level shape"
    end
    unless manifest.fetch("schema_version") == SCHEMA_VERSION &&
           manifest.fetch("canonicalization") == CANONICALIZATION
      raise Error, "Unity export provenance manifest uses an unsupported schema"
    end

    validate_summary!(manifest.fetch("source"), SOURCE_ROOTS, [])
    exports = manifest.fetch("exports")
    unless exports.is_a?(Hash) && exports.keys == %w[android ios]
      raise Error, "Unity export provenance manifest must contain exactly Android and iOS exports"
    end
    validate_summary!(exports.fetch("android"), ANDROID_ROOTS, ANDROID_EXCLUSION_RULES)
    validate_summary!(exports.fetch("ios"), IOS_ROOTS, IOS_EXCLUSION_RULES)
  rescue KeyError
    raise Error, "Unity export provenance manifest is missing required fields"
  end

  def validate_summary!(summary, roots, excluded)
    expected_keys = %w[roots excluded entry_count file_count total_size sha256]
    unless summary.is_a?(Hash) && summary.keys == expected_keys &&
           summary["roots"] == roots && summary["excluded"] == excluded &&
           summary["entry_count"].is_a?(Integer) && summary["entry_count"].positive? &&
           summary["file_count"].is_a?(Integer) && summary["file_count"].positive? &&
           summary["file_count"] <= summary["entry_count"] &&
           summary["total_size"].is_a?(Integer) && summary["total_size"].positive? &&
           summary["sha256"].is_a?(String) && summary["sha256"].match?(/\A[0-9a-f]{64}\z/)
      raise Error, "Unity export provenance manifest contains an invalid tree summary"
    end
  end

  def ios_exclusion(relative, stat)
    root = IOS_ROOTS.fetch(0)
    path = relative.delete_prefix("#{root}/")
    # The snapshot walker rejects symlinks/special files and enforces this type.
    return :file if IOS_PROFILER_OUTPUT_PATHS.include?(path)

    components = path.split("/")
    return :directory if stat.directory? && components.include?("xcuserdata")
    return :directory if stat.directory? && components.first == "Il2CppTempDirArtifacts"
    if stat.directory? && components.length == 1 && components.first.end_with?("_BurstDebugInformation_DoNotShip")
      return :directory
    end

    nil
  end

  def android_exclusion(relative, stat)
    prefix = "unity/masso_avatar/Builds/Android/"
    path = relative.delete_prefix(prefix)
    return :directory if stat.directory? && %w[unityLibrary/.cxx unityLibrary/build unityLibrary/symbols].include?(path)
    if stat.file? && path.match?(%r{\AunityLibrary/src/main/jniLibs/[^/]+/libil2cpp[^/]*\.so\z})
      return :file
    end

    nil
  end

  def canonical_repo_root!(repo_root)
    expanded = File.expand_path(repo_root)
    stat = File.lstat(expanded)
    raise Error, "repository root must not be a symlink" if stat.symlink?
    raise Error, "repository root is not a directory" unless stat.directory?
    File.realpath(expanded)
  rescue SystemCallError => error
    raise Error, "unable to resolve repository root: #{error.message}"
  end

  def assert_no_symlink_components!(root, relative, allow_missing_leaf: false)
    validate_relative_path!(relative)
    current = root
    components = relative.split("/")
    components.each_with_index do |component, index|
      current = File.join(current, component)
      begin
        stat = File.lstat(current)
      rescue Errno::ENOENT
        if allow_missing_leaf && index == components.length - 1
          return
        end
        raise Error, "required Unity provenance path is missing: #{relative}"
      end
      raise Error, "symlinked Unity inputs are forbidden: #{relative}" if stat.symlink?
      if index < components.length - 1 && !stat.directory?
        raise Error, "Unity provenance path has a non-directory ancestor: #{relative}"
      end
    end
  end

  def validate_relative_path!(relative)
    unless relative.is_a?(String) && !relative.empty? && relative.valid_encoding? &&
           relative.encoding != Encoding::BINARY && !relative.start_with?("/") &&
           !relative.include?("\0") && !relative.match?(/[\r\n]/) &&
           Pathname.new(relative).cleanpath.to_s == relative &&
           relative.split("/").none? { |component| component.empty? || component == "." || component == ".." }
      raise Error, "Unity provenance path is not canonical: #{relative.inspect}"
    end
  end

  def validate_child_name!(name, parent)
    unless name.valid_encoding? && name.encoding != Encoding::BINARY &&
           !name.empty? && name != "." && name != ".." &&
           !name.include?("/") && !name.include?("\0") && !name.match?(/[\r\n]/)
      raise Error, "Unity input contains a non-canonical child under #{parent}"
    end
  end

  def sorted_children!(absolute, relative)
    Dir.children(absolute).sort_by(&:b)
  rescue SystemCallError => error
    raise Error, "unable to enumerate Unity input #{relative}: #{error.message}"
  end

  def safe_lstat!(absolute, relative)
    File.lstat(absolute)
  rescue SystemCallError => error
    raise Error, "unable to inspect Unity input #{relative}: #{error.message}"
  end

  def reject_symlink_or_special!(relative, stat, allow_directory:)
    raise Error, "symlinked Unity inputs are forbidden: #{relative}" if stat.symlink?
    return if stat.file?
    return if allow_directory && stat.directory?

    raise Error, "special Unity inputs are forbidden: #{relative}"
  end

  def same_file?(left, right)
    left.dev == right.dev && left.ino == right.ino && left.size == right.size
  end

  def same_file_identity?(left, right)
    left.dev == right.dev && left.ino == right.ino && left.ftype == right.ftype
  end

  def same_snapshot?(left, right)
    same_file?(left, right) &&
      left.mtime == right.mtime && left.mtime.nsec == right.mtime.nsec &&
      left.ctime == right.ctime && left.ctime.nsec == right.ctime.nsec
  end

  def executable?(stat)
    (stat.mode & 0o111) != 0
  end

  def git_capture(root, *arguments)
    overrides = FORBIDDEN_GIT_REPOSITORY_ENV.select { |name| ENV.key?(name) }
    unless overrides.empty?
      raise Error,
            "forbidden Git repository override environment: #{overrides.sort.join(', ')}"
    end

    sanitized = FORBIDDEN_GIT_REPOSITORY_ENV.to_h { |name| [name, nil] }
    command = ["git", "--no-replace-objects", "-C", root]
    top_level, _, top_level_status = Open3.capture3(
      sanitized,
      *command,
      "rev-parse",
      "--show-toplevel",
    )
    begin
      canonical_top_level = File.realpath(top_level.strip) if top_level_status.success?
    rescue SystemCallError
      canonical_top_level = nil
    end
    unless canonical_top_level == root
      raise Error, "Git repository top-level does not match the canonical release root"
    end

    Open3.capture3(sanitized, *command, *arguments)
  end

  def remove_generated_libil2cpp_files!(root)
    relative = ANDROID_JNI_LIBS_RELATIVE_PATH
    inspected = inspect_generated_path_if_present!(root, relative)
    return if inspected.nil?

    stat = inspected.fetch(:chain).last.fetch(:stat)
    raise Error, "Android Unity jniLibs input is not a directory" unless stat.directory?

    with_verified_generated_directory!(
      inspected: inspected,
      relative: relative,
    ) do |jni_libs_directory|
      sorted_open_directory_children!(jni_libs_directory, relative).each do |abi|
        validate_child_name!(abi, relative)
        abi_relative = "#{relative}/#{abi}"
        abi_stat = File.lstat(abi)
        reject_symlink_or_special!(abi_relative, abi_stat, allow_directory: true)
        next unless abi_stat.directory?

        with_verified_generated_child_directory!(
          basename: abi,
          expected_stat: abi_stat,
          relative: abi_relative,
        ) do |abi_directory|
          sorted_open_directory_children!(abi_directory, abi_relative).each do |name|
            next unless name.match?(ANDROID_GENERATED_LIBIL2CPP)

            validate_child_name!(name, abi_relative)
            generated_relative = "#{abi_relative}/#{name}"
            generated_stat = File.lstat(name)
            reject_symlink_or_special!(generated_relative, generated_stat, allow_directory: false)
            confirmed = File.lstat(name)
            unless !confirmed.symlink? && confirmed.file? &&
                   same_file_identity?(generated_stat, confirmed)
              raise Error, "generated libil2cpp changed before cleanup: #{generated_relative}"
            end

            File.unlink(name)
            assert_generated_entry_missing!(name, generated_relative)
          end
        end

        current_abi = File.lstat(abi)
        unless !current_abi.symlink? && current_abi.directory? &&
               same_file_identity?(abi_stat, current_abi)
          raise Error, "Android Unity ABI input changed during cleanup: #{abi_relative}"
        end
      end
    end

    assert_generated_chain_unchanged!(inspected.fetch(:chain), relative)
  end

  def inspect_generated_path_if_present!(root, relative)
    validate_relative_path!(relative)
    current = root
    chain = []
    components = relative.split("/")
    components.each_with_index do |component, index|
      current = File.join(current, component)
      begin
        stat = File.lstat(current)
      rescue Errno::ENOENT
        return nil
      end
      raise Error, "symlinked generated Unity output is forbidden: #{relative}" if stat.symlink?
      if index < components.length - 1 && !stat.directory?
        raise Error, "generated Unity output has a non-directory ancestor: #{relative}"
      end
      chain << { path: current, stat: stat }
    end

    { path: current, chain: chain }
  end

  def with_verified_generated_parent_directory!(root:, inspected:, relative:)
    path = inspected.fetch(:path)
    chain = inspected.fetch(:chain)
    parent_chain = chain[0...-1]
    parent_path = File.dirname(path)
    expected_parent = parent_chain.empty? ? File.lstat(root) : parent_chain.last.fetch(:stat)

    assert_generated_chain_unchanged!(parent_chain, relative)
    with_verified_generated_directory_path!(
      path: parent_path,
      expected_stat: expected_parent,
      relative: File.dirname(relative),
    ) do
      assert_generated_chain_unchanged!(parent_chain, relative)
      yield File.basename(path)
    end
  end

  def with_verified_generated_directory!(inspected:, relative:)
    chain = inspected.fetch(:chain)
    assert_generated_chain_unchanged!(chain, relative)
    with_verified_generated_directory_path!(
      path: inspected.fetch(:path),
      expected_stat: chain.last.fetch(:stat),
      relative: relative,
    ) do |directory|
      assert_generated_chain_unchanged!(chain, relative)
      yield directory
    end
  end

  def with_verified_generated_child_directory!(basename:, expected_stat:, relative:)
    with_verified_generated_directory_path!(
      path: basename,
      expected_stat: expected_stat,
      relative: relative,
    ) do |directory|
      yield directory
    end
  end

  def with_verified_generated_directory_path!(path:, expected_stat:, relative:)
    Dir.open(path) do |directory|
      opened = IO.new(directory.fileno, autoclose: false).stat
      current = File.lstat(path)
      unless opened.directory? && !current.symlink? && current.directory? &&
             same_file_identity?(expected_stat, opened) &&
             same_file_identity?(expected_stat, current)
        raise Error, "generated Unity directory changed during cleanup: #{relative}"
      end

      Dir.fchdir(directory.fileno) do
        yield directory
      end
    end
  end

  def sorted_open_directory_children!(directory, relative)
    directory.rewind
    directory.each_child.to_a.sort_by(&:b)
  rescue SystemCallError => error
    raise Error, "unable to enumerate generated Unity output #{relative}: #{error.message}"
  end

  def assert_generated_chain_unchanged!(chain, relative)
    chain.each do |entry|
      current = File.lstat(entry.fetch(:path))
      unless !current.symlink? && same_file_identity?(entry.fetch(:stat), current)
        raise Error, "generated Unity output changed during cleanup: #{relative}"
      end
    rescue SystemCallError
      raise Error, "generated Unity output changed during cleanup: #{relative}"
    end
  end

  def assert_generated_entry_missing!(basename, relative)
    File.lstat(basename)
    raise Error, "generated Unity output still exists after cleanup: #{relative}"
  rescue Errno::ENOENT
    nil
  end

  def normalize_platform!(platform)
    value = platform.to_s.downcase
    return value if %w[android ios].include?(value)

    raise Error, "platform must be ios or android"
  end
end
