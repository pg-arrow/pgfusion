use datafusion::prelude::SessionContext;
use pg_arrow::file::PAGE_BUFFER_SIZE;
use pg_arrow::file::reader::{ChunkReader, Oid, TableFileReader};
use pg_arrow::heap::page::HeapPageData;
use pg_arrow::table::PgTableReader;
use pg_test_harness::{db_oid_blocking, read_pg_config};
use pgfusion_lib::{SessionOptions, create_session_with_options};
use tokio::runtime::Runtime;

pub struct BenchContext {
    pub db_id: Oid,
    pub rt: Runtime,
}

impl BenchContext {
    pub fn new() -> Self {
        let config = read_pg_config(env!("CARGO_MANIFEST_DIR"), "pg18");
        pg_arrow::file::set_data_dir(config.data_dir.clone());
        let db_id = db_oid_blocking("pgbench_test");
        Self { db_id, rt: Runtime::new().unwrap() }
    }

    pub fn session(&self, opts: &SessionOptions) -> SessionContext {
        create_session_with_options(self.db_id, opts).expect("failed to create session")
    }

    pub fn default_session(&self) -> SessionContext {
        self.session(&SessionOptions::default())
    }
}

// ── SessionOptions presets ───────────────────────────────────────────────────

pub fn opts_default() -> SessionOptions { SessionOptions::default() }

pub fn opts_mem_2g() -> SessionOptions {
    SessionOptions { memory_limit: Some(2 * 1024 * 1024 * 1024), ..Default::default() }
}

pub fn opts_mem_512m() -> SessionOptions {
    SessionOptions { memory_limit: Some(512 * 1024 * 1024), ..Default::default() }
}

pub fn opts_mem_15g() -> SessionOptions {
    SessionOptions { memory_limit: Some(15 * 1024 * 1024 * 1024), ..Default::default() }
}

pub fn opts_batch_1024() -> SessionOptions {
    SessionOptions { batch_size: Some(1024), ..Default::default() }
}

pub fn opts_batch_16384() -> SessionOptions {
    SessionOptions { batch_size: Some(16384), ..Default::default() }
}

pub fn opts_no_coalesce() -> SessionOptions {
    SessionOptions { coalesce_batches: Some(false), ..Default::default() }
}

pub fn opts_partitions_4() -> SessionOptions {
    SessionOptions { target_partitions: Some(4), ..Default::default() }
}

pub fn opts_partitions_20() -> SessionOptions {
    SessionOptions { target_partitions: Some(20), ..Default::default() }
}

pub fn opts_tuned() -> SessionOptions {
    SessionOptions {
        memory_limit: Some(4 * 1024 * 1024 * 1024),
        batch_size: Some(16384),
        coalesce_batches: Some(false),
        target_partitions: Some(20),
        ..Default::default()
    }
}

// ── Raw pg_arrow helpers ─────────────────────────────────────────────────────

pub fn raw_read_all_batches(db_id: Oid, table_name: &str) -> usize {
    let mut reader = PgTableReader::new(db_id).unwrap();
    reader.set_table(table_name).unwrap();
    let schema = reader.schema().unwrap().clone();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, _) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();
    TableFileReader::new(db_id, pg_class.relfilenode as usize)
        .get_page_reader().unwrap()
        .into_batch_stream(&schema, None)
        .map(|b| b.unwrap().num_rows())
        .sum()
}

pub fn raw_read_pages_io_only(db_id: Oid, table_name: &str) -> usize {
    let reader = PgTableReader::new(db_id).unwrap();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, _) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();
    let file_reader = TableFileReader::new(db_id, pg_class.relfilenode as usize);
    let total_pages = pg_class.relpages.max(0) as usize;
    let chunk_size = 256;
    let mut pages_total = 0usize;
    let mut start = 0;
    while start < total_pages {
        let want = chunk_size.min(total_pages - start);
        let (_bytes, pages_read) = file_reader.read_pages_bulk(start, want).unwrap();
        pages_total += pages_read;
        start += pages_read;
        if pages_read < want { break; }
    }
    pages_total
}

pub fn raw_read_pages_parsed(db_id: Oid, table_name: &str) -> usize {
    let reader = PgTableReader::new(db_id).unwrap();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, _) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();
    let file_reader = TableFileReader::new(db_id, pg_class.relfilenode as usize);
    let total_pages = pg_class.relpages.max(0) as usize;
    let chunk_size = 256;
    let mut total_tuples = 0usize;
    let mut start = 0;
    while start < total_pages {
        let want = chunk_size.min(total_pages - start);
        let (bulk_bytes, pages_read) = file_reader.read_pages_bulk(start, want).unwrap();
        for i in 0..pages_read {
            let offset = i * PAGE_BUFFER_SIZE;
            let page = HeapPageData::parse_bytes(bulk_bytes.slice(offset..offset + PAGE_BUFFER_SIZE)).unwrap();
            total_tuples += page.lp_num;
        }
        start += pages_read;
        if pages_read < want { break; }
    }
    total_tuples
}

pub fn raw_read_pages_arrow(db_id: Oid, table_name: &str) -> usize {
    let reader = PgTableReader::new(db_id).unwrap();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, schema) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();
    let file_reader = TableFileReader::new(db_id, pg_class.relfilenode as usize);
    let total_pages = pg_class.relpages.max(0) as usize;
    let chunk_size = 128;
    let mut total_rows = 0usize;
    let mut start = 0;
    while start < total_pages {
        let want = chunk_size.min(total_pages - start);
        let (bulk_bytes, pages_read) = file_reader.read_pages_bulk(start, want).unwrap();
        for i in 0..pages_read {
            let offset = i * PAGE_BUFFER_SIZE;
            let page = HeapPageData::parse_bytes(bulk_bytes.slice(offset..offset + PAGE_BUFFER_SIZE)).unwrap();
            total_rows += page.to_record_batch(schema, None, None).unwrap().num_rows();
        }
        start += pages_read;
        if pages_read < want { break; }
    }
    total_rows
}

pub fn raw_read_pages_arrow_projected(db_id: Oid, table_name: &str, projection: &[usize]) -> usize {
    let reader = PgTableReader::new(db_id).unwrap();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, schema) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();
    let file_reader = TableFileReader::new(db_id, pg_class.relfilenode as usize);
    let total_pages = pg_class.relpages.max(0) as usize;
    let chunk_size = 128;
    let mut total_rows = 0usize;
    let mut start = 0;
    while start < total_pages {
        let want = chunk_size.min(total_pages - start);
        let (bulk_bytes, pages_read) = file_reader.read_pages_bulk(start, want).unwrap();
        for i in 0..pages_read {
            let offset = i * PAGE_BUFFER_SIZE;
            let page = HeapPageData::parse_bytes(bulk_bytes.slice(offset..offset + PAGE_BUFFER_SIZE)).unwrap();
            total_rows += page.to_record_batch(schema, Some(projection), None).unwrap().num_rows();
        }
        start += pages_read;
        if pages_read < want { break; }
    }
    total_rows
}
