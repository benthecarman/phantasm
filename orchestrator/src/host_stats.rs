//! Best-effort host statistics for the dashboard: RAM and load from `/proc`,
//! GPU state from `nvidia-smi`. Every field is optional and every failure path
//! (non-Linux, missing binary, timeout, unparsable output) degrades to `None`
//! or an empty list — a dashboard panel that hides beats an endpoint that
//! errors. Collected on demand per `/dashboard/data` request; nothing polls in
//! the background.

use std::time::Duration;

use serde::Serialize;

const NVIDIA_SMI_TIMEOUT: Duration = Duration::from_millis(1500);

#[derive(Debug, Default, Serialize)]
pub struct HostStats {
    pub memory: Option<MemoryStats>,
    pub load: Option<LoadStats>,
    /// One entry per GPU `nvidia-smi` reports; empty when unavailable.
    pub gpus: Vec<GpuStats>,
}

#[derive(Debug, Serialize)]
pub struct MemoryStats {
    pub total_bytes: u64,
    pub available_bytes: u64,
}

#[derive(Debug, Serialize)]
pub struct LoadStats {
    /// 1-minute load average.
    pub load_1m: f64,
    pub cores: u64,
}

#[derive(Debug, Serialize)]
pub struct GpuStats {
    pub name: String,
    pub memory_used_bytes: u64,
    pub memory_total_bytes: u64,
    pub utilization_pct: u64,
    /// Core temperature in °C. `None` when the driver reports N/A — a missing
    /// temperature must not drop the rest of the row.
    pub temperature_c: Option<u64>,
}

pub async fn collect() -> HostStats {
    let (memory, load, gpus) = tokio::join!(
        read_meminfo(),
        read_loadavg(),
        query_nvidia_smi(NVIDIA_SMI_TIMEOUT)
    );
    HostStats { memory, load, gpus }
}

async fn read_meminfo() -> Option<MemoryStats> {
    let text = tokio::fs::read_to_string("/proc/meminfo").await.ok()?;
    parse_meminfo(&text)
}

fn parse_meminfo(text: &str) -> Option<MemoryStats> {
    let field = |name: &str| {
        text.lines().find_map(|l| {
            let rest = l.strip_prefix(name)?;
            // "MemTotal:       32671728 kB"
            let kb: u64 = rest
                .trim_start_matches(':')
                .split_whitespace()
                .next()?
                .parse()
                .ok()?;
            Some(kb * 1024)
        })
    };
    Some(MemoryStats {
        total_bytes: field("MemTotal")?,
        available_bytes: field("MemAvailable")?,
    })
}

async fn read_loadavg() -> Option<LoadStats> {
    let text = tokio::fs::read_to_string("/proc/loadavg").await.ok()?;
    let load_1m: f64 = text.split_whitespace().next()?.parse().ok()?;
    let cores = std::thread::available_parallelism().ok()?.get() as u64;
    Some(LoadStats { load_1m, cores })
}

async fn query_nvidia_smi(timeout: Duration) -> Vec<GpuStats> {
    let cmd = tokio::process::Command::new("nvidia-smi")
        .args([
            "--query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu",
            "--format=csv,noheader,nounits",
        ])
        .kill_on_drop(true)
        .output();
    let output = match tokio::time::timeout(timeout, cmd).await {
        Ok(Ok(out)) if out.status.success() => out,
        _ => return Vec::new(),
    };
    parse_nvidia_smi_csv(&String::from_utf8_lossy(&output.stdout))
}

fn parse_nvidia_smi_csv(text: &str) -> Vec<GpuStats> {
    text.lines()
        .filter_map(|line| {
            let parts: Vec<&str> = line.split(',').map(str::trim).collect();
            let [name, used_mib, total_mib, util, temp] = parts.as_slice() else {
                return None;
            };
            Some(GpuStats {
                name: name.to_string(),
                memory_used_bytes: used_mib.parse::<u64>().ok()? * 1024 * 1024,
                memory_total_bytes: total_mib.parse::<u64>().ok()? * 1024 * 1024,
                utilization_pct: util.parse().ok()?,
                temperature_c: temp.parse().ok(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn meminfo_parses_kib_fields() {
        let text = "MemTotal:       32671728 kB\nMemFree:         1000000 kB\nMemAvailable:   20000000 kB\n";
        let mem = parse_meminfo(text).unwrap();
        assert_eq!(mem.total_bytes, 32_671_728 * 1024);
        assert_eq!(mem.available_bytes, 20_000_000 * 1024);
        assert!(parse_meminfo("garbage").is_none());
    }

    #[test]
    fn nvidia_csv_parses_rows_and_skips_garbage() {
        let text =
            "NVIDIA GeForce RTX 4090, 20345, 24564, 87, 71\nOld GPU, 100, 200, 5, N/A\nbad line\n";
        let gpus = parse_nvidia_smi_csv(text);
        assert_eq!(gpus.len(), 2);
        assert_eq!(gpus[0].name, "NVIDIA GeForce RTX 4090");
        assert_eq!(gpus[0].memory_used_bytes, 20345 * 1024 * 1024);
        assert_eq!(gpus[0].temperature_c, Some(71));
        // An N/A temperature must not drop the row.
        assert_eq!(gpus[1].temperature_c, None);
        assert_eq!(gpus[0].utilization_pct, 87);
    }
}
