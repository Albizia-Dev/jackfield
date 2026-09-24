Pod::Spec.new do |s|
  s.name             = 'jackfield'
  s.version          = '0.0.1'
  s.summary          = 'Durable call notifications for Flutter on macOS.'
  s.description      = <<-DESC
Jackfield connects a Flutter call lifecycle to macOS notifications, durable
local events, and optional HTTPS callbacks. The host owns signaling and media.
                       DESC
  s.homepage         = 'https://github.com/Albizia-Dev/jackfield'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'Albizia-Dev'

  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '11.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.9'
  s.frameworks = 'UserNotifications', 'Security'
  s.libraries = 'sqlite3'
end
