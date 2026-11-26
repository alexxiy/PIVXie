package pivxie.store

import android.app.Activity
import io.flutter.plugin.common.MethodChannel

/** Builds not for Google Play: no Play libraries, nothing to ask Play. */
object PlayStore {
    fun updateInfo(activity: Activity, result: MethodChannel.Result) =
        result.success(null)

    fun startUpdate(activity: Activity, result: MethodChannel.Result) =
        result.success(false)

    fun review(activity: Activity, result: MethodChannel.Result) =
        result.success(false)
}
