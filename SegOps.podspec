Pod::Spec.new do |s|
  s.name             = 'SegOps'
  s.version          = '0.1.0'
  s.summary          = 'SegOps behavioral segmentation SDK for Apple platforms.'
  s.description      = <<-DESC
    Thread-safe SegOps event client with automatic batching and the public-key
    session handshake. Ship a public key (pk_) safely in your app; it is
    exchanged for a short-lived session token. Zero dependencies.
  DESC
  s.homepage         = 'https://github.com/segops/sdk-swift'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'SegOps' => 'support@segops.ai' }

  # Source lives in the published mirror repo; the tag matches the release
  # (the release-sdks.yml mirror job tags sdk-swift as v<version>).
  s.source           = { :git => 'https://github.com/segops/sdk-swift.git', :tag => "v#{s.version}" }

  s.swift_version            = '5.9'
  s.ios.deployment_target    = '16.0'
  s.osx.deployment_target    = '13.0'
  s.watchos.deployment_target = '9.0'
  s.tvos.deployment_target   = '16.0'

  s.source_files     = 'Sources/SegOps/**/*.swift'
  s.frameworks       = 'Foundation'
end
