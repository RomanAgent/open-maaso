# frozen_string_literal: true

module Maaso
  module Unity
    module XcodeProjectSanitizer
      module_function

      def deduplicate_build_phases!(project)
        project.targets.sum do |target|
          original_count = target.build_phases.length
          target.build_phases.uniq!
          original_count - target.build_phases.length
        end
      end
    end
  end
end
