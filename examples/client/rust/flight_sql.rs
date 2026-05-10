use arrow_flight::sql::client::FlightSqlServiceClient;
use futures::StreamExt;
use tonic::transport::Channel;

const DEFAULT_ENDPOINT: &str = "http://localhost:32010";
const DEFAULT_QUERY: &str = "SELECT count(*) FROM pgbench_accounts";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let endpoint = std::env::args().nth(1).unwrap_or_else(|| DEFAULT_ENDPOINT.to_owned());
    let query = std::env::args().nth(2).unwrap_or_else(|| DEFAULT_QUERY.to_owned());

    let channel = Channel::from_shared(endpoint.clone())?
        .connect()
        .await
        .map_err(|e| format!("failed to connect to {endpoint}: {e}"))?;

    let mut client = FlightSqlServiceClient::new(channel);

    let info = client
        .execute(query.clone(), None)
        .await
        .map_err(|e| format!("execute failed: {e}"))?;

    println!("query: {query}");
    println!("endpoints: {}", info.endpoint.len());

    let mut total_rows = 0usize;

    for (i, ep) in info.endpoint.into_iter().enumerate() {
        let ticket = match ep.ticket {
            Some(t) => t,
            None => {
                eprintln!("partition {i}: no ticket, skipping");
                continue;
            }
        };

        let mut stream = client
            .do_get(ticket)
            .await
            .map_err(|e| format!("do_get failed for partition {i}: {e}"))?;

        let mut rows = 0usize;
        while let Some(batch) = stream.next().await {
            let batch = batch.map_err(|e| format!("partition {i} stream error: {e}"))?;
            rows += batch.num_rows();
        }

        println!("partition {i}: {rows} rows");
        total_rows += rows;
    }

    println!("total: {total_rows} rows");
    Ok(())
}
