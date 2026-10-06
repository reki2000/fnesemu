#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint mp_bigfile_picker.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'mp_bigfile_picker'
  s.version          = '0.1.0'
  s.summary          = 'Picks a directory and reads its files at any offset without copying.'
  s.description      = <<-DESC
Picks a directory and reads its files at any offset without copying.
                       DESC
  s.homepage         = 'https://github.com/reki2000/fnesemu'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'reki2000' => '' }
  s.source           = { :path => '.' }
  s.source_files = 'mp_bigfile_picker/Sources/mp_bigfile_picker/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'mp_bigfile_picker_privacy' => ['mp_bigfile_picker/Sources/mp_bigfile_picker/PrivacyInfo.xcprivacy']}
end
