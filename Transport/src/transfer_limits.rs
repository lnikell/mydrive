//! A shared reservation clock bounds aggregate bandwidth across this app's
//! helper processes. Default transfers do no clock-file I/O or waiting.
use crate::{CancellationToken, Error, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs::OpenOptions,
    future::Future,
    io::{Read, Seek, SeekFrom, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::Path,
    time::Duration,
};

const MIN_RATE: u64 = 100_000;
const MAX_RATE: u64 = 10_000_000_000;
const MAX_RESERVATION_BYTES: u64 = 1_048_576;
const CLOCK_MAGIC: &[u8; 8] = b"MYDRATE2";

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TransferLimits {
    pub download_bps: Option<u64>,
    pub upload_bps: Option<u64>,
    pub directory: Option<String>,
}

tokio::task_local! { static LIMITS: TransferLimits; }

impl TransferLimits {
    pub fn validate(&self) -> Result<()> {
        if [self.download_bps, self.upload_bps]
            .into_iter()
            .flatten()
            .any(|rate| !(MIN_RATE..=MAX_RATE).contains(&rate))
            || self.directory.as_ref().is_some_and(|path| {
                path.len() > 4096 || path.contains('\0') || !Path::new(path).is_absolute()
            })
            || (self.download_bps.is_some() || self.upload_bps.is_some())
                && self.directory.is_none()
        {
            return Err(Error::Input("invalid transfer limits"));
        }
        Ok(())
    }

    pub async fn scope<T>(&self, operation: impl Future<Output = T>) -> T {
        LIMITS.scope(self.clone(), operation).await
    }
}

pub(crate) async fn wait(upload: bool, bytes: u64, cancel: &CancellationToken) -> Result<()> {
    let limit = LIMITS
        .try_with(|limits| {
            let rate = if upload {
                limits.upload_bps
            } else {
                limits.download_bps
            }?;
            Some((rate, limits.directory.clone()?))
        })
        .ok()
        .flatten();
    let Some((rate, directory)) = limit else {
        return Ok(());
    };
    loop {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let delay = reserve(&directory, upload, rate, bytes)?;
        if delay.is_zero() {
            return Ok(());
        }
        tokio::select! { biased;
            _ = cancel.cancelled() => return Err(Error::Cancelled),
            _ = tokio::time::sleep(delay) => (),
        }
    }
}

fn reserve(directory: &str, upload: bool, rate: u64, bytes: u64) -> Result<Duration> {
    if !(MIN_RATE..=MAX_RATE).contains(&rate) || bytes > MAX_RESERVATION_BYTES {
        return Err(Error::Input("invalid bandwidth reservation"));
    }
    let path = Path::new(directory).join(if upload {
        ".bandwidth-upload"
    } else {
        ".bandwidth-download"
    });
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(Error::Input("invalid bandwidth clock"));
    }
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // Closing the descriptor releases the lock on every error path.
    let now = monotonic_nanos()?;
    let mut saved = [0u8; 32];
    let read = file.read(&mut saved)?;
    let previous_rate = u64::from_le_bytes(saved[8..16].try_into().unwrap());
    let previous_next = u128::from_le_bytes(saved[16..].try_into().unwrap());
    let longest_slot = u128::from(MAX_RESERVATION_BYTES) * 1_000_000_000 / u128::from(MIN_RATE) + 1;
    let valid = read == saved.len()
        && &saved[..8] == CLOCK_MAGIC
        && (MIN_RATE..=MAX_RATE).contains(&previous_rate)
        && previous_next <= now + longest_slot;
    // Waiters do not reserve arbitrarily distant future slots. Only one chunk
    // owns the clock; every contender rechecks it under the same process-shared
    // lock after sleeping. Capping a long reservation queue would permit a
    // burst of overlapping transfers and violate the aggregate limit.
    if valid && previous_next > now {
        return Ok(Duration::from_nanos((previous_next - now) as u64));
    }
    let duration = (u128::from(bytes) * 1_000_000_000).div_ceil(u128::from(rate));
    file.seek(SeekFrom::Start(0))?;
    file.write_all(CLOCK_MAGIC)?;
    file.write_all(&rate.to_le_bytes())?;
    file.write_all(&(now + duration).to_le_bytes())?;
    file.set_len(saved.len() as u64)?;
    Ok(Duration::ZERO)
}

fn monotonic_nanos() -> Result<u128> {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if time.tv_sec < 0 || !(0..1_000_000_000).contains(&time.tv_nsec) {
        return Err(Error::Input("invalid monotonic clock"));
    }
    Ok(time.tv_sec as u128 * 1_000_000_000 + time.tv_nsec as u128)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_limits_and_shares_one_reservation_clock() {
        assert!(TransferLimits {
            download_bps: Some(0),
            ..Default::default()
        }
        .validate()
        .is_err());
        let directory = std::env::temp_dir().join(format!("mydrive-rate-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.to_str().unwrap();
        assert!(reserve(path, false, 1_000_000, 10_000).unwrap() < Duration::from_millis(5));
        assert!(reserve(path, false, 1_000_000, 10_000).unwrap() >= Duration::from_millis(5));
        assert!(reserve(path, true, 1_000_000, 10_000).unwrap() < Duration::from_millis(5));
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[tokio::test]
    async fn cancellation_does_not_wait_for_reserved_bandwidth() {
        let directory =
            std::env::temp_dir().join(format!("mydrive-rate-cancel-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let limits = TransferLimits {
            upload_bps: Some(1),
            directory: Some(directory.to_str().unwrap().into()),
            ..Default::default()
        };
        let cancel = CancellationToken::new();
        cancel.cancel();
        assert!(matches!(
            limits.scope(wait(true, 1_000_000, &cancel)).await,
            Err(Error::Cancelled)
        ));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn queued_transfers_do_not_burst_after_ten_seconds() {
        let directory =
            std::env::temp_dir().join(format!("mydrive-rate-waiters-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let limits = TransferLimits {
            upload_bps: Some(100_000),
            directory: Some(directory.to_str().unwrap().into()),
            ..Default::default()
        };
        let started = std::time::Instant::now();
        let mut tasks = tokio::task::JoinSet::new();
        // This queue exceeds the old ten-second reservation cap. Limiting
        // future timestamps used to let its tail send several chunks at once.
        for _ in 0..18 {
            let limits = limits.clone();
            tasks.spawn(async move {
                limits
                    .scope(wait(true, 65_536, &CancellationToken::new()))
                    .await
                    .unwrap();
                started.elapsed()
            });
        }
        let mut times = Vec::new();
        while let Some(result) = tasks.join_next().await {
            times.push(result.unwrap());
        }
        times.sort();
        for pair in times.windows(2) {
            assert!(pair[1] - pair[0] >= Duration::from_millis(590));
        }
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn concurrent_transfers_share_one_real_rate() {
        let directory =
            std::env::temp_dir().join(format!("mydrive-rate-concurrent-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let limits = TransferLimits {
            download_bps: Some(100_000),
            directory: Some(directory.to_str().unwrap().into()),
            ..Default::default()
        };
        let started = std::time::Instant::now();
        let mut tasks = tokio::task::JoinSet::new();
        for _ in 0..4 {
            let limits = limits.clone();
            tasks.spawn(async move {
                limits
                    .scope(wait(false, 20_000, &CancellationToken::new()))
                    .await
                    .unwrap();
                started.elapsed()
            });
        }
        let mut times = Vec::new();
        while let Some(result) = tasks.join_next().await {
            times.push(result.unwrap());
        }
        times.sort();
        for pair in times.windows(2) {
            assert!(pair[1] - pair[0] >= Duration::from_millis(180));
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
