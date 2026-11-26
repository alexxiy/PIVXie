package pivxie.store

import android.app.Activity
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.UpdateAvailability
import com.google.android.play.core.review.ReviewManagerFactory
import io.flutter.plugin.common.MethodChannel

/** Google Play builds: Play's in-app updates and reviews. */
object PlayStore {
    /** Whether Play has a newer version that can be installed right away. */
    fun updateInfo(activity: Activity, result: MethodChannel.Result) {
        AppUpdateManagerFactory.create(activity).appUpdateInfo
            .addOnSuccessListener { info ->
                result.success(
                    mapOf(
                        "available" to (
                            info.updateAvailability() ==
                                UpdateAvailability.UPDATE_AVAILABLE &&
                                info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)
                            ),
                    ),
                )
            }
            .addOnFailureListener { e -> result.error("PLAY", e.message, null) }
    }

    /** Play's full-screen update; the app restarts updated. */
    fun startUpdate(activity: Activity, result: MethodChannel.Result) {
        val manager = AppUpdateManagerFactory.create(activity)
        // Asked again: an AppUpdateInfo starts one flow only.
        manager.appUpdateInfo
            .addOnSuccessListener { info ->
                if (info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE ||
                    info.updateAvailability() ==
                    UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS
                ) {
                    manager.startUpdateFlow(
                        info,
                        activity,
                        AppUpdateOptions.defaultOptions(AppUpdateType.IMMEDIATE),
                    )
                    result.success(true)
                } else {
                    result.success(false)
                }
            }
            .addOnFailureListener { e -> result.error("PLAY", e.message, null) }
    }

    /** Play's review sheet. Play decides whether it shows. */
    fun review(activity: Activity, result: MethodChannel.Result) {
        val manager = ReviewManagerFactory.create(activity)
        manager.requestReviewFlow().addOnCompleteListener { request ->
            if (!request.isSuccessful) {
                result.success(false)
                return@addOnCompleteListener
            }
            manager.launchReviewFlow(activity, request.result)
                .addOnCompleteListener { result.success(true) }
        }
    }
}
