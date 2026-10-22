package com.place.holder

import androidx.activity.enableEdgeToEdge
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterFragmentActivity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.Executors
class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL = "STACK_WALLET_RESTORE"
    private val CLIPBOARD_CHANNEL = "PIVXIE_CLIPBOARD"

    /** An opened backup file, read when Flutter asks for it. */
    private var openUri: Uri? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getOpenFile" -> {
                    // Taken once: a second call (start and resume both
                    // ask) doesn't open the same file again.
                    val uri = openUri
                    openUri = null
                    if (uri == null) {
                        result.success(null)
                    } else {
                        // Off the UI thread: a provider can be slow (a
                        // cloud file is downloaded first).
                        io.execute {
                            val text = readBackup(uri)
                            main.post { result.success(text) }
                        }
                    }
                }
                "resetOpenPath" -> {
                    openUri = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLIPBOARD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecret" -> {
                        val text = call.argument<String>("text")
                        if (text == null) {
                            result.error("ARGS", "No text", null)
                        } else {
                            setSecretClip(text)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Copies [text] marked as sensitive: Android 13 and later hide it in
     * the copy preview, and keyboards keep it out of their clipboard
     * history.
     */
    private fun setSecretClip(text: String) {
        val clip = ClipData.newPlainText("", text)
        clip.description.extras = PersistableBundle().apply {
            // ClipDescription.EXTRA_IS_SENSITIVE (API 33), which keyboards
            // also read on older versions.
            putBoolean("android.content.extra.IS_SENSITIVE", true)
        }
        (getSystemService(CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip)
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

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    // An opened backup file: a content: link, as file managers and
    // pickers send (never a file: path, which could name the app's own
    // files). Other links (pivx: payments) are app_links'.
    private fun handleOpenFile(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "content") return
        openUri = uri
    }

    private fun readBackup(uri: Uri): String? = try {
        contentResolver.openInputStream(uri)?.use { it.readTextUpTo(MAX_BACKUP_BYTES) }
    } catch (e: Exception) {
        null
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
