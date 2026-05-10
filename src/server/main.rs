use mimalloc::MiMalloc;
use pg_arrow::file::error::PgError;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

#[tokio::main]
async fn main() -> Result<(), PgError> {
    env_logger::init();
    todo!("pgfusion_server is not yet implemented")
}
