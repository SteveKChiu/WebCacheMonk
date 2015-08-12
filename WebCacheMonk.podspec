Pod::Spec.new do |s|

  s.name         = "WebCacheMonk"
  s.version      = "0.9"

  s.summary      = "A generic and extensible web cache library for Swift"
  s.description  = <<-DESC
      WebCacheMonk is a generic and extensible web cache library for Swift

      + Allow you to fetch data from web site and store it into cache automatically
      + Allow you to create cache by combing different store layers (memory, file or your own layer)
      + Allow you to cache Swift object
      + UIImageView extension for image cache with simple URL loading
  DESC

  s.homepage     = "https://github.com/SteveKChiu/WebCacheMonk"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "Steve K. Chiu" => "steve.k.chiu@gmail.com" }

  s.ios.deployment_target = "8.0"
  s.source       = { :git => "https://github.com/SteveKChiu/WebCacheMonk.git", :tag => "v" + s.version.to_s }
  s.source_files = "WebCacheMonk", "WebCacheMonk/**/*.{swift}"
  s.frameworks   = "Foundation", "UIKit"
  s.requires_arc = true

end
