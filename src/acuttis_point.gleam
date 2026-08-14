//// One run of the automation.
////
//// Reads the environment, resolves the current moment in the configured
//// timezone, hands the Playwright adapter to the runner and writes down what
//// happened. Everything interesting lives in the modules below this one; this
//// is only the wiring.

import acuttis_point/clock
import acuttis_point/config
import acuttis_point/credentials
import acuttis_point/discovery
import acuttis_point/notification
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

/// Where a run record goes once it exists.
type Outputs {
  Outputs(
    log: Result(String, Nil),
    notify_url: Result(String, Nil),
    notify_on: notification.Trigger,
  )
}

pub fn main() -> Nil {
  let environment = system.environment()
  let env = environment.values
  let out = outputs(env)

  // Where configuration came from is worth saying out loud: a `.env` picked up
  // from a working directory should never be a surprise.
  case environment.dotenv {
    Ok(path) -> io.println("acuttis-point: read " <> path)
    Error(Nil) -> Nil
  }

  case setup(env) {
    Error(detail) -> report_bad_setup(out, detail)
    Ok(setup) -> {
      io.println(
        "acuttis-point: "
        <> config.describe(setup.settings)
        <> " "
        <> credentials.to_string(setup.secrets),
      )

      let port = playwright.port(setup.settings, setup.page_selectors)

      let _ = case setup.settings.discover {
        True ->
          discovery.discover(secrets: setup.secrets, now: setup.now, port: port)
          |> promise.map(announce)
        False ->
          runner.run(
            settings: setup.settings,
            secrets: setup.secrets,
            now: setup.now,
            port: port,
          )
          |> promise.await(fn(finished) {
            emit(out, finished.report)
            send(out, finished.report, finished.screenshot)
          })
      }

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
  use now <- result.try(
    system.now(settings.timezone)
    |> result.map_error(system.error_to_string),
  )

  Ok(Setup(
    settings: settings,
    secrets: secrets,
    page_selectors: selectors.from_env(env),
    now: now,
  ))
}

/// The configuration is what failed, so its timezone cannot be trusted for the
/// timestamp. UTC still gives the record an honest one.
fn report_bad_setup(out: Outputs, detail: String) -> Nil {
  case system.now("UTC") {
    Ok(now) -> {
      let record =
        report.Broke(
          at: now,
          stage: report.ReadingConfiguration,
          detail: detail,
        )
      emit(out, record)
      // A configuration error means no punch happened at all, which is exactly
      // when a notification earns its keep.
      let _ = send(out, record, Error(Nil))
      Nil
    }
    Error(_) -> {
      io.println("acuttis-point: " <> detail)
      system.set_exit_status(1)
    }
  }
}

/// Failing to notify never changes a run's outcome: the punch has already
/// happened or not, and a message that did not arrive does not change which.
fn send(
  out: Outputs,
  record: report.Report,
  screenshot: Result(String, Nil),
) -> promise.Promise(Nil) {
  case out.notify_url {
    Error(Nil) -> promise.resolve(Nil)
    Ok(url) ->
      case notification.wanted(out.notify_on, record) {
        False -> promise.resolve(Nil)
        True -> {
          let message = notification.from_report(record)
          use sent <- promise.await(system.notify(
            url: url,
            title: message.title,
            body: message.body,
            priority: message.priority,
            tags: message.tags,
            // ntfy takes an attachment as the request body, so a screenshot
            // rides along with the message instead of arriving separately.
            attachment: screenshot,
          ))
          case sent {
            Ok(Nil) -> Nil
            Error(error) ->
              io.println("acuttis-point: " <> system.error_to_string(error))
          }
          promise.resolve(Nil)
        }
      }
  }
}

/// A discovery run produces no record: nothing happened to record. It goes to
/// stdout only.
fn announce(found: discovery.Discovery) -> Nil {
  io.println(discovery.to_text(found))
  system.set_exit_status(discovery.exit_code(found))
}

fn emit(out: Outputs, record: report.Report) -> Nil {
  // One line to stdout, which under systemd is the journal.
  io.println(report.to_line(record))

  case out.log {
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
/// configuration error still reaches the log file and the phone.
fn outputs(env: Dict(String, String)) -> Outputs {
  let notify_on = case present(env, "NOTIFY_ON") {
    Error(Nil) -> notification.OnAction
    Ok(raw) ->
      case notification.parse_trigger(raw) {
        Ok(trigger) -> trigger
        Error(detail) -> {
          io.println("acuttis-point: NOTIFY_ON " <> detail <> ", using action")
          notification.OnAction
        }
      }
  }

  Outputs(
    log: present(env, "LOG_FILE"),
    notify_url: present(env, "NOTIFY_URL"),
    notify_on: notify_on,
  )
}

fn present(env: Dict(String, String), key: String) -> Result(String, Nil) {
  case dict.get(env, key) {
    Error(Nil) -> Error(Nil)
    Ok(value) ->
      case string.trim(value) {
        "" -> Error(Nil)
        trimmed -> Ok(trimmed)
      }
  }
}
