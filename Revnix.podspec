Pod::Spec.new do |s|
  s.name             = 'Revnix'
  s.version          = '0.2.0'
  s.summary          = 'Native Swift SDK for Revnix — StoreKit 2 purchases and offline-correct entitlements.'

  s.description      = <<-DESC
    StoreKit 2 purchase glue plus an offline-correct entitlement cache: a
    network blip keeps paying customers unlocked, while a revoked key still
    locks them out. One call from tap to unlocked gate, with the JWS as
    server-verifiable proof.
  DESC

  s.homepage         = 'https://github.com/Oth-tech/revnix-swift'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Oth Tech' => 'support@revnix.com' }
  s.source           = { :git => 'https://github.com/Oth-tech/revnix-swift.git', :tag => s.version.to_s }
  s.documentation_url = 'https://revnix.com/docs/ios'

  s.swift_versions   = ['5.9']
  s.ios.deployment_target     = '16.0'
  s.osx.deployment_target     = '13.0'
  s.tvos.deployment_target    = '16.0'
  s.watchos.deployment_target = '9.0'

  s.source_files     = 'Sources/Revnix/**/*.swift'
  s.frameworks       = 'Foundation', 'StoreKit'
end
