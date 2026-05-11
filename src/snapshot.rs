use datafusion::common::config::{ConfigExtension, ExtensionOptions};
use datafusion::common::Result;

/// PostgreSQL transaction snapshot used for MVCC visibility checks.
///
/// Obtained by running:
///   `SELECT txid_current_snapshot()` inside a REPEATABLE READ transaction.
///
/// A tuple's xmin is visible when:
///   xmin < xmax_snap  AND  xmin not in xip
#[derive(Debug, Clone, Default)]
pub struct PgSnapshot {
    /// Lowest xid still active when snapshot was taken (all xids < xmin are committed).
    pub xmin: u32,
    /// First xid not yet assigned (all xids >= xmax are invisible).
    pub xmax: u32,
    /// In-progress xids at snapshot time (xmin <= xid < xmax but not yet committed).
    pub xip: Vec<u32>,
}

impl PgSnapshot {
    /// Parse PostgreSQL snapshot string format: `xmin:xmax:xip_list`
    /// e.g. `"100:105:101,103"`
    pub fn parse(s: &str) -> Option<Self> {
        let parts: Vec<&str> = s.splitn(3, ':').collect();
        if parts.len() < 2 {
            return None;
        }
        let xmin = parts[0].trim().parse::<u32>().ok()?;
        let xmax = parts[1].trim().parse::<u32>().ok()?;
        let xip = if parts.len() == 3 && !parts[2].trim().is_empty() {
            parts[2]
                .split(',')
                .filter_map(|x| x.trim().parse::<u32>().ok())
                .collect()
        } else {
            vec![]
        };
        Some(Self { xmin, xmax, xip })
    }

    /// Returns true if t_xmin is visible under this snapshot.
    ///
    /// Visibility rule (simplified, post-CHECKPOINT):
    ///   - xmin < xmin_snap  → always visible (committed before snapshot)
    ///   - xmin >= xmax_snap → never visible (started after snapshot)
    ///   - xmin in xip       → not visible (in-progress at snapshot time)
    ///   - otherwise         → visible
    pub fn xmin_visible(&self, t_xmin: u32) -> bool {
        const FROZEN_XID: u32 = 2;
        if t_xmin <= FROZEN_XID {
            return true; // frozen tuples are always visible
        }
        if t_xmin < self.xmin {
            return true;
        }
        if t_xmin >= self.xmax {
            return false;
        }
        !self.xip.contains(&t_xmin)
    }
}

// ── ConfigExtension boilerplate ──────────────────────────────────────────────
// Serialise snapshot to/from string so DataFusion can clone and pass it through
// SessionConfig extensions.

impl ConfigExtension for PgSnapshot {
    const PREFIX: &'static str = "pg_snapshot";
}

impl ExtensionOptions for PgSnapshot {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    fn cloned(&self) -> Box<dyn ExtensionOptions> {
        Box::new(self.clone())
    }

    fn set(&mut self, key: &str, value: &str) -> Result<()> {
        match key {
            "xmin" => self.xmin = value.parse().unwrap_or(0),
            "xmax" => self.xmax = value.parse().unwrap_or(0),
            "xip" => {
                self.xip = value
                    .split(',')
                    .filter(|s| !s.is_empty())
                    .filter_map(|s| s.parse::<u32>().ok())
                    .collect()
            }
            _ => {}
        }
        Ok(())
    }

    fn entries(&self) -> Vec<datafusion::common::config::ConfigEntry> {
        vec![]
    }
}
