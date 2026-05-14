package io.pgfusion.client;

import org.apache.arrow.flight.FlightClient;
import org.apache.arrow.flight.FlightEndpoint;
import org.apache.arrow.flight.FlightInfo;
import org.apache.arrow.flight.FlightStream;
import org.apache.arrow.flight.Location;
import org.apache.arrow.flight.sql.FlightSqlClient;
import org.apache.arrow.memory.RootAllocator;

public class FlightSqlClient {

    private static final String DEFAULT_HOST = "localhost";
    private static final int DEFAULT_PORT = 32010;
    private static final String DEFAULT_QUERY = "SELECT count(*) FROM pgbench_accounts";

    public static void main(String[] args) throws Exception {
        String host = DEFAULT_HOST;
        int port = DEFAULT_PORT;
        String query = DEFAULT_QUERY;

        if (args.length > 0) {
            String[] parts = args[0].split(":", 2);
            host = parts[0];
            if (parts.length > 1) {
                port = Integer.parseInt(parts[1]);
            }
        }
        if (args.length > 1) {
            query = args[1];
        }

        try (RootAllocator allocator = new RootAllocator();
             FlightClient flightClient = FlightClient.builder(allocator, Location.forGrpcInsecure(host, port)).build();
             org.apache.arrow.flight.sql.FlightSqlClient client = new org.apache.arrow.flight.sql.FlightSqlClient(flightClient)) {

            FlightInfo info = client.execute(query);

            System.out.printf("query: %s%n", query);
            System.out.printf("endpoints: %d%n", info.getEndpoints().size());

            long totalRows = 0;

            for (int i = 0; i < info.getEndpoints().size(); i++) {
                FlightEndpoint ep = info.getEndpoints().get(i);

                try (FlightStream stream = client.getStream(ep.getTicket())) {
                    long rows = 0;
                    while (stream.next()) {
                        rows += stream.getRoot().getRowCount();
                    }
                    System.out.printf("partition %d: %d rows%n", i, rows);
                    totalRows += rows;
                }
            }

            System.out.printf("total: %d rows%n", totalRows);
        }
    }
}
