Pod::Spec.new do |s|
  s.name             = 'jackfield'
  s.version          = '0.0.1'
  s.summary          = 'Durable system call presentation for Flutter on iOS.'
  s.description      = <<-DESC
Jackfield connects a Flutter call lifecycle to CallKit, durable local events,
and optional HTTPS callbacks. The host application owns signaling and media.
                       DESC
  s.homepage         = 'https://github.com/Albizia-Dev/jackfield'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'Albizia-Dev'
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
  s.frameworks = 'CallKit', 'PushKit', 'Security'
  s.libraries = 'sqlite3'

end
