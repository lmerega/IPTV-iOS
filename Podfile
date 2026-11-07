platform :ios, '18.0'
project 'IPTVPOC.xcodeproj'
install! 'cocoapods', :integrate_targets => true

target 'IPTVPOC' do
  use_frameworks!
  pod 'MobileVLCKit', '3.6.0'
  target 'IPTVPOCTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end
