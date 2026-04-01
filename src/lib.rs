#[cfg(test)]
mod tests {

    #[test]
    fn test_pg_arrow() {
        use pg_arrow::table::PgTableReader;
        use std::time::Instant;

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
        println!("Elapsed: {:.3} ms", duration.as_secs_f64() * 1000.0);
        println!("Total rows: {}", rows.len());

        // Fetch all rows
        let start = Instant::now();
        let rows = reader.fetch_by_limit(10_000_000).unwrap();
        let duration = start.elapsed();
        println!("Elapsed: {:.3} ms", duration.as_secs_f64() * 1000.0);
        println!("Total rows: {}", rows.len());

        // Fetch with limit
        let rows = reader.fetch_by_limit(5).unwrap();
        for (i, row) in rows.iter().enumerate() {
            println!("{}", row);
        }
    }
}

use async_trait::async_trait;
use datafusion::catalog::Session;
use datafusion::common::tree_node::TreeNodeRecursion;
use datafusion::datasource::{TableProvider, TableType};
use datafusion::execution::RecordBatchStream;
use datafusion::logical_expr::expr::Expr;
use datafusion::physical_expr::EquivalenceProperties;
use datafusion::physical_plan::execution_plan::{Boundedness, EmissionType};
use datafusion::physical_plan::metrics::{BaselineMetrics, ExecutionPlanMetricsSet};
use datafusion::physical_plan::{Partitioning, PhysicalExpr, project_schema};

use datafusion::arrow::array::{UInt8Builder, UInt64Builder};
use datafusion::arrow::datatypes::{DataType, Field, Schema, SchemaRef};
use datafusion::arrow::record_batch::RecordBatch;
use datafusion::common::Result;
use datafusion::execution::context::TaskContext;
use datafusion::physical_plan::expressions::PhysicalSortExpr;
use datafusion::physical_plan::memory::MemoryStream;
use datafusion::physical_plan::{
    DisplayAs, DisplayFormatType, ExecutionPlan, PlanProperties, SendableRecordBatchStream,
    Statistics,
};
use datafusion::prelude::SessionContext;
use futures::Stream;
use pg_arrow::file::error::PgError;
use pg_arrow::file::reader::{ChunkReader, Oid, PageRowIter, TableFileReader};
use pg_arrow::file::tuple::ColumnSearchArg;
use pg_arrow::table::{PgRow, PgTableReader, decode_row};
use pg_arrow::types::{PgClass, PgSchema};
use std::any::Any;
use std::collections::{BTreeMap, HashMap};
use std::future::ready;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

/// A custom datasource, used to represent a datastore with a single index
#[derive(Clone, Debug)]
pub struct CustomDataSource {
    pub schema: SchemaRef,
    pub pg_schema: PgSchema,
    pub table_metadata: PgClass,
    pub db_id: Oid,
}

#[derive(Debug)]
struct CustomExec {
    db_id: Oid,
    table_metadata: PgClass,
    schema: PgSchema,
    projections: Option<(SchemaRef, Vec<usize>)>,
    properties: Arc<PlanProperties>,
    metrics: ExecutionPlanMetricsSet,
}

impl DisplayAs for CustomExec {
    fn fmt_as(&self, _t: DisplayFormatType, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "CustomExec")
    }
}

impl ExecutionPlan for CustomExec {
    fn name(&self) -> &str {
        "CustomExec"
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
        _partition: usize,
        _context: Arc<TaskContext>,
    ) -> Result<SendableRecordBatchStream> {
        let reader = TableFileReader {
            db_id: self.db_id,
            relation_id: self.table_metadata.relfilenode as usize,
        };

        let page_reader = reader
            .get_page_reader()
            .map_err(|e| PgError::CatalogBootstrapFailed {
                detail: format!("failed to open table file: {e}"),
            })
            .unwrap();

        let row_result = page_reader.into_iter();

        Ok(Box::pin(SampleStream {
            page_row_iter: row_result,
            projections: self.projections.clone(),
            metrics: BaselineMetrics::new(&self.metrics, 0),
            schema: self.schema.clone(),
        }))
    }
}

impl CustomExec {
    fn new(
        projections: Option<&Vec<usize>>,
        schema: SchemaRef,
        pg_schema: PgSchema,
        db: Oid,
        table_metadata: PgClass,
    ) -> Self {
        let proj = if let Some(proj) = projections {
            let projected_schema = project_schema(&schema, projections).unwrap();
            Some((projected_schema, proj.clone()))
        } else {
            None
        };

        Self {
            db_id: db,
            table_metadata,
            schema: pg_schema,
            projections: proj.clone(),
            properties: Arc::new(PlanProperties::new(
                EquivalenceProperties::new(proj.unwrap().0),
                Partitioning::UnknownPartitioning(1),
                EmissionType::Incremental,
                Boundedness::Bounded,
            )),
            metrics: ExecutionPlanMetricsSet::new(),
        }
    }
}

/// Stream adapter that applies sampling to each batch.
struct SampleStream<R: ChunkReader> {
    page_row_iter: PageRowIter<R>,
    projections: Option<(SchemaRef, Vec<usize>)>,
    metrics: BaselineMetrics,
    schema: PgSchema,
}

impl<R: ChunkReader> Stream for SampleStream<R> {
    type Item = Result<RecordBatch>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let mut rows = Vec::new();
        while let Some(Ok(next_row)) = self.page_row_iter.next() {
            rows.push(decode_row(&next_row, &self.schema).unwrap());
            if rows.len() == 100 {
                break;
            }
        }
        if !rows.is_empty() {
            let rb = PgRow::to_record_batch(rows.as_slice(), &self.schema).unwrap();
            let projected_rb = rb
                .project(self.projections.as_ref().unwrap().1.as_slice())
                .unwrap();
            Poll::Ready(Some(Ok(projected_rb)))
        } else {
            Poll::Ready(None)
        }
    }
}

impl<R: ChunkReader> RecordBatchStream for SampleStream<R> {
    fn schema(&self) -> SchemaRef {
        if let Some(proj) = &self.projections {
            proj.0.clone()
        } else {
            Arc::new(self.schema.to_arrow_schema())
        }
    }
}

/// Create a `SessionContext` with all tables from the given database registered.
pub fn create_session(
    db_id: Oid,
) -> std::result::Result<SessionContext, pg_arrow::file::error::PgError> {
    use datafusion::prelude::SessionConfig;
    use pg_arrow::table::PgTableReader;

    let mut config = SessionConfig::new();
    config.options_mut().catalog.information_schema = true;
    let ctx = SessionContext::new_with_config(config);

    let table_reader = PgTableReader::new(db_id)?;
    for table_details in table_reader.get_all_tables()? {
        let provider = CustomDataSource {
            db_id,
            schema: Arc::new(table_details.1.to_arrow_schema()),
            pg_schema: table_details.1,
            table_metadata: table_details.0.clone(),
        };
        ctx.register_table(&table_details.0.relname, Arc::new(provider))
            .unwrap();
    }
    // println!("Loaded {} tables from database OID {}", tables.len(), db_id);

    Ok(ctx)
}

impl CustomDataSource {
    pub(crate) async fn create_physical_plan(
        &self,
        projections: Option<&Vec<usize>>,
        schema: SchemaRef,
    ) -> Result<Arc<dyn ExecutionPlan>> {
        Ok(Arc::new(CustomExec::new(
            projections,
            schema,
            self.pg_schema.clone(),
            self.db_id,
            self.table_metadata.clone(),
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
        _state: &dyn Session,
        projection: Option<&Vec<usize>>,
        // filters and limit can be used here to inject some push-down operations if needed
        _filters: &[Expr],
        _limit: Option<usize>,
    ) -> Result<Arc<dyn ExecutionPlan>> {
        return self.create_physical_plan(projection, self.schema()).await;
    }
}
