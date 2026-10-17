package com.place.holder

import androidx.activity.enableEdgeToEdge
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterFragmentActivity
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.ByteArrayOutputStream
import java.io.InputStream
import android.os.Build
import android.view.ViewTreeObserver
import android.view.WindowManager
class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL = "STACK_WALLET_RESTORE"

    var openPath: String? = null
    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getOpenFile" -> {
                    result.success(openPath)
                }
                "resetOpenPath" -> {
                    resetOpenPath()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun resetOpenPath() {
        openPath = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw behind the status and navigation bars on every Android
        // version, as Android 15 and later always do. Flutter tells the
        // screens how much room the bars take (SafeArea).
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handleOpenFile(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleOpenFile(intent)
    }

    // An opened backup file: a content: link, as file managers and
    // pickers send (never a file: path, which could name the app's own
    // files). Other links (pivx: payments) are app_links'.
    private fun handleOpenFile(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "content") return
        openPath = try {
            contentResolver.openInputStream(uri)?.use { it.readTextUpTo(MAX_BACKUP_BYTES) }
        } catch (e: Exception) {
            null
        }
    }

    /** The stream as UTF-8 text; null when it's longer than [max] bytes. */
    private fun InputStream.readTextUpTo(max: Int): String? {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val n = read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
            if (out.size() > max) return null
        }
        return out.toString(Charsets.UTF_8.name())
    }

    companion object {
        /** Far more than any backup file. */
        private const val MAX_BACKUP_BYTES = 16 * 1024 * 1024
    }
}