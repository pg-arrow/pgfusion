package main

import (
	"context"
	"fmt"
	"os"

	"github.com/apache/arrow-go/v18/arrow/flight/flightsql"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const defaultEndpoint = "localhost:32010"
const defaultQuery = "SELECT count(*) FROM pgbench_accounts"

func main() {
	endpoint := defaultEndpoint
	query := defaultQuery
	if len(os.Args) > 1 {
		endpoint = os.Args[1]
	}
	if len(os.Args) > 2 {
		query = os.Args[2]
	}

	client, err := flightsql.NewClient(endpoint, nil, nil, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create flight sql client: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	ctx := context.Background()

	info, err := client.Execute(ctx, query)
	if err != nil {
		fmt.Fprintf(os.Stderr, "execute failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("query: %s\n", query)
	fmt.Printf("endpoints: %d\n", len(info.Endpoint))

	totalRows := int64(0)

	for i, ep := range info.Endpoint {
		if ep.Ticket == nil {
			fmt.Fprintf(os.Stderr, "partition %d: no ticket, skipping\n", i)
			continue
		}

		stream, err := client.DoGet(ctx, ep.Ticket)
		if err != nil {
			fmt.Fprintf(os.Stderr, "do_get failed for partition %d: %v\n", i, err)
			os.Exit(1)
		}

		rows := int64(0)
		for stream.Next() {
			rec := stream.Record()
			rows += rec.NumRows()
		}
		if err := stream.Err(); err != nil {
			fmt.Fprintf(os.Stderr, "partition %d stream error: %v\n", i, err)
			os.Exit(1)
		}

		fmt.Printf("partition %d: %d rows\n", i, rows)
		totalRows += rows
	}

	fmt.Printf("total: %d rows\n", totalRows)
}
