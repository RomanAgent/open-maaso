# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'pathname'
require 'tmpdir'
require 'xcodeproj'

class LinkIosUnityLibraryTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir('maaso-unity-link-'))
    @runner_path = @root.join('ios/Runner.xcodeproj')
    @unity_path = @root.join('unity/masso_avatar/Builds/iOS/Unity-iPhone.xcodeproj')
    @runner = Xcodeproj::Project.new(@runner_path.to_s)
    runner_target = @runner.new_target(:application, 'Runner', :ios, '15.5')
    @runner.add_build_configuration('Profile', :release)
    runner_target.add_build_configuration('Profile', :release)
    runner_target.build_configurations.each do |config|
      config.build_settings['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '/custom/frameworks']
    end
    @runner.save

    @unity = Xcodeproj::Project.new(@unity_path.to_s)
    @unity_target = @unity.new_target(:framework, 'UnityFramework', :ios, '15.5')
    @unity_target.build_configuration_list.default_configuration_name = 'Release'
    @unity.save
    # Match the existing linked app: the linker updates this project reference.
    unity_ref = @runner.new(Xcodeproj::Project::Object::PBXFileReference)
    unity_ref.path = '../unity/masso_avatar/Builds/iOS/Unity-iPhone.xcodeproj'
    unity_ref.last_known_file_type = 'wrapper.pb-project'
    unity_ref.source_tree = '<group>'
    @runner.main_group.children << unity_ref
    @runner.save
    metadata = @unity_path.dirname.join('Data/Managed/Metadata/global-metadata.dat')
    FileUtils.mkdir_p(metadata.dirname)
    metadata.write('fixture metadata')
    scripts = @root.join('tool/unity')
    FileUtils.mkdir_p(scripts)
    %w[link_ios_unity_library.rb xcode_project_sanitizer.rb].each do |file|
      FileUtils.cp(File.expand_path("../../../tool/unity/#{file}", __dir__), scripts.join(file))
    end
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_linker
    output, status = Open3.capture2e(RbConfig.ruby, @root.join('tool/unity/link_ios_unity_library.rb').to_s)
    assert status.success?, output
    Xcodeproj::Project.open(@runner_path.to_s).targets.find { |target| target.name == 'Runner' }
  end

  def search_paths(target, name)
    target.build_configurations.find { |config| config.name == name }.build_settings['FRAMEWORK_SEARCH_PATHS']
  end

  def test_profile_resolves_default_dependency_product_without_changing_debug_or_release
    target = run_linker
    fallback = '$(BUILD_DIR)/Release$(EFFECTIVE_PLATFORM_NAME)'
    assert_includes search_paths(target, 'Profile'), fallback
    %w[Debug Release].each { |name| refute_includes search_paths(target, name), fallback }
    %w[Debug Profile Release].each do |name|
      assert_includes search_paths(target, name), '/custom/frameworks'
      assert_includes search_paths(target, name), '$(inherited)'
    end
    assert_equal 1, target.frameworks_build_phase.files_references.count { |file| file.display_name == 'UnityFramework.framework' }
    assert_equal 1, search_paths(run_linker, 'Profile').count(fallback)
  end

  def test_matching_profile_uses_its_own_product
    @unity_target.add_build_configuration('Profile', :release)
    @unity.save
    refute_includes search_paths(run_linker, 'Profile'), '$(BUILD_DIR)/Release$(EFFECTIVE_PLATFORM_NAME)'
  end

  def test_fallback_follows_exported_target_default_instead_of_assuming_release
    @unity_target.add_build_configuration('ReleaseForProfiling', :release)
    @unity_target.build_configuration_list.default_configuration_name = 'ReleaseForProfiling'
    @unity.save
    paths = search_paths(run_linker, 'Profile')
    assert_includes paths, '$(BUILD_DIR)/ReleaseForProfiling$(EFFECTIVE_PLATFORM_NAME)'
    refute_includes paths, '$(BUILD_DIR)/Release$(EFFECTIVE_PLATFORM_NAME)'
  end

  def test_missing_default_configuration_fails_instead_of_silently_losing_unity
    @unity_target.build_configuration_list.default_configuration_name = 'Missing'
    @unity.save
    before = @runner_path.join('project.pbxproj').read
    output, status = Open3.capture2e(RbConfig.ruby, @root.join('tool/unity/link_ios_unity_library.rb').to_s)
    refute status.success?
    assert_includes output, 'UnityFramework has no valid default build configuration for Profile'
    assert_equal before, @runner_path.join('project.pbxproj').read
  end
end
