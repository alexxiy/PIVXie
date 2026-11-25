Pod::Spec.new do |s|
  s.name             = 'flutter_libnym'
  s.version          = '0.1.0'
  s.summary          = 'Nym mixnet SOCKS5 client.'
  s.description      = 'nym-sdk SOCKS5 client exposed through a C ABI.'
  s.homepage         = 'https://pivxie.me'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'PIVXie' => 'support@pivxie.me' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # Relative path to the rust crate, then the crate's library name.
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../rust nym_socks_ffi',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    :output_files => ["${BUILT_PRODUCTS_DIR}/libnym_socks_ffi.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'EXCLUDED_ARCHS' => 'armv7',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/libnym_socks_ffi.a',
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS' => 'armv7',
  }
end
