gtfs_file = "routing.zip"
download.file("https://github.com/polettif/gtfs-test-feeds/raw/master/zip/routing.zip", gtfs_file)
start_time = 7*3600
from_name = "One"

# tidytransit
library(tidytransit)
library(dplyr)
gtfs_1 <- read_gtfs(gtfs_file)

timetable_1 = filter_stop_times(gtfs_1, "2018-10-01", start_time, 24*3600)
tts_1 = travel_times(timetable_1, from_name)

# gtfsrouter
library(gtfsrouter)
packageVersion("gtfsrouter")
gtfs_2 <- extract_gtfs(gtfs_file, T)
gtfs_2 <- gtfs_timetable(gtfs_2, date = 20181001)

tts_2 = gtfs_traveltimes(gtfs_2, from_name, start_time)

# compare
tidytransit = tts_1 %>%
	select(stop_name=to_stop_name, tt_tidytransit=travel_time, transf_tidytransit = transfers)

gtfsrouter = tts_2 %>% as_tibble() %>%
	mutate(duration = as.numeric(duration)) %>%
	select(stop_name, tt_gtfsrouter=duration, transf_gtfsrouter = ntransfers)
# keep only best travel time
gtfsrouter <- gtfsrouter %>%
	arrange(tt_gtfsrouter, transf_gtfsrouter) %>%
	group_by(stop_name) %>%
	slice_head() %>% ungroup()

comparison = full_join(tidytransit, gtfsrouter, na_matches = "never", by = "stop_name") %>%
	mutate(diff_tt = tt_gtfsrouter-tt_tidytransit, diff_transf = transf_gtfsrouter-transf_tidytransit) %>%
	filter(diff_tt != 0 | diff_transf != 0)

hist(comparison$tt_gtfsrouter - comparison$tt_tidytransit)

# explore
tidytransit %>% arrange(stop_name)
gtfsrouter %>% arrange(stop_name)
