//! HTTP server for remote SQL query execution against PostgreSQL data files.
//!
//! This module will provide:
//! - REST API for submitting SQL queries
//! - JSON and Arrow IPC result formats
//! - Connection and session management

use pg_arrow::file::error::PgError;

/// Entry point for the server binary. Not yet implemented.
pub async fn run() -> Result<(), PgError> {
    todo!("pgfusion_server is not yet implemented")
}
