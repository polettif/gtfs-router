#' gtfs_isochrone
#'
#' Calculate a single isochrone from a given start station, returning the list
#' of all stations reachable to the specified `end_time`.
#'
#' @param gtfs A set of GTFS data returned from \link{extract_gtfs} or, for more
#' efficient queries, pre-processed with \link{gtfs_timetable}.
#' @param from Name of start station
#' @param start_time Desired departure time at `from` station, either in seconds
#' after midnight, a vector of two or three integers (hours, minutes) or (hours,
#' minutes, seconds), an object of class \link{difftime}, \pkg{hms}, or
#' \pkg{lubridate}.
#' @param end_time End time to calculate isochrone
#' @param route_pattern Using only those routes matching given pattern, for
#' example, "^U" for routes starting with "U" (as commonly used for underground
#' or subway routes. (Parameter not used at all if `gtfs` has already been
#' prepared with \link{gtfs_timetable}.)
#' @param hull_alpha alpha value of non-convex hulls returned as part of result
#' (see ?alphashape::ashape for details).
#'
#' @inheritParams gtfs_route
#'
#' @return An object of class `gtfs_isochrone`, including \pkg{sf}-formatted
#' points representing the `from` station (`start_point`), the terminal end
#' stations (`end_points`), and all intermediate stations (`mid_points`), along
#' with lines representing the individual routes. A non-convex ("alpha") hull is
#' also returned (as an \pkg{sf} `POLYGON` object), including measures of area
#' and "elongation", which equals zero for a circle, and increases towards one
#' for more elongated shapes.
#'
#' @examples
#' berlin_gtfs_to_zip ()
#' f <- file.path (tempdir (), "vbb.zip")
#' g <- extract_gtfs (f)
#' g <- gtfs_timetable (g)
#' from <- "Alexanderplatz"
#' start_time <- 12 * 3600 + 600
#' end_time <- start_time + 600
#' ic <- gtfs_isochrone (g,
#'                       from = from,
#'                       start_time = start_time,
#'                       end_time = end_time)
#' \dontrun{
#' plot (ic)
#' }
#' @export 
gtfs_isochrone <- function (gtfs, from, start_time, end_time, day = NULL,
                            route_pattern = NULL, hull_alpha = 0.1, quiet = FALSE)
{
    requireNamespace ("geodist")
    requireNamespace ("lwgeom")

    if (!"timetable" %in% names (gtfs))
        gtfs <- gtfs_timetable (gtfs, day, route_pattern, quiet = quiet)

    gtfs_cp <- data.table::copy (gtfs)

    # no visible binding note:
    departure_time <- NULL

    start_time <- convert_time (start_time)
    end_time <- convert_time (end_time)
    gtfs_cp$timetable <- gtfs_cp$timetable [departure_time >= start_time, ]
    if (nrow (gtfs_cp$timetable) == 0)
        stop ("There are no scheduled services after that time.")

    stations <- NULL # no visible binding note
    start_stns <- station_name_to_ids (from, gtfs_cp)

    isotrips <- get_isotrips (gtfs_cp, start_stns, start_time, end_time)

    routes <- route_to_linestring (isotrips$isotrips)
    xy <- as.numeric (isotrips$isotrips [[1]] [1, c ("stop_lon", "stop_lat")])
    startpt <- sf::st_sfc (sf::st_point (xy), crs = 4326)
    nm <- isotrips$isotrips [[1]] [1, "stop_name"]
    startpt <- sf::st_sf ("stop_name" = nm, geometry = startpt)

    hull <- NULL
    if (length (isotrips$isotrips) > 1)
        hull <- isohull (isotrips$isotrips, hull_alpha = hull_alpha)

    res <- list (start_point = startpt,
                 mid_points = route_midpoints (isotrips$isotrips),
                 end_points = route_endpoints (isotrips$isotrips),
                 routes = routes,
                 hull = hull,
                 start_time = isotrips$start_time,
                 end_time = isotrips$end_time)

    class (res) <- c ("gtfs_isochrone", class (res))
    return (res)
}

get_isotrips <- function (gtfs, start_stns, start_time, end_time)
{
    # no visible binding note:
    stop_id <- trip_id <- NULL

    stns <- rcpp_csa_isochrone (gtfs$timetable, gtfs$transfers,
                                nrow (gtfs$stop_ids), nrow (gtfs$trip_ids),
                                start_stns, start_time, end_time)
    if (length (stns) < 2)
        stop ("No isochrone possible") # nocov

    actual_start_time <- as.numeric (stns [length (stns)])

    index <- 2 * 1:((length (stns) - 1) / 2) - 1
    trips <- stns [index + 1]
    stns <- stns [index]

    stop_ids <- lapply (stns, function (i) gtfs$stop_ids [i] [, stop_ids])
    trip_ids <- lapply (trips, function (i) gtfs$trip_ids [i] [, trip_ids])

    isotrips <- lapply (seq (stop_ids), function (i)
                   {
        stops <- gtfs$stops [match (stop_ids [[i]], gtfs$stops [, stop_id]), ]
        trips <- gtfs$trips [match (trip_ids [[i]], gtfs$trips [, trip_id]), ]
        data.frame (cbind (stops [, c ("stop_id", "stop_name", "parent_station",
                                       "stop_lon", "stop_lat")]),
                    cbind (trips [, c ("route_id", "trip_id", "trip_headsign")]))
                   })

    list (isotrips = isotrips,
          start_time = actual_start_time,
          end_time = actual_start_time + end_time - start_time)
}

# convert list of data.frames of stops and trips into sf linestrings for each route
route_to_linestring <- function (x)
{
    # split each route into trip IDs
    xsp <- list ()
    for (i in x)
        xsp <- c (xsp, split (i, f = as.factor (i$trip_id)))
    names (xsp) <- NULL
    # remove the trip info so unique sequences of stops can be identified
    xsp <- lapply (xsp, function (i) {
                       i [c ("route_id", "trip_id", "trip_headsign")] <- NULL
                       return (i)
                   })
    xsp <- xsp [!duplicated (xsp)]
    lens <- vapply (xsp, nrow, numeric (1))
    xsp <- xsp [which (lens > 1)]

    # Then determine which sequences are sub-sequences of others already present
    lens <- vapply (xsp, nrow, numeric (1))
    xsp <- xsp [order (lens)]
    # paste all sequences of stop_ids
    stop_seqs <- vapply (xsp, function (i) paste0 (i$stop_id, collapse = ""),
                         character (1))
    # then find the longest sequence matching each - this can be done with a
    # simple "max" because of the above ordering by length
    index <- unlist (lapply (stop_seqs, function (i) max (grep (i, stop_seqs))))
    xsp <- xsp [sort (unique (index))]

    # Then convert to linestring geometries
    xy <- lapply (xsp, function (i)
                  sf::st_linestring (cbind (i$stop_lon, i$stop_lat)))
    sf::st_sfc (xy, crs = 4326)
}

# extract endpoints of each route as sf point objects
route_endpoints <- function (x)
{
    xy <- lapply (x, function (i)
                  as.numeric (i [nrow (i), c ("stop_lon", "stop_lat")]))
    xy <- do.call (rbind, xy)
    xy <- data.frame ("x" = xy [, 1], "y" = xy [, 2])
    g <- sf::st_as_sf (xy, coords = 1:2, crs = 4326)$geometry
    nms <- vapply (x, function (i)
                  i [nrow (i), "stop_name"], character (1))
    sf::st_sf ("stop_name" = nms, geometry = g)
}

route_midpoints <- function (x)
{
    xy <- lapply (x, function (i)
                  as.matrix (i [2:(nrow (i) - 1), c ("stop_lon", "stop_lat")]))
    xy <- do.call (rbind, xy)
    xy <- data.frame ("x" = xy [, 1], "y" = xy [, 2])
    g <- sf::st_as_sf (xy, coords = 1:2, crs = 4326)$geometry
    nms <- lapply (x, function (i)
                  i [2:(nrow (i) - 1), "stop_name"])
    sf::st_sf ("stop_name" = do.call (c, nms), geometry = g)
}

# x is isolines
isohull <- function (x, hull_alpha)
{
    xy <- lapply (x, function (i)
                  as.matrix (i [, c ("stop_lon", "stop_lat")]))
    xy <- do.call (rbind, xy)
    if (length (which (!duplicated (xy))) < 3)
        return (NULL) # nocov
    hull <- get_ahull (xy, alpha = hull_alpha)
    if (nrow (hull) < 3)
        return (NULL) # nocov

    hull <- rbind (hull, hull [1, ])

    bdry <- sf::st_polygon (list (as.matrix (hull [, 2:3])))
    geometry <- sf::st_sfc (bdry, crs = 4326)
    sf::st_sf (area = sf::st_area (geometry),
               elongation = 1 - hull_ratio (geometry),
               geometry = geometry)
}

# ratio of lengths of minor / major axes of the hull
hull_ratio <- function (x)
{
    xy <- sf::st_coordinates (x)
    d <- geodist::geodist (xy)
    d [lower.tri (d)] <- 0
    i <- which.max (apply (d, 1, max))
    j <- which.max (apply (d, 2, max))
    major_axis <- rbind (xy [i, c ("X", "Y")],
                         xy [j, c ("X", "Y")])
    major_axis <- sf::st_sfc (sf::st_linestring (major_axis), crs = 4326)
    index <- seq (nrow (xy)) [!seq (nrow (xy)) %in% c (i, j)]
    pts <- sf::st_as_sf (data.frame (xy [index, ]), coords = 1:2, crs = 4326)

    minor_axis_dist <- as.numeric (max (sf::st_distance (pts, major_axis)))
    minor_axis_dist / max (d)
}

get_ahull <- function (x, alpha = alpha)
{
    x <- x [!duplicated (x), ]
    alpha <- 0.1
    a <- data.frame (alphahull::ashape (x, alpha = alpha)$edges)

    xy <- rbind (data.frame (ind = a$ind1, x = a$x1, y = a$y1),
                 data.frame (ind = a$ind2, x = a$x2, y = a$y2))
    xy <- xy [!duplicated (xy), ]
    xy <- xy [order (xy$ind), ]
    inds <- data.frame (ind1 = a$ind1, ind2 = a$ind2)
    # Wrap those indices around xy:
    # TODO: Find a better way to do this!
    ind_seq <- as.numeric (inds [1, ])
    inds <- inds [-1, ]
    while (nrow (inds) > 0)
    {
        j <- which (inds$ind1 == utils::tail (ind_seq, n = 1))
        if (length (j) > 0)
        {
            ind_seq <- c (ind_seq, inds [j, 2])
        } else
        {
            j <- which (inds$ind2 == utils::tail (ind_seq, n = 1))
            ind_seq <- c (ind_seq, inds [j, 1])
        }
        inds <- inds [-j, , drop = FALSE] #nolint
    }
    xy [match (ind_seq, xy$ind), ]
}

#' plot.gtfs_isochrone
#'
#' @name plot.gtfs_ischrone
#' @param x object to be plotted
#' @param ... ignored here
#' @export
plot.gtfs_isochrone <- function (x, ...)
{
    requireNamespace ("sf")
    requireNamespace ("alphahull")
    requireNamespace ("mapview")

    allpts <- rbind (x$start_pt, x$mid_points, x$end_points)

    m <- mapview::mapview (allpts, color = "grey", cex = 3, legend = FALSE)
    m <- mapview::addFeatures (m, x$hull, color = "orange", alpha.regions = 0.2)
    m <- mapview::addFeatures (m, x$routes, colour = "blue")
    m <- mapview::addFeatures (m, x$start_point, radius = 5, color = "green")
    m <- mapview::addFeatures (m, x$end_points, radius = 4, color = "red",
                               fill = TRUE, fillOpacity = 0.8, fillColor = "red")

    print (m)
    invisible (m)
}
