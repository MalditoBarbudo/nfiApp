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
#' @param data_reactives,filter_reactives,apply_reactives,map_reactives
#'   reactives from modules
#' @param nfidb object to access the nfi db
#' @param lang lang selected
#' @param texts_thes thesaurus
#' @param parent_session parent session to be able to update tabset panel
#'
#' @importFrom dplyr n
#'
#' @export
#'
#' @rdname mod_mainDataOuput
mod_mainData <- function(
  input, output, session,
  data_reactives, filter_reactives, apply_reactives, map_reactives,
  nfidb, lang, texts_thes, parent_session
) {

  ## helpers ####
  to_matrix_list <- function(data) {
    list(as.matrix(data))
  }

  ## waiter/hostess progress ####
  # set a progress with waiter. We will use infinite TRUE, that way we dont
  # need to calculate any steps durations
  # 1. hostess progress
  hostess_progress <- waiter::Hostess$new(infinite = TRUE)
  hostess_progress$set_loader(waiter::hostess_loader(
    svg = 'images/hostess_image.svg',
    progress_type = 'fill',
    fill_direction = 'btt'
  ))


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
          ) |>
            sf::st_transform(4326)
        } else {
          # gpkg
          user_file_polygons <- sf::st_read(path_to_file) |>
            sf::st_transform(4326)
        }
      }

      shiny::validate(
        shiny::need(user_file_polygons, 'no file provided')
      )

      # check for poly_id
      if (!"poly_id" %in% names(user_file_polygons)) {
        warning('No poly_id variable found in spatial file, using first variable found as id')
        user_file_polygons$poly_id <- as.character(user_file_polygons[[1]])

        shiny::showNotification(
          ui = shiny::tagList(
            shiny::h4(text_translate("poly_id_missing_title", lang(), texts_thes))
          ),
          action = shiny::tagList(
            text_translate("poly_id_missing_message", lang(), texts_thes)
          ),
          duration = 15,
          type = "warning"
        )

      } else {
        # ensure polygon id is character (factors fuck it all)
        user_file_polygons$poly_id <- as.character(user_file_polygons$poly_id)
      }

      return(user_file_polygons)
    }

    if (admin_div == 'drawn_poly') {
      # validation
      drawn_polygon <- map_reactives$nfi_map_draw_all_features
      # When removing the features (custom polygon) the
      # input$map_draw_new_feature is not cleared, so is always filtering the
      # sites, even after removing. For that we need to control when the removed
      # feature equals the new, that's it, when we removed the last one
      shiny::validate(
        shiny::need(drawn_polygon, 'no draw polys yet'),
        shiny::need(length(drawn_polygon[['features']]) != 0, 'removed poly')
      )
      res <-
        drawn_polygon[['features']][[1]][['geometry']][['coordinates']] |>
        purrr::flatten() |>
        purrr::modify_depth(1, purrr::set_names, nm = c('long', 'lat')) |>
        dplyr::bind_rows() |>
        # {list(as.matrix(.))} |>
        to_matrix_list() |>
        sf::st_polygon() |>
        sf::st_sfc() |>
        sf::st_sf(crs = 4326) |>
        dplyr::mutate(poly_id = 'drawn_poly')
      return(res)

      # if (is.null(drawn_polygon) || length(drawn_polygon[['features']]) == 0) {
      #   return(NULL)
      # } else {
      #   res <-
      #     drawn_polygon[['features']][[1]][['geometry']][['coordinates']] |>
      #     purrr::flatten() |>
      #     purrr::modify_depth(1, purrr::set_names, nm = c('long', 'lat')) |>
      #     dplyr::bind_rows() |>
      #     {list(as.matrix(.))} |>
      #     sf::st_polygon() |>
      #     sf::st_sfc() |>
      #     sf::st_sf(crs = 4326) |>
      #     dplyr::mutate(poly_id = 'drawn_poly')
      #   return(res)
      # }
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

      # progress
      waiter_overlay <- waiter::Waiter$new(
        id = 'mod_mapOutput-nfi_map',
        html = shiny::tagList(
          hostess_progress$get_loader(),
          shiny::h3(text_translate("progress_message", lang(), texts_thes)),
          shiny::p(text_translate("progress_detail_initial", lang(), texts_thes))
        ),
        color = '#E8EAEB'
      )
      waiter_overlay$show()
      hostess_progress$start()
      on.exit(hostess_progress$close())
      on.exit(waiter_overlay$hide(), add = TRUE)

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

      # get data, join it
      first_table <-
        main_table_to_look_at(nfi, desglossament, diameter_classes) |>
        nfidb$get_data(spatial = TRUE)

      ancillary_tables <-
        ancillary_tables_to_look_at(nfi) |>
        purrr::map(~ nfidb$get_data(.x, spatial = FALSE)) |>
        purrr::reduce(dplyr::left_join, by = c('plot_id'))

      main_data_pre <- dplyr::left_join(
        first_table, ancillary_tables
      )

      if (!all(filter_reactives$filter_vars %in% names(main_data_pre))) {
        ##TODO add sweet alarm
        # shiny::validate(
        #   shiny::need(FALSE, 'filters active not in data')
        # )
        shinyWidgets::sendSweetAlert(
          session = session,
          title = text_translate(
            'active_filters_warning_title', lang(), texts_thes
          ),
          text = text_translate(
            'active_filters_warning', lang(), texts_thes
          )
        )
        main_data_table <- main_data_pre
      } else {
        main_data_table <- main_data_pre |>
          dplyr::filter(
            !!! filter_reactives$filter_expressions
          )
      }

      # sweet alert for when no results are returned by the filters
      if (nrow(main_data_table) < 1) {
        shinyWidgets::sendSweetAlert(
          session = session,
          title = text_translate(
            'sweet_alert_returned_data_title', lang(), texts_thes
          ),
          text = text_translate(
            'sweet_alert_returned_data_text', lang(), texts_thes
          )
        )
      }

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
        shiny::validate(shiny::need(custom_poly, 'no custom poly'))

        # get only the plots inside the polygons supplied
        # The logic is as follows:
        #   - get the indexes of the intersection between them
        #   - use that indexes to extract the poly_id from the custom poly
        #   - create a new column in the main data with the poly_id to summarise
        #   - later
        indexes <- sf::st_intersects(main_data_table, custom_poly) |>
          as.numeric()
        polys_names <- custom_poly |>
          dplyr::pull(poly_id) |>
          as.character() |>
          magrittr::extract(indexes)
        raw_main_data <- main_data_table |>
          dplyr::mutate(
            poly_id = polys_names
          ) |>
          dplyr::filter(!is.na(poly_id))
        # check if raw data has data
        # sweet alert for when no results are returned by the filters
        if (nrow(raw_main_data) < 1) {
          shinyWidgets::sendSweetAlert(
            session = session,
            title = text_translate(
              'sweet_alert_polygon_title', lang(), texts_thes
            ),
            text = text_translate(
              'sweet_alert_polygon_text', lang(), texts_thes
            )
          )

          shiny::validate(shiny::need(
            nrow(raw_main_data) > 0, 'polygon contains no plots'
          ))
        }
      } else {
        raw_main_data <- main_data_table
      }

      # general_summary ####
      group_by_general <- general_summary_grouping_vars(
        nfi, diameter_classes, admin_div, group_by_dom, dominant_group,
        dominant_criteria, dominant_nfi, desglossament
      )

      general_summary <- raw_main_data |>
        dplyr::as_tibble() |>
        dplyr::select(-geometry) |>
        dplyr::group_by(!!! group_by_general) |>
        dplyr::summarise(
          dplyr::across(
            tidyselect:::where(function(x) {is.numeric(x) && !all(is.na(x))}),
            list(
              mean = ~ mean(.x, na.rm = TRUE),
              se = ~ sd(.x, na.rm = TRUE)/sqrt(n()),
              min = ~ min(.x, na.rm = TRUE),
              max = ~ max(.x, na.rm = TRUE),
              n = ~ n()
            )
          )
        )

      # requested_data ####
      if (isTRUE(group_by_div)) {
        requested_data <- general_summary

      } else {
        if (!isTRUE(group_by_dom)) {
          requested_data <- raw_main_data

        } else {
          requested_data <-
            raw_main_data |>
            dplyr::as_tibble() |>
            dplyr::select(-geometry) |>
            dplyr::group_by(!!! group_by_general[2]) |>
            dplyr::summarise(
              dplyr::across(
                tidyselect:::where(function(x) {is.numeric(x) && !all(is.na(x))}),
                list(
                  mean = ~ mean(.x, na.rm = TRUE),
                  se = ~ sd(.x, na.rm = TRUE)/sqrt(n()),
                  min = ~ min(.x, na.rm = TRUE),
                  max = ~ max(.x, na.rm = TRUE),
                  n = ~ n()
                )
              )
            )
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

  # observers to update tab and update viz_fg
  shiny::observeEvent(
    eventExpr = main_data(),
    handlerExpr = {
      # update tab
      shiny::updateTabsetPanel(
        parent_session, 'sidebar_tabset', selected = 'viz_panel'
      )
    }
  )

  # reactive to return
  main_data_reactives <- shiny::reactiveValues()
  shiny::observe({
    main_data_reactives$main_data <- main_data()
    main_data_reactives$custom_polygon <- custom_polygon()
  })
  return(main_data_reactives)
}
