#' ERA5_extract
#'
#' @param slat numeric: vector of latitudes.
#' @param slon numeric: vector of longitudes.
#' @param in.path character: path to the directory containing the file to be inserted
#' @param start_date character: start date (in YYYY-MM-DD format).
#' @param end_date character: end date (in YYYY-MM-DD format).
#' @param outfolder character: Path to directory where nc files need to be saved.
#' @param in.prefix character: initial portion of the filename that does not vary by date.
#'  Does not include directory; specify that as part of in.path.
#' @param newsite character: vector of site names. 
#'  The length should match with that of slat and slon.
#' @param vars character: names of variables to be extracted. If NULL all the variables will be
#'  returned. Default is NULL.
#' @param overwrite Logical if files needs to be overwritten.
#' @param verbose Decide if we want to stop printing info.
#' @param ... other inputs.
#' @details For the list of variables check out the documentation at \url{
#'  https://confluence.ecmwf.int/display/CKB/ERA5+data+documentation#ERA5datadocumentation-Spatialgrid}
#'
#' @return a list of xts objects with all the variables for the requested years
#' @export
#' @examples
#' \dontrun{
#' point.data <- ERA5_extract(sslat=40, slon=-120, years=c(1990:1995), vars=NULL)
#' 
#  point.data %>% 
#'  purrr::map(~xts::apply.daily(.x, mean))
#'
#' }
extract.nc.ERA5 <-
  function(slat,
           slon,
           in.path,
           start_date,
           end_date,
           outfolder,
           in.prefix,
           newsite,
           vars = NULL,
           overwrite = FALSE,
           verbose = FALSE,
           ...) {
    # initialize parallel.
    cores <- parallel::detectCores()
    cl <- parallel::makeCluster(cores)
    doSNOW::registerDoSNOW(cl)
    # initialize progress bar.
    pb <- utils::txtProgressBar(min=1, max=length(slat), style=3)
    progress <- function(n) utils::setTxtProgressBar(pb, n)
    opts <- list(progress=progress)
    # Distributing the job between whatever core is available. 
    years <- seq(lubridate::year(start_date),
                 lubridate::year(end_date),
                 1
    )
    ensemblesN <- seq(1, 10)
    final.nc.files <- vector("list", length = length(years))
    for (i in seq_along(years)) {
      # report progress.
      PEcAn.logger::logger.info(paste0("\nProcessing year ", years[i], ".\n"))
      year <- years[i]
      ncfile <- file.path(in.path, paste0(in.prefix, year, ".nc"))
      # open the file
      nc_data <- ncdf4::nc_open(ncfile)
      # time.
      t <- ncdf4::ncvar_get(nc_data, "time")
      tunits <- ncdf4::ncatt_get(nc_data, 'time')
      tustr <- strsplit(tunits$units, " ")
      timestamp <- as.POSIXct(t * 3600, tz = "UTC", origin = tustr[[1]][3])
      # set the vars
      if (is.null(vars)) {
        vars <- names(nc_data$var)
      }
      # for the variables extract the data
      if (verbose) {
        PEcAn.logger::logger.info("Extracting NC file.\n")
      }
      vname <- NULL
      all.data.point <- 
        foreach::foreach(vname = vars, 
                         .packages=c("Kendall", "ncdf4")) %dopar% {
                           ens.out <- vector("list", length = length(ensemblesN))
                           for (ens in ensemblesN) {
                             brick.tmp <-
                               raster::brick(ncfile, varname = vname, level = ens)
                             nn <-
                               raster::extract(brick.tmp,
                                               sp::SpatialPoints(cbind(slon, slat)),
                                               method = 'simple')
                             # replacing the missing/filled values with NA
                             nn[nn == nc_data$var[[vname]]$missval] <- NA
                             # send out the extracted var as a new col
                             ens.out[[ens]] <- t(nn)
                           }
                           ens.out
                         } %>% 
        purrr::set_names(vars)
      # progress bar.
      # TODO wrap into a large matrix (2928*8000*10 rows and 8 columns), and then split them into the foreach.
      if (verbose) {
        PEcAn.logger::logger.info("Converting multi-site time series to by-site data frames.\n")
      }
      pb <- utils::txtProgressBar(min = 0, max = length(slat), style = 3)
      all.site.data.point <- vector("list", length = length(slat))
      for (s.ind in seq_along(all.site.data.point)) {
        pbi <- s.ind
        utils::setTxtProgressBar(pb, pbi)
        all.site.data.point[[s.ind]] <- ensemblesN %>%
          purrr::map(function(ens) {
            s.all.data <- vars %>% 
              purrr::set_names(vars) %>% 
              purrr::map_dfc(function(vname){
                all.data.point[[vname]][[ens]][,s.ind]
              })
            s.all.data <- xts::xts(s.all.data, order.by = timestamp)
            s.all.data
          })
      }
      # Write into NC files.
      if (verbose) {
        PEcAn.logger::logger.info("Writing NC files.\n")
      }
      data.point <- NULL
      final.nc.files[[i]] <- 
        foreach::foreach(data.point = all.site.data.point, 
                         s.ind = seq_along(slat),
                         .packages=c("Kendall", "ncdf4", "PEcAn.data.atmosphere", "purrr"), 
                         .options.snow=opts) %dopar% {
                           # Calling the met2CF inside extract bc in met process met2CF comes before extract !
                           out <- met2CF.ERA5(
                             slat[s.ind],
                             slon[s.ind],
                             paste0(year,"-01-01"),
                             paste0(year,"-12-31"),
                             sitename=newsite[s.ind],
                             outfolder,
                             data.point,
                             overwrite = FALSE,
                             verbose = verbose
                           )
                           out %>% purrr::map(~.x[['file']]) %>% unlist
                         }
    }
    # stop parallel.
    close(pb)
    parallel::stopCluster(cl)
    # we only need the by-site ensemble folders for the met2model function.
    final.nc.files <- final.nc.files[[1]] %>% purrr::map(dirname)
    return(final.nc.files)
  }