Pod::Spec.new do |s|
  s.name             = 'frappe_mobile_sdk'
  s.version          = '2.0.0'
  s.summary          = 'Flutter SDK for offline-first Frappe/ERPNext mobile apps.'
  s.description      = <<-DESC
    Flutter SDK providing auth, API access, dynamic forms, and sync-aware offline
    data operations for Frappe/ERPNext backends.
  DESC
  s.homepage         = 'https://github.com/dhwani-ris/frappe-mobile-sdk'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Dhwani RIS' => 'info@dhwaniris.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'frappe_mobile_sdk/Sources/frappe_mobile_sdk/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version    = '5.0'
end
