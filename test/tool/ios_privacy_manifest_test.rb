# frozen_string_literal: true

require 'minitest/autorun'
require 'pathname'
require 'xcodeproj'

class IosPrivacyManifestTest < Minitest::Test
  ROOT = Pathname.new(ENV.fetch('MAASO_TEST_REPO', File.expand_path('../..', __dir__)))
  MANIFEST = ROOT.join('ios/Runner/PrivacyInfo.xcprivacy')

  def test_runner_manifest_declares_the_observed_elapsed_time_api_reason
    privacy = Xcodeproj::Plist.read_from_path(MANIFEST)
    entries = privacy.fetch('NSPrivacyAccessedAPITypes')
    boot_time = entries.select do |entry|
      entry['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategorySystemBootTime'
    end
    assert_equal 1, boot_time.length
    assert_includes boot_time.first.fetch('NSPrivacyAccessedAPITypeReasons'), '35F9.1'
  end

  def test_manifest_is_a_single_runner_resource_and_not_a_source_file
    project = Xcodeproj::Project.open(ROOT.join('ios/Runner.xcodeproj'))
    runner = project.targets.find { |target| target.name == 'Runner' }
    ref = project.files.select { |file| file.real_path == MANIFEST }
    assert_equal 1, ref.length, 'Runner needs exactly one app-owned manifest reference'
    resources = runner.resources_build_phase.files_references.select { |file| file == ref.first }
    assert_equal 1, resources.length, 'A file reference alone does not bundle the manifest'
    refute_includes runner.source_build_phase.files_references, ref.first
    assert_equal ROOT.join('ios/Runner'), ref.first.parent.real_path
    assert MANIFEST.file?
  end

  def test_archived_app_contains_the_current_app_owned_manifest
    archive = ENV['MAASO_IOS_ARCHIVE']
    skip 'Set MAASO_IOS_ARCHIVE after a real Xcode archive to verify bundled resources' unless archive

    root = Pathname.new(archive)
    info = Xcodeproj::Plist.read_from_path(root.join('Info.plist'))
    app = root.join('Products', info.fetch('ApplicationProperties').fetch('ApplicationPath'))
    bundled = app.join('PrivacyInfo.xcprivacy')
    assert bundled.file?, 'SDK manifests do not replace the app-root manifest'
    assert_equal Xcodeproj::Plist.read_from_path(MANIFEST), Xcodeproj::Plist.read_from_path(bundled)
    assert app.join('Runner').file?
    assert app.join('Frameworks/UnityFramework.framework/UnityFramework').file?
    assert app.join('Frameworks/UnityFramework.framework/Data/Managed/Metadata/global-metadata.dat').file?
  end
end
