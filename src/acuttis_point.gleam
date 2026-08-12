//// One run of the automation.
////
//// Reads the environment, resolves the current moment in the configured
//// timezone, hands the Playwright adapter to the runner and writes down what
//// happened. Everything interesting lives in the modules below this one; this
//// is only the wiring.

import acuttis_point/clock
import acuttis_point/config
import acuttis_point/credentials
import acuttis_point/playwright
import acuttis_point/report
import acuttis_point/runner
import acuttis_point/selectors
import acuttis_point/system
import gleam/dict.{type Dict}
import gleam/io
import gleam/javascript/promise
import gleam/result
import gleam/string

type Setup {
  Setup(
    settings: config.Config,
    secrets: credentials.Credentials,
    page_selectors: selectors.Selectors,
    now: clock.Instant,
  )
}

pub fn main() -> Nil {
  let environment = system.environment()
  let env = environment.values
  let log = log_file(env)

  // Where configuration came from is worth saying out loud: a `.env` picked up
  // from a working directory should never be a surprise.
  case environment.dotenv {
    Ok(path) -> io.println("acuttis-point: read " <> path)
    Error(Nil) -> Nil
  }

  case setup(env) {
    Error(detail) -> report_bad_setup(log, detail)
    Ok(setup) -> {
      io.println(
        "acuttis-point: "
        <> config.describe(setup.settings)
        <> " "
        <> credentials.to_string(setup.secrets),
      )

      let _ =
        runner.run(
          settings: setup.settings,
          secrets: setup.secrets,
          now: setup.now,
          port: playwright.port(setup.settings, setup.page_selectors),
        )
        |> promise.map(emit(log, _))

      // The promise keeps the process alive; the exit status is set once it
      // settles, so buffered output has already reached the journal.
      Nil
    }
  }
}

/// Errors collapse to a string here because the only thing left to do with them
/// is write them down.
fn setup(env: Dict(String, String)) -> Result(Setup, String) {
  use settings <- result.try(
    config.from_env(env)
    |> result.map_error(config.error_to_string),
  )
  use secrets <- result.try(
    credentials.from_env(env)
    |> result.map_error(credentials.error_to_string),
  )
  use page_selectors <- result.try(
    selectors.from_env(env)
    |> result.map_error(selectors.error_to_string),
  )
  use now <- result.try(
    system.now(settings.timezone)
    |> result.map_error(system.error_to_string),
  )

  Ok(Setup(
    settings: settings,
    secrets: secrets,
    page_selectors: page_selectors,
    now: now,
  ))
}

/// The configuration is what failed, so its timezone cannot be trusted for the
/// timestamp. UTC still gives the record an honest one.
fn report_bad_setup(log: Result(String, Nil), detail: String) -> Nil {
  case system.now("UTC") {
    Ok(now) ->
      emit(
        log,
        report.Broke(
          at: now,
          stage: report.ReadingConfiguration,
          detail: detail,
        ),
      )
    Error(_) -> {
      io.println("acuttis-point: " <> detail)
      system.set_exit_status(1)
    }
  }
}

fn emit(log: Result(String, Nil), record: report.Report) -> Nil {
  // One line to stdout, which under systemd is the journal.
  io.println(report.to_line(record))

  case log {
    Error(Nil) -> Nil
    Ok(path) ->
      // A blank line after each block, so the file stays readable.
      case system.append_line(path, report.to_text(record) <> "\n") {
        Ok(Nil) -> Nil
        Error(error) ->
          io.println("acuttis-point: " <> system.error_to_string(error))
      }
  }

  system.set_exit_status(report.exit_code(record))
}

/// Read straight from the environment rather than from `Config`, so that a
/// configuration error still reaches the log file.
fn log_file(env: Dict(String, String)) -> Result(String, Nil) {
  case dict.get(env, "LOG_FILE") {
    Error(Nil) -> Error(Nil)
    Ok(path) ->
      case string.trim(path) {
        "" -> Error(Nil)
        trimmed -> Ok(trimmed)
      }
  }
}
