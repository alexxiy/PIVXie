Pod::Spec.new do |s|
  s.name             = 'flutter_libpivxshield'
  s.version          = '0.1.0'
  s.summary          = 'PIVX Shield (Sapling) wallet core.'
  s.description      = 'Rust port of PIVX-Labs/pivx-shield exposed through a C ABI.'
  s.homepage         = 'https://pivx.org'
  s.license          = { :type => 'MIT' }
  s.author           = { 'PIVX' => 'dev@pivx.org' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # Relative path to the rust crate, then the crate's library name.
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../rust pivx_shield_ffi',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    :output_files => ["${BUILT_PRODUCTS_DIR}/libpivx_shield_ffi.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'EXCLUDED_ARCHS' => 'armv7',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/libpivx_shield_ffi.a',
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS' => 'armv7',
  }
end
