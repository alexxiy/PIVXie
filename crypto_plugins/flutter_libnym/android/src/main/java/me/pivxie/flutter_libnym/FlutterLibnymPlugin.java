package me.pivxie.flutter_libnym;

import android.content.Context;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Android setup for the Nym library; everything else goes through dart:ffi.
 *
 * <p>The Nym client checks TLS certificates against Android's trust store
 * through rustls-platform-verifier, which needs the app context. On the
 * first start ("init") this loads the library and hands the context over,
 * so nothing is loaded for people who don't use Nym.
 */
public class FlutterLibnymPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private Context context;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "flutter_libnym");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (!"init".equals(call.method)) {
            result.notImplemented();
            return;
        }
        try {
            System.loadLibrary("nym_socks_ffi");
            result.success(nativeInit(context));
        } catch (Throwable t) {
            result.error("init", t.toString(), null);
        }
    }

    private native boolean nativeInit(Context context);
}
