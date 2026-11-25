# Called from Rust over JNI: keep the names.
-keepclasseswithmembernames class me.pivxie.flutter_libnym.FlutterLibnymPlugin {
    native <methods>;
}
-keep class org.rustls.platformverifier.** { *; }
