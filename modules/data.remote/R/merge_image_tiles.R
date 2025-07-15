#' Merge image tiles to a single image (currently support hdf and tif image format).
#' @details
#' Please refer to the gdalwarp manual for more details
#' https://gdal.org/en/stable/programs/gdalwarp.html
#' 
#' @param folder.path character: physical path to the folder that contains all the image tiles.
#' @param keep.files Boolean: if we want to keep the image tiles at the end.
#' @param image.settings list: settings used during exporting merged image.
#' Such as image coordinate system (crs), dimension, extents (ext), and average function (fun).
#' @param computation list: settings used for configuring computation.
#' Such as maximum memory per CPU (GDAL_CACHEMAX), percentage of total memory (wm),
#' number of CPUs (NUM_THREADS), compress method (COMPRESS).
#'
#' @return character: file path to the merged GeoTIFF file.
#' @export
#' 
#' @author Dongchen Zhang
merge_image_tiles <- function(folder.path, 
                              keep.files = FALSE, 
                              image.settings = list(crs = "EPSG:4326",
                                                    dimension = NULL,
                                                    ext = NULL,
                                                    fun = NULL),
                              computation = list(GDAL_CACHEMAX = 1000,                                                        
                                                 wm = "80%",                                                        
                                                 NUM_THREADS = 16,                                                        
                                                 COMPRESS = "DEFLATE")) {
  if (!is.null(base.map)) {
    ext <- terra::ext(base.map)
    crs <- terra::crs(base.map, proj = TRUE)
    dim <- dim(base.map)[2:1]
  }
  # convert hdf to tif.
  if (all(grepl(".hdf", list.files(folder.path)))) {
    hdf.files <- list.files(folder.path, pattern = "*.hdf", full.names = T)
    for (ff in hdf.files) {
      temp <- terra::rast(ff)
      terra::writeRaster(temp, gsub(".hdf", ".tif", ff), overwrite = T)
      unlink(ff)
    }
  }
  # write job.sh script.
  # insert image settings.
  gdal.cmd <- "gdalwarp"
  # output coordinate system.
  if (!is.null(image.settings$crs)) {
    gdal.cmd <- paste(gdal.cmd, "-t_srs", image.settings$crs)
  }
  # output image dimension (=resolution).
  if (!is.null(image.settings$dimension)) {
    gdal.cmd <- paste(gdal.cmd, "-ts", paste(image.settings$dimension, collapse = " "))
  }
  # output image extents (in xmin, ymin, xmax, ymax order).
  if (!is.null(image.settings$ext)) {
    gdal.cmd <- paste(gdal.cmd, "-te", paste(image.settings$ext[c(1, 3, 2, 4)], collapse = " "))
  }
  # average function used to upscale image.
  if (!is.null(image.settings$fun)) {
    gdal.cmd <- paste(gdal.cmd, "-r", image.settings$fun)
  }
  # insert computation settings.
  if (any(!is.null(unlist(computation)))) {
    gdal.cmd <- paste(gdal.cmd, "--config")
  }
  # memory usage per CPU.
  if (!is.null(computation$GDAL_CACHEMAX)) {
    gdal.cmd <- paste(gdal.cmd, "GDAL_CACHEMAX", computation$GDAL_CACHEMAX)
  }
  # total memory usage.
  if (!is.null(computation$wm)) {
    gdal.cmd <- paste(gdal.cmd, "-wm", computation$wm)
  }
  # how many CPUs will be used.
  if (!is.null(computation$NUM_THREADS)) {
    gdal.cmd <- paste(gdal.cmd, paste0("-multi -wo -NUM_THREADS=", computation$NUM_THREADS))
  }
  # image compress method.
  if (!is.null(computation$COMPRESS)) {
    gdal.cmd <- paste(gdal.cmd, paste0("-co COMPRESS=", computation$COMPRESS))
  }
  gdal.cmd <- paste(gdal.cmd, "-co BIGTIFF=YES -co TILED=TRUE @VRT@ @FINALTIFF@")
  cmd <- c("#!/bin/bash -l", 
           "module load gdal", 
           "gdalbuildvrt @VRT@ @TIF@",
           gdal.cmd)
  cmd <- gsub("@VRT@", file.path(folder.path, "index.vrt"), cmd)
  cmd <- gsub("@TIF@", file.path(folder.path, "*.tif"), cmd)
  cmd <- gsub("@FINALTIFF@", file.path(folder.path, paste0("merged_image.tif")), cmd)
  writeLines(cmd, con = file.path(folder.path, "job.sh"))
  # grand permissions to the job file.
  cmd <- "chmod 744 @JOBFILE@"
  cmd <- gsub("@JOBFILE@", file.path(folder.path, "job.sh"), cmd)
  out <- system(cmd, intern = TRUE)
  # enter the folder and run the job file.
  cmd <- 'cd \"@JOBPATH@\";./job.sh'
  cmd <- gsub(pattern = "@JOBPATH@", replacement = folder.path, x = cmd)
  out <- system(cmd, intern = TRUE)
  # remove files.
  if (!keep.files) {
    unlink(list.files(folder.path, full.names = T)[which(!grepl(paste0(basename(folder.path), ".tif"), list.files(folder.path)))], recursive = T)
  }
  return(file.path(folder.path, paste0("merged_image.tif")))
}