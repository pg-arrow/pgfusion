use datafusion::common::config::{ConfigExtension, ExtensionOptions};
use datafusion::common::Result;
pub use pg_arrow::heap::snapshot::PgSnapshot as ArrowPgSnapshot;

/// DataFusion session-config extension carrying a PostgreSQL MVCC snapshot.
///
/// Wraps `pg_arrow::heap::snapshot::PgSnapshot` and adds the DataFusion
/// `ConfigExtension` / `ExtensionOptions` boilerplate so it can travel through
/// `SessionConfig::extensions`.
#[derive(Debug, Clone, Default)]
pub struct PgSnapshot(pub ArrowPgSnapshot);

impl PgSnapshot {
    /// Parse PostgreSQL snapshot string: `"xmin:xmax:xip_list"`.
    pub fn parse(s: &str) -> Option<Self> {
        ArrowPgSnapshot::parse(s).map(Self)
    }
}

impl From<ArrowPgSnapshot> for PgSnapshot {
    fn from(s: ArrowPgSnapshot) -> Self { Self(s) }
}

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
            "xmin" => self.0.xmin = value.parse().unwrap_or(0),
            "xmax" => self.0.xmax = value.parse().unwrap_or(0),
            "xip" => {
                self.0.xip = value
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
