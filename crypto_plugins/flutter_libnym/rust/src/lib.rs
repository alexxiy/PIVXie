//! A Nym mixnet SOCKS5 client for the app, with a small C interface.
//!
//! The app sends its requests through a local SOCKS5 proxy, as with Tor.
//! [nym_start] connects to the mixnet and opens that proxy on a free
//! local port; requests then leave the mixnet at an exit gateway's
//! network requester, which does the DNS lookup too.

use std::ffi::{c_char, CString};
use std::net::{SocketAddr, TcpListener};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use nym_sdk::mixnet::{NetworkRequesterSelector, Socks5MixnetClient};
use tokio::runtime::Runtime;
use tokio::sync::oneshot;

static CLIENT: Mutex<Option<Socks5MixnetClient>> = Mutex::new(None);
static CANCEL: Mutex<Option<oneshot::Sender<()>>> = Mutex::new(None);
static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("nym")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

fn set_error(message: String) {
    let text = CString::new(message.replace('\0', " ")).unwrap_or_default();
    *LAST_ERROR.lock().unwrap() = Some(text);
}

/// A port nothing listens on now; the client opens its proxy there.
fn free_port() -> std::io::Result<u16> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    Ok(listener.local_addr()?.port())
}

fn stop_client() {
    let client = CLIENT.lock().unwrap().take();
    if let Some(client) = client {
        runtime().block_on(client.disconnect());
    }
}

/// Connects to the mixnet and opens the local SOCKS5 proxy.
///
/// Blocks until connected, so call it off the UI thread. Returns the
/// proxy's port, 0 when [nym_stop] cancelled it, or -1 on failure
/// (see [nym_last_error]). A client from an earlier start is stopped
/// first.
#[no_mangle]
pub extern "C" fn nym_start(timeout_secs: u32) -> i32 {
    stop_client();
    *LAST_ERROR.lock().unwrap() = None;

    let port = match free_port() {
        Ok(port) => port,
        Err(e) => {
            set_error(format!("no free local port: {e}"));
            return -1;
        }
    };
    let address = SocketAddr::from(([127, 0, 0, 1], port));

    let (cancel_tx, cancel_rx) = oneshot::channel::<()>();
    *CANCEL.lock().unwrap() = Some(cancel_tx);

    let result = runtime().block_on(async {
        tokio::select! {
            connected = tokio::time::timeout(
                Duration::from_secs(timeout_secs.max(1) as u64),
                Socks5MixnetClient::connect_with(NetworkRequesterSelector::any(), Some(address)),
            ) => Some(connected),
            _ = cancel_rx => None,
        }
    });
    CANCEL.lock().unwrap().take();

    match result {
        None => 0,
        Some(Ok(Ok(client))) => {
            *CLIENT.lock().unwrap() = Some(client);
            port as i32
        }
        Some(Ok(Err(e))) => {
            set_error(format!("{e}"));
            -1
        }
        Some(Err(_)) => {
            set_error("connecting to the Nym mixnet timed out".to_string());
            -1
        }
    }
}

/// Cancels a start in progress and closes the proxy.
#[no_mangle]
pub extern "C" fn nym_stop() {
    if let Some(cancel) = CANCEL.lock().unwrap().take() {
        let _ = cancel.send(());
    }
    stop_client();
}

/// Whether a client is connected and its proxy open.
#[no_mangle]
pub extern "C" fn nym_is_running() -> bool {
    CLIENT.lock().unwrap().is_some()
}

/// The last start's error, or null. Valid until the next start.
#[no_mangle]
pub extern "C" fn nym_last_error() -> *const c_char {
    match LAST_ERROR.lock().unwrap().as_ref() {
        Some(text) => text.as_ptr(),
        None => std::ptr::null(),
    }
}

/// Android: hands the app context to rustls-platform-verifier, which the
/// Nym API client uses to check TLS certificates against the system's trust
/// store. Without it every HTTPS call fails. Called by FlutterLibnymPlugin
/// when the plugin attaches; repeated calls do nothing.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_me_pivxie_flutter_1libnym_FlutterLibnymPlugin_nativeInit<'caller>(
    mut env: jni::EnvUnowned<'caller>,
    _this: jni::objects::JObject<'caller>,
    context: jni::objects::JObject<'caller>,
) -> jni::sys::jboolean {
    let outcome = env
        .with_env(|env| rustls_platform_verifier::android::init_with_env(env, context))
        .into_outcome();
    match outcome {
        jni::Outcome::Ok(()) => true,
        jni::Outcome::Err(e) => {
            set_error(format!("TLS verifier setup failed: {e}"));
            false
        }
        jni::Outcome::Panic(_) => {
            set_error("TLS verifier setup failed".to_string());
            false
        }
    }
}
