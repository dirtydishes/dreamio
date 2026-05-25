platform :ios, '16.0'

target 'Dreamio' do
  use_frameworks!

  pod 'MobileVLCKit'
end

post_install do |_installer|
  project = Xcodeproj::Project.open('Dreamio.xcodeproj')
  target = project.targets.find { |candidate| candidate.name == 'Dreamio' }
  next unless target

  target.frameworks_build_phase.files.delete_if do |build_file|
    build_file.file_ref&.display_name == 'Pods_Dreamio.framework'
  end

  phase_name = '[CP] Prepare MobileVLCKit XCFramework'
  phase = target.shell_script_build_phases.find { |candidate| candidate.name == phase_name }
  phase ||= target.new_shell_script_build_phase(phase_name)
  phase.shell_script = <<~SH
    if [ -x "${PODS_ROOT}/Target Support Files/MobileVLCKit/MobileVLCKit-xcframeworks.sh" ]; then
      "${PODS_ROOT}/Target Support Files/MobileVLCKit/MobileVLCKit-xcframeworks.sh"
    else
      echo "error: MobileVLCKit is missing. Run 'pod install' and open Dreamio.xcworkspace, or rebuild after Pods are installed." >&2
      exit 1
    fi
  SH
  phase.input_file_list_paths = [
    '${PODS_ROOT}/Target Support Files/MobileVLCKit/MobileVLCKit-xcframeworks-input-files.xcfilelist'
  ]
  phase.output_file_list_paths = []

  check_phase = target.shell_script_build_phases.find { |candidate| candidate.name == '[CP] Check Pods Manifest.lock' }
  if check_phase
    target.build_phases.delete(phase)
    insert_index = target.build_phases.index(check_phase) + 1
    target.build_phases.insert(insert_index, phase)
  end

  project.save
end
