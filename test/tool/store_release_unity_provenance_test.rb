# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "thread"
require "tmpdir"

require_relative "../../tool/unity/store_release_provenance"

class StoreReleaseUnityProvenanceTest < Minitest::Test
  def setup
    @temporary = Dir.mktmpdir("maaso-unity-provenance-test-")
    @repo = File.join(@temporary, "repo")
    FileUtils.mkdir_p(@repo)
    git!("init", "-q")

    write("tool/unity/exporter.rb", "puts :export\n")
    write("unity/masso_avatar/.gitignore", "/Builds/\n")
    write("unity/masso_avatar/Assets/avatar.asset", "avatar-v1\n")

    write("unity/masso_avatar/Builds/iOS/UnityFramework/source.mm", "ios-v1\n")
    write("unity/masso_avatar/Builds/iOS/Unity-iPhone.xcodeproj/project.pbxproj", "// fixture\n")
    write("unity/masso_avatar/Builds/Android/gradle.properties", "unityStreamingAssets=Data\n")
    write("unity/masso_avatar/Builds/Android/shared/common.gradle", "ext.shared = true\n")
    write("unity/masso_avatar/Builds/Android/unityLibrary/build.gradle", "apply from: '../shared/common.gradle'\n")
    write("unity/masso_avatar/Builds/Android/unityLibrary/src/main/assets/bin/Data/data.unity3d", "android-v1\n")
    write("unity/masso_avatar/Builds/Android/unityLibrary/src/main/jniLibs/arm64-v8a/libunity.so", "runtime\n")

    git!("add", "tool/unity", "unity/masso_avatar")
    commit!("fixture source")
    write_and_commit_manifest!
  end

  def teardown
    FileUtils.remove_entry(@temporary) if File.exist?(@temporary)
  end

  def test_committed_manifest_verifies_both_platforms
    assert MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    assert MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :android)

    manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
    assert_equal 1, manifest.fetch("schema_version")
    assert_match(/\A[0-9a-f]{64}\z/, manifest.dig("source", "sha256"))
    assert_match(/\A[0-9a-f]{64}\z/, manifest.dig("exports", "ios", "sha256"))
    assert_match(/\A[0-9a-f]{64}\z/, manifest.dig("exports", "android", "sha256"))
  end

  def test_source_export_and_extra_consumed_file_drift_fail_closed
    append("tool/unity/exporter.rb", "puts :changed\n")
    assert_error(/tracked Unity source/) do
      MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    end

    write("tool/unity/exporter.rb", "puts :export\n")
    File.chmod(0o644, absolute("tool/unity/exporter.rb"))
    append("unity/masso_avatar/Builds/iOS/UnityFramework/source.mm", "changed\n")
    assert_error(/ios Unity export/) do
      MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    end

    write("unity/masso_avatar/Builds/iOS/UnityFramework/source.mm", "ios-v1\n")
    write("unity/masso_avatar/Builds/Android/shared/unreviewed.gradle", "surprise\n")
    assert_error(/android Unity export/) do
      MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :android)
    end
  end

  def test_executable_mode_is_part_of_the_canonical_file_type
    File.chmod(0o755, absolute("tool/unity/exporter.rb"))
    assert_error(/tracked Unity source/) do
      MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    end
  end

  def test_explicit_generated_output_exclusions_do_not_drift
    write("unity/masso_avatar/Builds/iOS/Unity-iPhone.xcodeproj/xcuserdata/user.xcuserdatad/state", "state\n")
    write("unity/masso_avatar/Builds/iOS/Il2CppTempDirArtifacts/cache/object.o", "temp\n")
    write("unity/masso_avatar/Builds/iOS/avatar_BurstDebugInformation_DoNotShip/log.txt", "debug\n")

    write("unity/masso_avatar/Builds/Android/unityLibrary/.cxx/cache.bin", "cache\n")
    write("unity/masso_avatar/Builds/Android/unityLibrary/build/output.bin", "build\n")
    write("unity/masso_avatar/Builds/Android/unityLibrary/symbols/arm64-v8a/libil2cpp.so", "symbols\n")
    write("unity/masso_avatar/Builds/Android/unityLibrary/src/main/jniLibs/arm64-v8a/libil2cpp.so", "generated\n")

    assert MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    assert MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :android)
    assert MaasoUnityExportProvenance.clean_android_generated_outputs!(repo_root: @repo)
    refute File.exist?(absolute("unity/masso_avatar/Builds/Android/unityLibrary/.cxx"))
    refute File.exist?(absolute("unity/masso_avatar/Builds/Android/unityLibrary/build"))
    refute File.exist?(absolute("unity/masso_avatar/Builds/Android/unityLibrary/symbols"))
    refute File.exist?(absolute("unity/masso_avatar/Builds/Android/unityLibrary/src/main/jniLibs/arm64-v8a/libil2cpp.so"))
    assert File.exist?(absolute("unity/masso_avatar/Builds/Android/unityLibrary/src/main/jniLibs/arm64-v8a/libunity.so"))
  end

  def test_ios_native_profiler_outputs_do_not_drift
    output = "unity/masso_avatar/Builds/iOS/Il2CppOutputProject/Source/il2cppOutput"
    paths = ["#{output}/profile.json", "#{output}/il2cpp-compile.traceevents"]
    write("#{output}/Assembly-CSharp.cpp", "compiled source\n")
    paths.each { |path| write(path, "first compile timing\n") }
    write_and_commit_manifest!

    paths.each { |path| write(path, "different PID, memory and timing\n") }
    assert MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    paths.each { |path| File.unlink(absolute(path)) }
    assert MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
  end

  def test_ios_profiler_exclusions_leave_other_inputs_covered
    root = "unity/masso_avatar/Builds/iOS"
    paths = [
      "#{root}/Il2CppOutputProject/Source/il2cppOutput/Assembly-CSharp.cpp",
      "#{root}/Il2CppOutputProject/Source/il2cppOutput/build-config.json",
      "#{root}/Il2CppOutputProject/Source/il2cppOutput/profile.json.extra",
      "#{root}/Il2CppOutputProject/Source/il2cppOutput/il2cpp-compile.traceevents.extra",
      "#{root}/Il2CppOutputProject/Source/profile.json",
      "#{root}/Data/profile.json",
      "#{root}/Data/il2cpp-compile.traceevents",
      "#{root}/Data/Managed/Metadata/global-metadata.dat",
      "#{root}/Unity-iPhone.xcodeproj/project.pbxproj",
    ]
    paths.each { |path| write(path, "reviewed input\n") }
    write_and_commit_manifest!

    paths.each do |path|
      append(path, "unreviewed input\n")
      assert_error(/ios Unity export/) do
        MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
      end
      write(path, "reviewed input\n")
    end
    assert MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
  end

  def test_ios_profiler_output_exclusions_reject_non_regular_files
    output = "unity/masso_avatar/Builds/iOS/Il2CppOutputProject/Source/il2cppOutput"
    FileUtils.mkdir_p(absolute(output))
    ["profile.json", "il2cpp-compile.traceevents"].each do |name|
      path = absolute("#{output}/#{name}")
      File.symlink(absolute("tool/unity/exporter.rb"), path)
      assert_error(/symlinked Unity inputs/) do
        MaasoUnityExportProvenance.build_manifest(repo_root: @repo)
      end
      File.unlink(path)

      File.mkfifo(path)
      assert_error(/special Unity inputs/) do
        MaasoUnityExportProvenance.build_manifest(repo_root: @repo)
      end
      File.unlink(path)

      Dir.mkdir(path)
      assert_error(/exclusion type mismatch|file-only exclusion matched a directory/) do
        MaasoUnityExportProvenance.build_manifest(repo_root: @repo)
      end
      Dir.rmdir(path)
    end
  end

  def test_symlink_and_special_consumed_inputs_are_rejected
    target = absolute("unity/masso_avatar/Builds/iOS/UnityFramework/source.mm")
    link = absolute("unity/masso_avatar/Builds/iOS/UnityFramework/linked.mm")
    File.symlink(target, link)
    assert_error(/symlinked Unity inputs/) do
      MaasoUnityExportProvenance.build_manifest(repo_root: @repo)
    end
    File.unlink(link)

    special_path = absolute("unity/masso_avatar/Builds/Android/shared/build.pipe")
    File.mkfifo(special_path)
    assert_error(/special Unity inputs/) do
      MaasoUnityExportProvenance.build_manifest(repo_root: @repo)
    end
  ensure
    File.unlink(special_path) if special_path && File.exist?(special_path)
  end

  def test_direct_android_cleanup_rejects_symlinked_ancestor_without_deleting_outside
    unity_library = absolute(
      "unity/masso_avatar/Builds/Android/unityLibrary",
    )
    outside = File.join(@temporary, "outside-unity-library")
    canary = File.join(outside, ".cxx", "outside-canary.txt")
    FileUtils.mkdir_p(File.dirname(canary))
    File.write(canary, "must survive\n")
    unity_library_backup = "#{unity_library}.reviewed"
    File.rename(unity_library, unity_library_backup)
    File.symlink(outside, unity_library)

    assert_error(/symlinked generated Unity output is forbidden/) do
      MaasoUnityExportProvenance.clean_android_generated_outputs!(
        repo_root: @repo,
      )
    end
    assert File.file?(canary), "cleanup followed an ancestor symlink outside the repository"
    assert_equal "must survive\n", File.read(canary, encoding: "UTF-8")

    File.unlink(unity_library)
    File.rename(unity_library_backup, unity_library)
    jni_libs = File.join(unity_library, "src", "main", "jniLibs")
    jni_libs_backup = "#{jni_libs}.reviewed"
    outside_jni = File.join(@temporary, "outside-jni-libs")
    outside_libil2cpp = File.join(outside_jni, "arm64-v8a", "libil2cpp.so")
    FileUtils.mkdir_p(File.dirname(outside_libil2cpp))
    File.write(outside_libil2cpp, "outside binary\n")
    File.rename(jni_libs, jni_libs_backup)
    File.symlink(outside_jni, jni_libs)

    assert_error(/symlinked generated Unity output is forbidden/) do
      MaasoUnityExportProvenance.clean_android_generated_outputs!(
        repo_root: @repo,
      )
    end
    assert File.file?(outside_libil2cpp), "cleanup unlinked an external libil2cpp"
    assert_equal "outside binary\n", File.read(outside_libil2cpp, encoding: "UTF-8")
  end

  def test_android_directory_cleanup_race_cannot_follow_replaced_ancestor
    unity_library = absolute(
      "unity/masso_avatar/Builds/Android/unityLibrary",
    )
    write(
      "unity/masso_avatar/Builds/Android/unityLibrary/.cxx/cache.bin",
      "generated cache\n",
    )
    reviewed_library = "#{unity_library}.reviewed-during-cleanup"
    outside = File.join(@temporary, "outside-directory-race")
    canary = File.join(outside, ".cxx", "outside-canary.txt")
    FileUtils.mkdir_p(File.dirname(canary))
    File.binwrite(canary, "must survive directory race\n")

    ready = Queue.new
    racer = Thread.new do
      next unless ready.pop == :race

      File.rename(unity_library, reviewed_library)
      File.symlink(outside, unity_library)
      nil
    rescue StandardError => error
      error
    end
    original_remove = FileUtils.method(:remove_entry_secure)
    intercepted = false
    silently_define_singleton_method(FileUtils, :remove_entry_secure) do |path, *arguments|
      if !intercepted && File.basename(path.to_s) == ".cxx"
        intercepted = true
        ready << :race
        race_error = racer.value
        raise race_error unless race_error.nil?
      end
      original_remove.call(path, *arguments)
    end

    assert_error(/symlinked generated Unity output|changed during cleanup/) do
      MaasoUnityExportProvenance.clean_android_generated_outputs!(
        repo_root: @repo,
      )
    end
    assert intercepted, "the test did not race the generated-directory deletion"
    assert File.file?(canary), "cleanup followed a raced ancestor to an external directory"
    assert_equal "must survive directory race\n", File.binread(canary)
  ensure
    silently_define_singleton_method(
      FileUtils,
      :remove_entry_secure,
      original_remove,
    ) if original_remove
    ready << :cancel if racer&.alive?
    racer&.join
  end

  def test_android_libil2cpp_cleanup_race_cannot_follow_replaced_ancestor
    generated_relative =
      "unity/masso_avatar/Builds/Android/unityLibrary/src/main/jniLibs/arm64-v8a/libil2cpp.so"
    write(generated_relative, "generated binary\n")

    jni_libs = absolute(
      "unity/masso_avatar/Builds/Android/unityLibrary/src/main/jniLibs",
    )
    reviewed_jni_libs = "#{jni_libs}.reviewed-during-cleanup"
    outside = File.join(@temporary, "outside-file-race")
    canary = File.join(outside, "arm64-v8a", "libil2cpp.so")
    FileUtils.mkdir_p(File.dirname(canary))
    File.binwrite(canary, "must survive file race\n")

    ready = Queue.new
    racer = Thread.new do
      next unless ready.pop == :race

      File.rename(jni_libs, reviewed_jni_libs)
      File.symlink(outside, jni_libs)
      nil
    rescue StandardError => error
      error
    end
    original_unlink = File.method(:unlink)
    intercepted = false
    silently_define_singleton_method(File, :unlink) do |*paths|
      generated_name = File.basename(paths.fetch(0).to_s)
      if !intercepted &&
         generated_name.match?(MaasoUnityExportProvenance::ANDROID_GENERATED_LIBIL2CPP)
        intercepted = true
        ready << :race
        race_error = racer.value
        raise race_error unless race_error.nil?
      end
      original_unlink.call(*paths)
    end

    assert_error(/symlinked generated Unity output|changed during cleanup/) do
      MaasoUnityExportProvenance.clean_android_generated_outputs!(
        repo_root: @repo,
      )
    end
    assert intercepted, "the test did not race the generated-library deletion"
    assert File.file?(canary), "cleanup followed a raced ancestor to an external library"
    assert_equal "must survive file race\n", File.binread(canary)
  ensure
    silently_define_singleton_method(File, :unlink, original_unlink) if original_unlink
    ready << :cancel if racer&.alive?
    racer&.join
  end

  def test_manifest_must_exist_unchanged_at_head
    append(MaasoUnityExportProvenance::MANIFEST_RELATIVE_PATH, " \n")
    assert_error(/differs from the committed HEAD/) do
      MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    end

    git!("checkout", "--", MaasoUnityExportProvenance::MANIFEST_RELATIVE_PATH)
    git!("rm", "-q", MaasoUnityExportProvenance::MANIFEST_RELATIVE_PATH)
    commit!("remove manifest")
    assert_error(/required Unity provenance path is missing/) do
      MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    end

    MaasoUnityExportProvenance.write_manifest!(repo_root: @repo)
    assert_error(/manifest must be committed at HEAD/) do
      MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    end
    File.unlink(manifest_path)

    target = absolute("manifest-target.json")
    File.write(target, "{}\n")
    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.symlink(target, manifest_path)
    assert_error(/manifest must not be a symlink/) do
      MaasoUnityExportProvenance.write_manifest!(repo_root: @repo)
    end
  end

  def test_git_repository_override_environment_is_rejected
    original = {}
    MaasoUnityExportProvenance::FORBIDDEN_GIT_REPOSITORY_ENV.each do |name|
      original[name] = ENV[name] if ENV.key?(name)
      ENV.delete(name)
    end
    ENV["GIT_DIR"] = absolute("redirected.git")
    ENV["GIT_WORK_TREE"] = absolute("redirected-worktree")

    assert_error(/forbidden Git repository override environment: GIT_DIR, GIT_WORK_TREE/) do
      MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    end
  ensure
    MaasoUnityExportProvenance::FORBIDDEN_GIT_REPOSITORY_ENV.each do |name|
      ENV.delete(name)
      ENV[name] = original[name] if original&.key?(name)
    end
  end

  def test_git_replacement_refs_are_ignored
    original_commit = git!("rev-list", "--max-parents=0", "HEAD").strip
    git!("replace", "HEAD", original_commit)

    assert MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
  ensure
    git!("replace", "-d", "HEAD") if original_commit
  end

  def test_git_core_worktree_redirect_is_rejected
    redirected = absolute("redirected-worktree")
    FileUtils.mkdir_p(redirected)
    git!("config", "core.worktree", redirected)

    assert_error(/top-level does not match the canonical release root/) do
      MaasoUnityExportProvenance.verify!(repo_root: @repo, platform: :ios)
    end
  ensure
    if redirected
      _, _, status = Open3.capture3(
        "git",
        "--git-dir",
        absolute(".git"),
        "config",
        "--unset",
        "core.worktree",
      )
      assert status.success?, "unable to restore core.worktree in test fixture"
    end
  end

  private

  def silently_define_singleton_method(receiver, name, implementation = nil, &block)
    verbosity = $VERBOSE
    $VERBOSE = nil
    if implementation
      receiver.define_singleton_method(name, implementation)
    else
      receiver.define_singleton_method(name, &block)
    end
  ensure
    $VERBOSE = verbosity
  end

  def write_and_commit_manifest!
    MaasoUnityExportProvenance.write_manifest!(repo_root: @repo)
    git!("add", MaasoUnityExportProvenance::MANIFEST_RELATIVE_PATH)
    commit!("reviewed exports")
  end

  def manifest_path
    absolute(MaasoUnityExportProvenance::MANIFEST_RELATIVE_PATH)
  end

  def absolute(relative)
    File.join(@repo, relative)
  end

  def write(relative, contents)
    path = absolute(relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
  end

  def append(relative, contents)
    File.open(absolute(relative), "ab") { |file| file.write(contents) }
  end

  def git!(*arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", @repo, *arguments)
    assert status.success?, "git #{arguments.join(' ')} failed: #{stdout}#{stderr}"
    stdout
  end

  def commit!(message)
    git!(
      "-c",
      "user.name=Maaso Test",
      "-c",
      "user.email=maaso-test@example.invalid",
      "commit",
      "-q",
      "-m",
      message,
    )
  end

  def assert_error(pattern)
    error = assert_raises(MaasoUnityExportProvenance::Error) { yield }
    assert_match pattern, error.message
  end
end
