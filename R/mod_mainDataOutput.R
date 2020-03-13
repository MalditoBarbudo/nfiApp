#' @title mod_mainDataOutput and mod_mainData
#'
#' @description Shiny module to get the data as tbl_sql
#'
#' @param id
#'
#' @export
mod_mainDataOutput <- function(id) {
  ns <- shiny::NS(id)
  return()
}

#' @title mod_mainData server function
#'
#' @param input internal
#' @param output internal
#' @param session internal
#'
#' @param data_reactives reactives from dataInput module
#' @param filter_reactives filter reactives
#' @param nfidb object to access the nfi db#'
#' @param lang lang selected
#' @param texts_thes thesaurus
#'
#' @import tidyNFI
#' @importFrom dplyr n
#'
#' @export
#'
#' @rdname mod_mainDataOuput
mod_mainData <- function(
  input, output, session,
  data_reactives, filter_reactives, apply_reactives,
  nfidb, lang, texts_thes
) {

  # custom polygon ####
  # we need to check if custom polygon, to retrieve it and build the data later
  custom_polygon <- shiny::reactive({

    admin_div <- data_reactives$admin_div
    path_to_file <- data_reactives$user_file_sel$datapath

    # file
    if (admin_div == 'file') {
      # check if there is user file
      if (is.null(path_to_file)) {
        user_file_polygons <- NULL
      } else {
        # check if zip (shapefile) or gpkg to load the data
        if (stringr::str_detect(path_to_file, 'zip')) {
          tmp_folder <- tempdir()
          utils::unzip(path_to_file, exdir = tmp_folder)

          user_file_polygons <- sf::st_read(
            list.files(tmp_folder, '.shp', recursive = TRUE, full.names = TRUE),
            as_tibble = TRUE
          ) %>%
            sf::st_transform(4326)
        } else {
          # gpkg
          user_file_polygons <- sf::st_read(path_to_file) %>%
            sf::st_transform(4326)
        }
      }

      shiny::validate(
        shiny::need(user_file_polygons, 'no file provided')
      )

      # rename the poly_id
      names(user_file_polygons)[1] <- 'poly_id'

      return(user_file_polygons)
    }

    if (admin_div == 'drawn_poly') {
      # When removing the features (custom polygon) the input$map_draw_new_feature
      # is not cleared, so is always filtering the sites, even after removing. For
      # that we need to control when the removed feature equals the new, that's it,
      # when we removed the last one
      drawn_polygon <- map_reactives$map_draw_all_features
      if (is.null(drawn_polygon) || length(drawn_polygon[['features']]) == 0) {
        return(NULL)
      } else {
        res <-
          drawn_polygon[['features']][[1]][['geometry']][['coordinates']] %>%
          purrr::flatten() %>%
          purrr::modify_depth(1, purrr::set_names, nm = c('long', 'lat')) %>%
          dplyr::bind_rows() %>%
          {list(as.matrix(.))} %>%
          sf::st_polygon() %>%
          sf::st_sfc() %>%
          sf::st_sf(crs = 4326)
        return(res)
      }
    }
  })

  # main data ####
  # we have all we need to retrieve the main data. The map will need other
  # transformations (summarising...), and we need inputs now is convoluted
  # to do (like draw polygons or file inputs). Let's retrieve the main data,
  # and lets delegate the data transformations to the places they are needed
  main_data <- shiny::eventReactive(
    eventExpr = apply_reactives$apply_button,
    valueExpr = {

      # set a progress
      progress <- shiny::Progress$new(session, min = 0, max = 100)
      on.exit(progress$close())
      progress$set(
        message = 'Calculation in progress',
        detail = 'This may take a while...'
      )

      # tables to look at
      nfi <- data_reactives$nfi
      desglossament <- data_reactives$desglossament
      diameter_classes <- data_reactives$diameter_classes
      # get the needed inputs to know which summarise to do
      admin_div <- data_reactives$admin_div # indicates the polygon to summarise
      group_by_div <- data_reactives$group_by_div # indicates if summ by div
      group_by_dom <- data_reactives$group_by_dom # indicates if summ by dom
      dominant_group <- data_reactives$dominant_group # which dominant group
      dominant_criteria <- data_reactives$dominant_criteria # which criteria
      dominant_nfi <- data_reactives$dominant_nfi # which nfi dom if needed
      user_file_sel <- data_reactives$user_file_sel # file info

      tables_to_look_at <- c(
        main_table_to_look_at(nfi, desglossament, diameter_classes),
        ancillary_tables_to_look_at(nfi)
      )

      message(as.character(filter_reactives$filter_expressions))

      progress$set(value = 5)

      # get data, join it
      main_data_table <-
        tables_to_look_at %>%
        purrr::map(~ nfidb$get_data(., spatial = FALSE)) %>%
        purrr::walk(
          ~ progress$set(value = 15)
        ) %>%
        purrr::reduce(dplyr::left_join, by = c('plot_id')) %>%
        dplyr::filter(
          !!! filter_reactives$filter_expressions
        ) %>%
        dplyr::left_join(
          nfidb$get_data(tables_to_look_at[1], spatial = TRUE) %>%
            dplyr::select(plot_id, geometry),
          by = 'plot_id'
        ) %>%
        sf::st_as_sf(sf_column_name = 'geometry')

      # sweet alert for when no results are returned by the filters
      if (nrow(main_data_table) < 1) {
        shinyWidgets::sendSweetAlert(
          session = session,
          title = text_translate('sweet_alert_returned_data_title', lang, texts_thes),
          text = text_translate('sweet_alert_returned_data_text', lang, texts_thes)
        )
      }

      progress$set(value = 45)

      # validate to see if we can continue
      shiny::validate(
        shiny::need(nrow(main_data_table) > 0, 'filters too restrictive')
      )

      # processed_data
      # The idea here is to collect the main data, and summarise it as needed.
      # For that we will need map inputs (custom poly). The file input is
      # already in data inputs.
      # Logic is as follows:
      #   - raw_main_data is main data in plots.
      #     Only changes if there is a custom poly (it has to be filtered by the
      #     intersection).
      #   - general_summary is the needed data for info in maps (raw data only
      #     summarised by the main inputs: desglossament, admin_div/poly_id,
      #     diam_classes), and, if stated, by the dominance group
      #   - requested_data is the data as requested by the user, for map
      #     plotting, table building, viz inputs?. This is really simple, when
      #     knowing what happen:
      #     if group_by_div, then is the same as general_summary. There we
      #     already have the dispatching of grouping variables checked
      #     if not group_by_div, is raw data except the only case when
      #     group_by_dom, where we only need to summarise the totals by dom
      #   - Therefore, based on the inputs we can build a function that
      #     returns the grouping variables needed, as the summarising step
      #     is always the same.

      # raw_main_data ####
      if (admin_div %in% c('file', 'drawn_poly')) {
        # get the custom polygon with the reactive
        custom_poly <- custom_polygon()

        # get only the plots inside the polygons supplied
        # The logic is as follows:
        #   - get the indexes of the intersection between them
        #   - use that indexes to extract the poly_id from the custom poly
        #   - create a new column in the main data with the poly_id to summarise
        #   - later
        indexes <- sf::st_intersects(main_data_table, custom_poly) %>%
          as.numeric()
        polys_names <- custom_poly %>%
          dplyr::pull(poly_id) %>%
          as.character() %>%
          magrittr::extract(indexes)
        raw_main_data <- main_data_table %>%
          dplyr::mutate(
            poly_id = polys_names
          ) %>%
          dplyr::filter(!is.na(poly_id))
        # check if raw data has data
        shiny::validate(shiny::need(
          nrow(raw_main_data) > 0, 'polygon contains no plots'
        ))
        progress$set(value = 55)
      } else {
        raw_main_data <- main_data_table
        progress$set(value = 55)
      }

      # general_summary ####
      group_by_general <- general_summary_grouping_vars(
        nfi, diameter_classes, admin_div, group_by_dom, dominant_group,
        dominant_criteria, dominant_nfi, desglossament
      )
      general_summary <- raw_main_data %>%
        dplyr::group_by(!!! group_by_general) %>%
        dplyr::summarise_if(
          .predicate = is.numeric,
          .funs = list(
            mean = ~ mean(., na.rm = TRUE),
            se = ~ sd(., na.rm = TRUE)/sqrt(n()),
            min = ~ min(., na.rm = TRUE),
            max = ~ max(., na.rm = TRUE),
            n = ~ n()
          )
        )
      progress$set(value = 75)

      # requested_data ####
      if (isTRUE(group_by_div)) {
        requested_data <- general_summary
        progress$set(value = 95)
      } else {
        if (!isTRUE(group_by_dom)) {
          requested_data <- raw_main_data
          progress$set(value = 95)
        } else {
          requested_data <-
            raw_main_data %>%
            dplyr::group_by(!!! group_by_general[2]) %>%
            dplyr::summarise_if(
              .predicate = is.numeric,
              .funs = list(
                mean = ~ mean(., na.rm = TRUE),
                se = ~ sd(., na.rm = TRUE)/sqrt(n()),
                min = ~ min(., na.rm = TRUE),
                max = ~ max(., na.rm = TRUE),
                n = ~ n()
              )
            )
          progress$set(value = 95)
        }
      }

      res <- list(
        main_data = raw_main_data,
        general_summary = general_summary,
        requested_data = requested_data
      )

      return(res)
    }
  )


  # reactive to return
  main_data_reactives <- shiny::reactiveValues()
  shiny::observe({
    main_data_reactives$main_data <- main_data()
  })
  return(main_data_reactives)
}