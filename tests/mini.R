reprex::reprex({
	stop_times = as.data.frame(tibble::tribble(
		~trip_id, ~stop_id, ~arrival_time, ~departure_time, ~stop_sequence,
		"tripAB1", "A", "00:00:00", "00:00:00", 1,
		"tripAB1", "B", "00:00:10", "00:00:10", 2,
		"tripAB2", "A", "00:00:05", "00:00:05", 1,
		"tripAB2", "B", "00:00:16", "00:00:16", 2,
		"tripBC1", "B", "00:00:20", "00:00:20", 1,
		"tripBC1", "C", "00:00:30", "00:00:30", 2
	))

	tidytransit::raptor(stop_times,
		   transfers = data.frame(),
		   stop_ids = "A")
})

# A(t=0)->C with is discarded because the journey_arrival_time is the same as A(t=5)->C
