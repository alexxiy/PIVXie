package pivxie.store

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * PIVXIE_STORE: app updates and store reviews. Google Play's part is in
 * [PlayStore] (a stub in builds not for Play); GitHub builds install the
 * APK the app downloaded and checked.
 */
class StoreChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val statusAction = "${activity.packageName}.UPDATE_STATUS"

    /** The installApk call waiting for Android's answer. */
    private var pending: MethodChannel.Result? = null
    private var receiver: BroadcastReceiver? = null

    /**
     * Sent along with Android's answers. Before Android 13 any app can
     * send to the receiver, so answers without it are ignored (one could
     * otherwise make the app open a screen of its choosing).
     */
    private var token = ""

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "playUpdateInfo" -> PlayStore.updateInfo(activity, result)
            "playStartUpdate" -> PlayStore.startUpdate(activity, result)
            "playReview" -> PlayStore.review(activity, result)
            "installApk" -> installApk(call.argument<String>("path"), result)
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        receiver?.let { activity.unregisterReceiver(it) }
        receiver = null
        finish("aborted")
        io.shutdown()
    }

    /**
     * Answers "permission" after opening Android's "install unknown apps"
     * setting for the app, else once Android is done: "done", "aborted"
     * (turned down) or "failed" (for example, signed by someone else).
     */
    private fun installApk(path: String?, result: MethodChannel.Result) {
        // Only the file the app downloaded into its own cache.
        val file = path?.let { File(it).canonicalFile }
        val cache = activity.cacheDir.canonicalPath + File.separator
        if (file == null || !file.path.startsWith(cache) || !file.isFile) {
            result.error("ARGS", "No update file", null)
            return
        }
        if (Build.VERSION.SDK_INT >= 26 &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
            result.success("permission")
            return
        }
        finish("aborted")
        pending = result
        token = UUID.randomUUID().toString()
        val answerToken = token
        listen()
        io.execute {
            try {
                val installer = activity.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(
                    PackageInstaller.SessionParams.MODE_FULL_INSTALL,
                ).apply { setAppPackageName(activity.packageName) }
                val id = installer.createSession(params)
                installer.openSession(id).use { session ->
                    session.openWrite("update.apk", 0, file.length()).use { out ->
                        file.inputStream().use { it.copyTo(out) }
                        session.fsync(out)
                    }
                    var flags = PendingIntent.FLAG_UPDATE_CURRENT
                    if (Build.VERSION.SDK_INT >= 31) flags = flags or PendingIntent.FLAG_MUTABLE
                    val status = PendingIntent.getBroadcast(
                        activity,
                        id,
                        Intent(statusAction)
                            .setPackage(activity.packageName)
                            .putExtra("token", answerToken),
                        flags,
                    )
                    session.commit(status.intentSender)
                }
            } catch (e: Exception) {
                main.post { finish("failed") }
            }
        }
    }

    /** Android's answers about the install, for this app only. */
    private fun listen() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (pending == null || intent.getStringExtra("token") != token) return
                val status = intent.getIntExtra(
                    PackageInstaller.EXTRA_STATUS,
                    PackageInstaller.STATUS_FAILURE,
                )
                when (status) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        val confirm = if (Build.VERSION.SDK_INT >= 33) {
                            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(Intent.EXTRA_INTENT)
                        }
                        if (confirm == null) {
                            finish("failed")
                        } else {
                            // Android's own "update this app?" screen.
                            activity.startActivity(confirm)
                        }
                    }
                    PackageInstaller.STATUS_SUCCESS -> finish("done")
                    PackageInstaller.STATUS_FAILURE_ABORTED -> finish("aborted")
                    else -> finish("failed")
                }
            }
        }
        val filter = IntentFilter(statusAction)
        if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            activity.registerReceiver(r, filter)
        }
        receiver = r
    }

    private fun finish(answer: String) {
        val result = pending ?: return
        pending = null
        result.success(answer)
    }
}
