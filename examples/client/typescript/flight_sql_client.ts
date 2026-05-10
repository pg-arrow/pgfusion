/**
 * Example: TypeScript Arrow Flight SQL client for pgfusion_server.
 *
 * Uses apache-arrow + @grpc/grpc-js to connect to pgfusion_server
 * and receive Arrow RecordBatches directly.
 *
 * Run:
 *   pgfusion_server -d /path/to/pgdata --db-id 16384 --port 32010
 *   bun install && bun run flight_sql_client.ts
 */

import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";
import { tableFromIPC, RecordBatch } from "apache-arrow";

const FLIGHT_SQL_HOST = "localhost:32010";

// Arrow Flight proto — download from apache/arrow if not bundled:
// curl -O https://raw.githubusercontent.com/apache/arrow/main/format/Flight.proto
const PROTO_PATH = new URL("./Flight.proto", import.meta.url).pathname;

async function main() {
  const packageDef = await protoLoader.load(PROTO_PATH, {
    keepCase: true,
    longs: String,
    enums: String,
    defaults: true,
    oneofs: true,
  });

  const proto = grpc.loadPackageDefinition(packageDef) as any;
  const FlightService = proto.arrow.flight.protocol.FlightService;

  const client = new FlightService(
    FLIGHT_SQL_HOST,
    grpc.credentials.createInsecure()
  );

  // Execute SQL — get FlightInfo with ticket(s)
  const sqlCommand = Buffer.from(
    JSON.stringify({ query: "SELECT region, sum(revenue) FROM orders GROUP BY region" })
  );

  const flightInfo = await new Promise<any>((resolve, reject) => {
    client.GetFlightInfo(
      { type: 1, cmd: sqlCommand }, // type 1 = CMD
      (err: Error, response: any) => (err ? reject(err) : resolve(response))
    );
  });

  // Fetch each endpoint — returns Arrow IPC stream
  for (const endpoint of flightInfo.endpoint) {
    const stream = client.DoGet(endpoint.ticket);
    const chunks: Buffer[] = [];

    await new Promise<void>((resolve, reject) => {
      stream.on("data", (msg: { data_body: Buffer }) => {
        if (msg.data_body?.length) chunks.push(msg.data_body);
      });
      stream.on("error", reject);
      stream.on("end", resolve);
    });

    // Reconstruct Arrow Table from IPC buffers
    const ipcBuffer = Buffer.concat(chunks);
    const table = tableFromIPC(ipcBuffer);

    console.log(`${table.numRows} rows received`);
    for (const batch of table.batches as RecordBatch[]) {
      console.log("schema:", batch.schema.toString());
      console.log("batch rows:", batch.numRows);
    }
  }

  client.close();
}

main().catch(console.error);
