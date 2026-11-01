# frozen_string_literal: true

require 'minitest/autorun'
require 'xcodeproj'

sanitizer_path = File.expand_path(
  '../../../tool/unity/xcode_project_sanitizer.rb',
  __dir__
)
require sanitizer_path if File.file?(sanitizer_path)

class XcodeProjectSanitizerTest < Minitest::Test
  def test_deduplicates_repeated_build_phase_references
    project = Xcodeproj::Project.new('/private/tmp/maaso-sanitizer-fixture.xcodeproj')
    target = project.new_target(:static_library, 'GameAssembly', :ios, '15.5')
    script_phase = project.new(
      Xcodeproj::Project::Object::PBXShellScriptBuildPhase
    )
    script_phase.name = 'Run Script'
    target.build_phases << script_phase
    target.build_phases << script_phase

    if defined?(Maaso::Unity::XcodeProjectSanitizer)
      Maaso::Unity::XcodeProjectSanitizer.deduplicate_build_phases!(project)
    end

    phase_ids = target.build_phases.map(&:uuid)
    assert_equal 1, phase_ids.count(script_phase.uuid)
    assert_includes phase_ids, target.source_build_phase.uuid
    assert_includes phase_ids, target.frameworks_build_phase.uuid
  end
end
