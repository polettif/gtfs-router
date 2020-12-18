reprex::reprex({
	from = "Berlin Hauptbahnhof"
	start_time = 8 * 3600
	gtfsrouter::berlin_gtfs_to_zip()
	gtfs_file = paste0(tempdir(), "/vbb.zip")

	# 1a) tidytransit #####
	suppressMessages({
		library(tidytransit)
		library(dplyr)
	})
	gtfs_1 = read_gtfs(gtfs_file)

	from_name = gtfs_1$stops %>%
		filter(grepl(from, stop_name)) %>%
		pull(stop_name) %>%	unique()

	timetable_1 = filter_stop_times(gtfs_1, "2019-06-20", start_time, 24*3600)
	tts_1 = travel_times(timetable_1, from_name)

	# 1b) gtfsrouter ####
	library(gtfsrouter)
	gtfs_2 <- extract_gtfs(gtfs_file, T)
	gtfs_2 <- gtfs_timetable(gtfs_2, date = 20190620)

	tts_2 = gtfs_traveltimes(gtfs_2, from, start_time)

	# 2) compare ####
	tidytransit = tts_1 %>%
		select(stop_name=to_stop_name, tt_tidytransit=travel_time, transf_tidytransit = transfers)

	gtfsrouter = tts_2 %>% as_tibble() %>%
		mutate(duration = as.numeric(duration)) %>%
		select(stop_name, tt_gtfsrouter=duration, transf_gtfsrouter = ntransfers)
	gtfsrouter <- gtfsrouter %>% # keep only best travel time
		arrange(tt_gtfsrouter, transf_gtfsrouter) %>%
		group_by(stop_name) %>%
		slice_head()

	comparison = full_join(tidytransit, gtfsrouter, na_matches = "never", by = "stop_name") %>%
		mutate(diff_tt = tt_gtfsrouter-tt_tidytransit, diff_transf = transf_gtfsrouter-transf_tidytransit)

	comp_non0 = comparison %>% filter(diff_tt != 0)

	hist(comp_non0$tt_gtfsrouter - comp_non0$tt_tidytransit)
})
