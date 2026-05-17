use async_trait::async_trait;
use datafusion::catalog::Session;
use datafusion::datasource::{TableProvider, TableType};
use datafusion::execution::RecordBatchStream;
use datafusion::logical_expr::expr::Expr;
use datafusion::physical_expr::EquivalenceProperties;
use datafusion::physical_plan::execution_plan::{Boundedness, EmissionType};
use datafusion::physical_plan::metrics::ExecutionPlanMetricsSet;
use datafusion::physical_plan::{Partitioning, project_schema};

use datafusion::arrow::datatypes::SchemaRef;
use datafusion::arrow::record_batch::RecordBatch;
use datafusion::common::{DataFusionError, Result};
use datafusion::execution::context::TaskContext;
use datafusion::physical_plan::{
    DisplayAs, DisplayFormatType, ExecutionPlan, PlanProperties, SendableRecordBatchStream,
};
use futures::Stream;
use crate::snapshot::PgSnapshot;
use pg_arrow::file::reader::{AsyncBatchStream, Oid};
use pg_arrow::heap::snapshot::PgSnapshot as ArrowPgSnapshot;
use pg_arrow::types::{PgClass, PgSchema};
use std::any::Any;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

/// A custom datasource, used to represent a datastore with a single index
#[derive(Clone, Debug)]
pub struct CustomDataSource {
    pub schema: SchemaRef,
    pub pg_schema: PgSchema,
    pub table_metadata: PgClass,
    pub db_id: Oid,
    /// Number of page-range partitions for parallel heap file scans.
    pub partition_count: usize,
}

#[derive(Debug)]
struct PgTableExec {
    db_id: Oid,
    table_metadata: PgClass,
    schema: PgSchema,
    projections: Option<(SchemaRef, Vec<usize>)>,
    properties: Arc<PlanProperties>,
    metrics: ExecutionPlanMetricsSet,
    snapshot: Option<ArrowPgSnapshot>,
    partition_count: usize,
    total_pages: usize,
}

impl DisplayAs for PgTableExec {
    fn fmt_as(&self, _t: DisplayFormatType, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "PgTableExec")
    }
}

impl ExecutionPlan for PgTableExec {
    fn name(&self) -> &str {
        "PgTableExec"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn schema(&self) -> SchemaRef {
        if let Some(proj) = &self.projections {
            proj.0.clone()
        } else {
            Arc::new(self.schema.to_arrow_schema())
        }
    }

    fn properties(&self) -> &Arc<PlanProperties> {
        &self.properties
    }

    fn children(&self) -> Vec<&Arc<dyn ExecutionPlan>> {
        Vec::new()
    }

    fn with_new_children(
        self: Arc<Self>,
        _: Vec<Arc<dyn ExecutionPlan>>,
    ) -> Result<Arc<dyn ExecutionPlan>> {
        Ok(self)
    }

    fn execute(
        &self,
        partition: usize,
        _context: Arc<TaskContext>,
    ) -> Result<SendableRecordBatchStream> {
        let num_partitions = self.partition_count;
        let projection = self.projections.as_ref().map(|(_, cols)| cols.clone());
        let total_pages = self.total_pages;
        let pages_per_partition = (total_pages + num_partitions - 1) / num_partitions.max(1);
        let start = partition * pages_per_partition;
        let end = ((partition + 1) * pages_per_partition).min(total_pages);

        let mut batch_stream = AsyncBatchStream::new(
            self.db_id,
            self.table_metadata.relfilenode as usize,
            self.schema.clone(),
            projection,
        )
        .with_page_range(start, end);
        if let Some(snap) = self.snapshot.clone() {
            batch_stream = batch_stream.with_snapshot(snap);
        }

        let arrow_schema = match &self.projections {
            Some((schema, _)) => schema.clone(),
            None => Arc::new(self.schema.to_arrow_schema()),
        };

        let inner = futures::stream::unfold(batch_stream, |mut stream| async move {
            let result = stream.next_batch().await;
            result.map(|r| {
                let mapped = r.map_err(|e| DataFusionError::Execution(e.to_string()));
                (mapped, stream)
            })
        });

        Ok(Box::pin(PgRecordBatchStream {
            inner: Box::pin(inner),
            arrow_schema,
        }))
    }
}

impl PgTableExec {
    fn new(
        projections: Option<&Vec<usize>>,
        schema: SchemaRef,
        pg_schema: PgSchema,
        db: Oid,
        table_metadata: PgClass,
        snapshot: Option<ArrowPgSnapshot>,
        partition_count: usize,
    ) -> Self {
        let proj = if let Some(proj) = projections {
            let projected_schema = project_schema(&schema, projections).unwrap();
            Some((projected_schema, proj.clone()))
        } else {
            None
        };

        let total_pages = {
            let reader = pg_arrow::file::reader::TableFileReader::new(
                db,
                table_metadata.relfilenode as usize,
            );
            match reader.num_pages() {
                Ok(n) => n,
                Err(_) => table_metadata.relpages.max(0) as usize,
            }
        };

        Self {
            db_id: db,
            table_metadata,
            schema: pg_schema,
            projections: proj.clone(),
            properties: Arc::new(PlanProperties::new(
                EquivalenceProperties::new(proj.unwrap().0),
                Partitioning::RoundRobinBatch(partition_count),
                EmissionType::Incremental,
                Boundedness::Bounded,
            )),
            metrics: ExecutionPlanMetricsSet::new(),
            snapshot,
            partition_count,
            total_pages,
        }
    }
}

/// Wraps a `futures::Stream` with a schema to implement DataFusion's `RecordBatchStream`.
struct PgRecordBatchStream {
    inner: Pin<Box<dyn Stream<Item = Result<RecordBatch>> + Send>>,
    arrow_schema: SchemaRef,
}

impl Stream for PgRecordBatchStream {
    type Item = Result<RecordBatch>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.inner.as_mut().poll_next(cx)
    }
}

impl RecordBatchStream for PgRecordBatchStream {
    fn schema(&self) -> SchemaRef {
        self.arrow_schema.clone()
    }
}

impl CustomDataSource {
    pub(crate) fn create_physical_plan(
        &self,
        projections: Option<&Vec<usize>>,
        schema: SchemaRef,
        snapshot: Option<ArrowPgSnapshot>,
    ) -> Result<Arc<dyn ExecutionPlan>> {
        Ok(Arc::new(PgTableExec::new(
            projections,
            schema,
            self.pg_schema.clone(),
            self.db_id,
            self.table_metadata.clone(),
            snapshot,
            self.partition_count,
        )))
    }
}

#[async_trait]
impl TableProvider for CustomDataSource {
    fn as_any(&self) -> &dyn Any {
        self
    }

    fn schema(&self) -> SchemaRef {
        self.schema.clone()
    }

    fn table_type(&self) -> TableType {
        TableType::Base
    }

    async fn scan(
        &self,
        state: &dyn Session,
        projection: Option<&Vec<usize>>,
        _filters: &[Expr],
        _limit: Option<usize>,
    ) -> Result<Arc<dyn ExecutionPlan>> {
        let snapshot = state
            .config()
            .options()
            .extensions
            .get::<PgSnapshot>()
            .map(|s| ArrowPgSnapshot {
                xmin: s.xmin,
                xmax: s.xmax,
                xip: s.xip.clone(),
            });
        self.create_physical_plan(projection, self.schema(), snapshot)
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn test_pg_arrow() {
        use pg_arrow::table::PgTableReader;
        use std::time::{Duration, Instant};

        fn format_elapsed(elapsed: Duration) -> String {
            let ms = elapsed.as_secs_f64() * 1000.0;
            if elapsed.as_secs() >= 1 {
                let total_secs = elapsed.as_secs();
                let hrs = total_secs / 3600;
                let mins = (total_secs % 3600) / 60;
                let secs = total_secs % 60;
                let millis = elapsed.subsec_millis();
                format!(
                    "{:.3} ms ({:02}:{:02}:{:02}.{:03})",
                    ms, hrs, mins, secs, millis
                )
            } else {
                format!("{:.3} ms", ms)
            }
        }

        env_logger::init();

        let db_id = 16384;

        // Bootstrap: reads pg_class + pg_attribute catalogs
        println!("Bootstrapping catalogs for db_id={db_id}...");
        let mut reader = PgTableReader::new(db_id).unwrap();
        println!("Catalog bootstrap complete.");

        // Select a table
        reader.set_table("pgbench_accounts").unwrap();
        println!("Schema: {:?}", reader.schema());

        // Fetch all rows
        let start = Instant::now();
        let rows = reader.fetch_by_limit(10_000_000).unwrap();
        let duration = start.elapsed();
        println!("Elapsed: {}", format_elapsed(duration));
        println!("Total rows: {}", rows.len());

        // Fetch all rows
        let start = Instant::now();
        let rows = reader.fetch_by_limit(10_000_000).unwrap();
        let duration = start.elapsed();
        println!("Elapsed: {}", format_elapsed(duration));
        println!("Total rows: {}", rows.len());

        // Fetch with limit
        let rows = reader.fetch_by_limit(5).unwrap();
        for (i, row) in rows.iter().enumerate() {
            println!("{}", row);
        }
    }
}
