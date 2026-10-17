//! Keep an initial macOS dial failure inside its owning helper briefly. This
//! does not identify NECP or distinguish other causes of an unreachable host.
//! Never apply this policy to an established session or a file operation.
use std::{future::Future, time::Duration};
use tokio::time::{sleep_until, Instant};

pub(super) async fn connect<T, F, Fut>(attempt: F) -> smb2::Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = smb2::Result<T>>,
{
    retry(attempt, Duration::from_secs(5), Duration::from_millis(200)).await
}

/// The monotonic window controls when another attempt may start. It does not
/// cut off an in-flight connect/authentication, whose existing timeouts apply.
/// There is no detached work: dropping this future also drops its wait/attempt.
async fn retry<T, F, Fut>(mut attempt: F, window: Duration, interval: Duration) -> smb2::Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = smb2::Result<T>>,
{
    let deadline = Instant::now() + window;
    loop {
        match attempt().await {
            Ok(value) => return Ok(value),
            Err(error) => {
                let now = Instant::now();
                if !is_initial_host_unreachable(&error) || now >= deadline {
                    return Err(error);
                }
                sleep_until(deadline.min(now + interval)).await;
                if Instant::now() >= deadline {
                    return Err(error);
                }
            }
        }
    }
}

fn is_initial_host_unreachable(error: &smb2::Error) -> bool {
    // smb2 0.31's dialer discards errno and retains ErrorKind per address.
    // Darwin EHOSTUNREACH (65) maps to HostUnreachable. Require every attempted
    // address to have failed that way; no timeouts, mixed errors or empty list.
    // ConnectFailed is returned by the dialer before SMB negotiate/login starts.
    #[cfg(target_os = "macos")]
    {
        matches!(error, smb2::Error::ConnectFailed { attempts, .. }
            if !attempts.is_empty() && attempts.iter().all(|attempt|
                attempt.error_kind == Some(std::io::ErrorKind::HostUnreachable)))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = error;
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{future, poll};
    use std::sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc,
    };

    fn dial_failure(kinds: &[Option<std::io::ErrorKind>]) -> smb2::Error {
        smb2::Error::ConnectFailed {
            host: "synthetic.invalid:445".to_owned(),
            attempts: kinds
                .iter()
                .map(|&error_kind| smb2::transport::ConnectAttempt {
                    addr: "192.0.2.1:445".parse().unwrap(),
                    error_kind,
                })
                .collect(),
        }
    }

    fn unreachable() -> smb2::Error {
        dial_failure(&[Some(std::io::ErrorKind::HostUnreachable)])
    }

    #[test]
    fn classification_is_macos_and_only_uniform_initial_dial_failures() {
        use std::io::ErrorKind as K;
        assert_eq!(
            is_initial_host_unreachable(&unreachable()),
            cfg!(target_os = "macos")
        );
        assert_eq!(
            is_initial_host_unreachable(&dial_failure(&[Some(K::HostUnreachable); 2])),
            cfg!(target_os = "macos")
        );
        for kinds in [
            vec![],
            vec![None],
            vec![Some(K::HostUnreachable), None],
            vec![Some(K::HostUnreachable), Some(K::ConnectionRefused)],
            vec![Some(K::NetworkUnreachable)],
            vec![Some(K::PermissionDenied)],
            vec![Some(K::TimedOut)],
        ] {
            assert!(!is_initial_host_unreachable(&dial_failure(&kinds)));
        }
        #[cfg(target_os = "macos")]
        assert_eq!(
            std::io::Error::from_raw_os_error(65).kind(),
            K::HostUnreachable
        );
    }

    #[tokio::test]
    async fn authentication_and_other_io_errors_are_returned_once() {
        let failures = [
            smb2::Error::Auth {
                message: "synthetic authentication failure".to_owned(),
            },
            smb2::Error::GuestSessionRefused {
                username: "synthetic".to_owned(),
                anonymous: false,
            },
            smb2::Error::Io(std::io::Error::from_raw_os_error(65)),
            smb2::Error::Io(std::io::ErrorKind::PermissionDenied.into()),
            smb2::Error::Timeout,
            smb2::Error::Disconnected,
        ];
        for failure in failures {
            let expected = failure.kind();
            let mut remaining = Some(failure);
            let mut calls = 0;
            let result: smb2::Result<()> = retry(
                || {
                    calls += 1;
                    future::ready(Err(remaining.take().unwrap()))
                },
                Duration::from_secs(5),
                Duration::from_secs(1),
            )
            .await;
            assert_eq!(result.unwrap_err().kind(), expected);
            assert_eq!(calls, 1);
        }
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn transient_dial_failures_can_recover_without_replaying_success() {
        let mut calls = 0;
        let result = retry(
            || {
                calls += 1;
                future::ready(if calls < 3 {
                    Err(unreachable())
                } else {
                    Ok(71)
                })
            },
            Duration::from_secs(5),
            Duration::from_millis(1),
        )
        .await
        .unwrap();
        assert_eq!(result, 71);
        assert_eq!(calls, 3);
    }

    #[tokio::test]
    async fn exhausted_window_preserves_the_real_failure_without_an_extra_attempt() {
        let mut calls = 0;
        let failure: smb2::Result<()> = retry(
            || {
                calls += 1;
                future::ready(Err(unreachable()))
            },
            Duration::ZERO,
            Duration::from_secs(1),
        )
        .await;
        assert_eq!(calls, 1);
        assert!(
            matches!(failure, Err(smb2::Error::ConnectFailed { host, attempts })
            if host == "synthetic.invalid:445" && attempts.len() == 1)
        );
        // The eligibility window is not an in-flight deadline.
        let value = retry(
            || async {
                tokio::task::yield_now().await;
                Ok::<_, smb2::Error>(19)
            },
            Duration::ZERO,
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        assert_eq!(value, 19);
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn positive_window_waits_until_deadline_without_starting_another_attempt() {
        let mut calls = 0;
        let started = Instant::now();
        let window = Duration::from_millis(10);
        let failure: smb2::Result<()> = retry(
            || {
                calls += 1;
                future::ready(Err(unreachable()))
            },
            window,
            Duration::from_secs(5),
        )
        .await;
        assert!(started.elapsed() >= window);
        assert_eq!(calls, 1);
        assert!(
            matches!(failure, Err(smb2::Error::ConnectFailed { host, attempts })
            if host == "synthetic.invalid:445" && attempts.len() == 1)
        );
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn cancellation_drops_the_retry_wait_without_a_background_worker() {
        let calls = Arc::new(AtomicUsize::new(0));
        let cancel = crate::CancellationToken::new();
        let mut operation = Box::pin(async {
            tokio::select! {
                biased;
                _ = cancel.cancelled() => Err(crate::Error::Cancelled),
                result = retry(|| {
                    calls.fetch_add(1, Ordering::SeqCst);
                    future::ready(Err::<(), _>(unreachable()))
                }, Duration::from_secs(5), Duration::from_secs(1)) => result.map_err(crate::Error::from),
            }
        });
        assert!(poll!(operation.as_mut()).is_pending());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        cancel.cancel();
        assert!(matches!(operation.await, Err(crate::Error::Cancelled)));
        tokio::task::yield_now().await;
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn dropping_an_inflight_connect_drops_its_owned_state() {
        struct Owned(Arc<AtomicBool>);
        impl Drop for Owned {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let dropped = Arc::new(AtomicBool::new(false));
        let mut operation = Box::pin(connect(|| {
            let owned = Owned(dropped.clone());
            async move {
                let _owned = owned;
                future::pending::<smb2::Result<()>>().await
            }
        }));
        assert!(poll!(operation.as_mut()).is_pending());
        drop(operation);
        assert!(dropped.load(Ordering::SeqCst));
    }
}
