#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'xcodeproj'
require_relative 'xcode_project_sanitizer'

repo_root = Pathname.new(__dir__).join('../..').expand_path
runner_project_path = repo_root.join('ios/Runner.xcodeproj')
unity_project_path = repo_root.join('unity/masso_avatar/Builds/iOS/Unity-iPhone.xcodeproj')

unless unity_project_path.exist?
  warn "Unity iOS export not found: #{unity_project_path}"
  warn 'Export the masso_avatar Unity iOS Library before running this linker'
  exit 1
end

runner_project = Xcodeproj::Project.open(runner_project_path.to_s)
unity_project = Xcodeproj::Project.open(unity_project_path.to_s)

runner_target = runner_project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target not found' unless runner_target

unity_target = unity_project.targets.find { |target| target.name == 'UnityFramework' }
raise 'UnityFramework target not found' unless unity_target

unity_product = unity_target.product_reference
raise 'UnityFramework.framework product not found' unless unity_product

removed_build_phases =
  Maaso::Unity::XcodeProjectSanitizer.deduplicate_build_phases!(runner_project) +
  Maaso::Unity::XcodeProjectSanitizer.deduplicate_build_phases!(unity_project)
puts "Removed #{removed_build_phases} duplicate Xcode build phase reference(s)" if removed_build_phases.positive?

def ensure_unity_framework_data_resource!(unity_project, unity_target, unity_project_root)
  data_dir = unity_project_root.join('Data')
  metadata_path = data_dir.join('Managed/Metadata/global-metadata.dat')
  runtime_metadata_path = 'UnityFramework.framework/Data/Managed/Metadata/global-metadata.dat'
  resource_label = 'Data in Resources'

  raise "Unity Data folder not found: #{data_dir}" unless data_dir.directory?
  raise "Unity IL2CPP metadata missing for #{runtime_metadata_path}: #{metadata_path}" unless metadata_path.file?

  data_ref = unity_project.files.find do |file|
    file.display_name == 'Data' && file.path == 'Data'
  end

  unless data_ref
    data_ref = unity_project.main_group.new_file('Data')
    data_ref.last_known_file_type = 'folder'
    data_ref.source_tree = '<group>'
  end

  resources_phase = unity_target.resources_build_phase
  has_data_resource = resources_phase.files_references.any? do |file|
    file&.uuid == data_ref.uuid || (file&.display_name == 'Data' && file&.path == 'Data')
  end

  return if has_data_resource

  resources_phase.add_file_reference(data_ref, true)
  puts "Added #{resource_label} to UnityFramework so #{runtime_metadata_path} is bundled"
end

ensure_unity_framework_data_resource!(
  unity_project,
  unity_target,
  unity_project_path.dirname
)

def remove_build_files_named!(phase, display_name)
  phase.files.to_a.each do |build_file|
    file = build_file.file_ref
    next unless file&.display_name == display_name || file&.path == display_name

    build_file.remove_from_project
  end
end

def remove_stale_unity_framework_refs!(runner_project, runner_target)
  display_name = 'UnityFramework.framework'

  remove_build_files_named!(runner_target.frameworks_build_phase, display_name)

  unity_embed_phases = runner_target.copy_files_build_phases.select do |phase|
    phase.name == 'Embed Unity Frameworks'
  end
  unity_embed_phases.each { |phase| remove_build_files_named!(phase, display_name) }
  unity_embed_phases.drop(1).each do |phase|
    runner_target.build_phases.delete(phase)
    phase.remove_from_project
  end

  runner_target.dependencies.to_a.each do |dependency|
    next unless dependency.display_name == 'UnityFramework' ||
                dependency.name == 'UnityFramework' ||
                dependency.target_proxy&.remote_info == 'UnityFramework'

    dependency.target_proxy&.remove_from_project
    dependency.remove_from_project
  end

  runner_project.objects
                .grep(Xcodeproj::Project::Object::PBXReferenceProxy)
                .select { |proxy| proxy.path == display_name }
                .each do |proxy|
    proxy.remote_ref&.remove_from_project
    proxy.remove_from_project
  end

  runner_project.objects
                .grep(Xcodeproj::Project::Object::PBXContainerItemProxy)
                .select { |proxy| proxy.remote_info == 'UnityFramework' }
                .each(&:remove_from_project)
end

unity_project_relative_path = '../unity/masso_avatar/Builds/iOS/Unity-iPhone.xcodeproj'
legacy_unity_project_relative_path = 'unity/maaso_avatar/Builds/iOS/Unity-iPhone.xcodeproj'

unity_project_ref = runner_project.files.find do |file|
  file.path == unity_project_relative_path ||
    file.path == legacy_unity_project_relative_path ||
    file.path == 'Unity-iPhone.xcodeproj'
end

unless unity_project_ref
  # Xcodeproj opens new subprojects relative to the process cwd. Resolve the
  # real export first; store the portable relative path below.
  unity_project_ref = runner_project.main_group.new_file(unity_project_path.to_s)
  unity_project_ref.last_known_file_type = 'wrapper.pb-project'
  unity_project_ref.name = 'Unity-iPhone.xcodeproj'
end
unity_project_ref.path = unity_project_relative_path
unity_project_ref.name = 'Unity-iPhone.xcodeproj'

remove_stale_unity_framework_refs!(runner_project, runner_target)

products_group = runner_project.main_group.find_subpath('Unity Products', true)
products_group.set_source_tree('<group>')

framework_proxy = runner_project.objects
                                .grep(Xcodeproj::Project::Object::PBXReferenceProxy)
                                .find do |file|
  file.path == 'UnityFramework.framework' &&
    file.remote_ref&.remote_global_id_string == unity_product.uuid
end

unless framework_proxy
  container_proxy = runner_project.new(Xcodeproj::Project::Object::PBXContainerItemProxy)
  container_proxy.container_portal = unity_project_ref.uuid
  container_proxy.proxy_type = '2'
  container_proxy.remote_global_id_string = unity_product.uuid
  container_proxy.remote_info = 'UnityFramework'

  framework_proxy = runner_project.new(Xcodeproj::Project::Object::PBXReferenceProxy)
  framework_proxy.file_type = 'wrapper.framework'
  framework_proxy.path = 'UnityFramework.framework'
  framework_proxy.remote_ref = container_proxy
  framework_proxy.source_tree = 'BUILT_PRODUCTS_DIR'
  products_group << framework_proxy
end

unless runner_target.frameworks_build_phase.files_references.any? { |file| file&.display_name == 'UnityFramework.framework' }
  runner_target.frameworks_build_phase.add_file_reference(framework_proxy, true)
end

embed_phase = runner_target.copy_files_build_phases.find { |phase| phase.name == 'Embed Unity Frameworks' }
unless embed_phase
  embed_phase = runner_project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  embed_phase.name = 'Embed Unity Frameworks'
  embed_phase.dst_subfolder_spec = '10'
  runner_target.build_phases << embed_phase
end

unless embed_phase.files_references.any? { |file| file&.display_name == 'UnityFramework.framework' }
  build_file = embed_phase.add_file_reference(framework_proxy, true)
  build_file.settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }
end

thin_binary_phase = runner_target.build_phases.find { |phase| phase.display_name == 'Thin Binary' }
runner_target.build_phases.delete(embed_phase)
if thin_binary_phase
  runner_target.build_phases.insert(runner_target.build_phases.index(thin_binary_phase), embed_phase)
else
  runner_target.build_phases << embed_phase
end

unless runner_target.dependencies.any? { |dependency| dependency.display_name == 'UnityFramework' }
  target_proxy = runner_project.new(Xcodeproj::Project::Object::PBXContainerItemProxy)
  target_proxy.container_portal = unity_project_ref.uuid
  target_proxy.proxy_type = '1'
  target_proxy.remote_global_id_string = unity_target.uuid
  target_proxy.remote_info = 'UnityFramework'

  dependency = runner_project.new(Xcodeproj::Project::Object::PBXTargetDependency)
  dependency.name = 'UnityFramework'
  dependency.target_proxy = target_proxy
  runner_target.dependencies << dependency
end

unity_paths = [
  '$(inherited)',
  '$(PROJECT_DIR)/../unity/masso_avatar/Builds/iOS',
  '$(PROJECT_DIR)/../unity/masso_avatar/Builds/iOS/Frameworks',
  '$(PROJECT_DIR)/../unity/masso_avatar/Builds/iOS/UnityFramework'
]
legacy_unity_paths = [
  '$(PROJECT_DIR)/unity/maaso_avatar/Builds/iOS',
  '$(PROJECT_DIR)/unity/maaso_avatar/Builds/iOS/Frameworks',
  '$(PROJECT_DIR)/unity/maaso_avatar/Builds/iOS/UnityFramework',
  '$(PROJECT_DIR)/../unity/maaso_avatar/Builds/iOS',
  '$(PROJECT_DIR)/../unity/maaso_avatar/Builds/iOS/Frameworks',
  '$(PROJECT_DIR)/../unity/maaso_avatar/Builds/iOS/UnityFramework'
]

runner_target.build_configurations.each do |config|
  framework_search_paths =
    Array(config.build_settings['FRAMEWORK_SEARCH_PATHS']) - legacy_unity_paths
  header_search_paths =
    Array(config.build_settings['HEADER_SEARCH_PATHS']) - legacy_unity_paths
  runpath_search_paths = Array(config.build_settings['LD_RUNPATH_SEARCH_PATHS'])

  # Xcode builds a dependency's default configuration when the requested name
  # is absent. Unity exports Release/Debug, but Flutter also builds Profile.
  # Swift must find that dependency's module as well as linking its product;
  # otherwise canImport(UnityFramework) silently removes the runtime bridge.
  unless unity_target.build_configurations.any? { |unity_config| unity_config.name == config.name }
    fallback = unity_target.build_configuration_list.default_configuration_name
    unless unity_target.build_configurations.any? { |unity_config| unity_config.name == fallback }
      raise "UnityFramework has no valid default build configuration for #{config.name}"
    end
    framework_search_paths << "$(BUILD_DIR)/#{fallback}$(EFFECTIVE_PLATFORM_NAME)"
  end

  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = (framework_search_paths + unity_paths).uniq
  config.build_settings['HEADER_SEARCH_PATHS'] = (header_search_paths + unity_paths).uniq
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = (
    runpath_search_paths + ['$(inherited)', '@executable_path/Frameworks']
  ).uniq
end

unity_project.save
runner_project.save
puts "Linked Unity-iPhone.xcodeproj and UnityFramework.framework into #{runner_project_path}"
