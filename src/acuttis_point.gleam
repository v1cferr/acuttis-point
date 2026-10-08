//// One run of the automation.
////
//// Reads the environment, resolves the current moment in the configured
//// timezone, hands the Playwright adapter to the runner and writes down what
//// happened. Everything interesting lives in the modules below this one; this
//// is only the wiring.

import acuttis_point/authorised
import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/config
import acuttis_point/credentials
import acuttis_point/decision
import acuttis_point/discovery
import acuttis_point/holiday
import acuttis_point/notification
import acuttis_point/pending
import acuttis_point/playwright
import acuttis_point/preflight
import acuttis_point/punch
import acuttis_point/question
import acuttis_point/report
import acuttis_point/runner
import acuttis_point/selectors
import acuttis_point/system
import acuttis_point/timesheet
import gleam/dict.{type Dict}
import gleam/int
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
    /// What this run did with an answer to a calendar question, if it was
    /// carrying one at all.
    answered: question.Answered,
  )
}

/// Where a run record goes once it exists.
type Outputs {
  Outputs(
    log: Result(String, Nil),
    notify_url: Result(String, Nil),
    notify_on: notification.Trigger,
    /// Where a tapped button publishes to. Read straight from the environment
    /// like the rest of this, so even a configuration error can offer one.
    command_url: Result(String, Nil),
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

      let _ = case setup.answered {
        // An answer that could not be taken stops here: it reads a local file
        // and sends a message, and there is nothing for Acuttis in it.
        question.Refused(reason) -> {
          io.println(
            "acuttis-point: refused that answer, "
            <> question.error_to_string(reason),
          )
          system.set_exit_status(2)
          refused_answer(out, reason)
        }
        question.NotAnswering | question.Accepted(_) ->
          run_normally(out, setup, port)
      }

      // The promise keeps the process alive; the exit status is set once it
      // settles, so buffered output has already reached the journal.
      Nil
    }
  }
}

fn run_normally(
  out: Outputs,
  setup: Setup,
  port: browser.Port(playwright.Session),
) -> promise.Promise(Nil) {
  case setup.settings.discover, setup.settings.preflight, setup.settings.audit {
    // Reading the whole timesheet and saying which days do not add up.
    // Touches no punch control at all.
    _, _, True ->
      timesheet.inspect(
        secrets: setup.secrets,
        now: setup.now,
        port: port,
        announced: setup.settings.announced_file,
        daily_minutes: setup.settings.daily_minutes,
        tolerance_minutes: setup.settings.tolerance_minutes,
        min_lunch_minutes: setup.settings.min_lunch_minutes,
        limit_minutes: setup.settings.compensation_limit_minutes,
        alarm_minutes: setup.settings.bank_alarm_minutes,
        carried: setup.settings.carried_bank,
        calendar: setup.settings.calendar,
      )
      |> promise.await(fn(inspected) {
        io.println(timesheet.to_line(inspected))
        io.println(timesheet.to_text(inspected))
        system.set_exit_status(timesheet.exit_code(inspected))
        use told <- promise.await(audited(out, inspected))
        // Remembered only once it has actually been said out loud. A day
        // written down as announced but never sent is a day dropped in
        // silence, which is the one outcome this whole feature exists to
        // prevent.
        case told {
          True -> timesheet.remember(inspected, setup.settings.announced_file)
          False -> Nil
        }
        promise.resolve(Nil)
      })
    True, _, _ ->
      discovery.discover(secrets: setup.secrets, now: setup.now, port: port)
      |> promise.map(announce)
    _, True, _ ->
      preflight.check(secrets: setup.secrets, now: setup.now, port: port)
      |> promise.await(fn(checked) {
        io.println(preflight.to_line(checked))
        system.set_exit_status(preflight.exit_code(checked))
        rehearsal(out, checked)
      })
    _, _, _ ->
      case claimant(setup.settings.claim) {
        // Spending a token that was offered earlier: a tap on the phone, or
        // the deadline covering a tap nobody made.
        Ok(offered) ->
          authorised.run(
            settings: setup.settings,
            secrets: setup.secrets,
            now: setup.now,
            port: port,
            offered: offered,
          )
          |> promise.await(fn(done) {
            io.println(authorised.to_line(done))
            system.set_exit_status(authorised.exit_code(done))
            case done {
              authorised.Ran(finished:) -> {
                log(out, finished.report)
                send(out, finished.report, finished.screenshot)
              }
              // A declined claim is not a run, but it is still an answer
              // owed: a tap that does nothing and says nothing is how
              // somebody ends up at the totem making a second marking.
              authorised.Declined(reason:, ..) ->
                declined(
                  out,
                  reason,
                  config.next_scheduled(setup.settings.schedule, setup.now.time),
                )
            }
          })
        Error(Nil) ->
          runner.run(
            settings: setup.settings,
            secrets: setup.secrets,
            now: setup.now,
            port: port,
          )
          |> promise.await(fn(finished) {
            emit(out, finished.report)
            use _ <- promise.await(send(
              out,
              finished.report,
              finished.screenshot,
            ))
            ask_about_calendar(out, setup, finished.report)
          })
      }
  }
}

/// A day the calendar called off used to be silent, and silence is what made
/// being wrong about it expensive: four punches nobody made and nobody heard
/// about. So it asks — once, quietly, with a button for the one answer that
/// changes anything.
///
/// Recorded only once the question has actually gone out. A question written
/// down but never sent is a day that stays silent and now cannot ask again,
/// which is the failure this exists to prevent, wearing a different hat.
fn ask_about_calendar(
  out: Outputs,
  setup: Setup,
  record: report.Report,
) -> promise.Promise(Nil) {
  case worth_asking(setup, record) {
    Error(Nil) -> promise.resolve(Nil)
    Ok(reason) -> {
      let token = pending.fresh_token()
      let message =
        notification.calendar_question(
          date: setup.now.date,
          reason: reason,
          token: token,
        )

      use sent <- promise.await(deliver(out, message))
      case sent {
        False -> Nil
        True -> {
          let _ =
            system.append_line(
              setup.settings.questions_file,
              question.to_line(question.Question(
                date: setup.now.date,
                token: token,
              )),
            )
          Nil
        }
      }
      promise.resolve(Nil)
    }
  }
}

fn worth_asking(
  setup: Setup,
  record: report.Report,
) -> Result(holiday.Reason, Nil) {
  case setup.settings.ask_about_calendar, record {
    False, _ -> Error(Nil)
    True,
      report.Decided(
        decision: decision.Skip(decision.NonWorkingDate(reason:, ..)),
        ..,
      )
    ->
      case
        question.asked(
          system.read_or_empty(setup.settings.questions_file),
          on: setup.now.date,
        )
      {
        True -> Error(Nil)
        False -> Ok(reason)
      }
    True, _ -> Error(Nil)
  }
}

/// Every tap gets a reply, including an answer that could not be honoured.
fn refused_answer(
  out: Outputs,
  reason: question.AnswerError,
) -> promise.Promise(Nil) {
  deliver(out, notification.from_refused_answer(reason))
  |> promise.map(fn(_) { Nil })
}

/// Send a message that was composed rather than derived from a run record, and
/// say whether it went out. Failing to notify never changes an outcome.
fn deliver(
  out: Outputs,
  message: notification.Notification,
) -> promise.Promise(Bool) {
  case out.notify_url {
    Error(Nil) -> promise.resolve(False)
    Ok(url) -> {
      use sent <- promise.await(system.notify(
        url: url,
        title: message.title,
        body: message.body,
        priority: message.priority,
        tags: message.tags,
        attachment: Error(Nil),
        action: button(message),
        command_url: out.command_url,
      ))
      case sent {
        Ok(Nil) -> promise.resolve(True)
        Error(error) -> {
          io.println("acuttis-point: " <> system.error_to_string(error))
          promise.resolve(False)
        }
      }
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

  // The holidays that cannot be derived, as `scripts/calendar.sh` left them.
  // Read here rather than in `config`, which stays a pure function of the
  // environment — and read from a FILE rather than from the network, because
  // an API that is slow at 07:51 must not get a say in whether a punch happens.
  let published =
    holiday.parse_published(system.read_or_empty(settings.local_holidays_file))
  let settings =
    config.Config(
      ..settings,
      calendar: holiday.with_published(settings.calendar, published),
    )

  case holiday.reaches(published, clock.year(now.date)), published.unreadable {
    True, 0 -> Nil
    reaches, unreadable -> {
      case reaches {
        True -> Nil
        False ->
          io.println(
            "acuttis-point: "
            <> settings.local_holidays_file
            <> " has no holiday in "
            <> int.to_string(clock.year(now.date))
            <> " or later; the municipal and state ones are missing until"
            <> " scripts/calendar.sh is run again",
          )
      }
      case unreadable {
        0 -> Nil
        count ->
          io.println(
            "acuttis-point: "
            <> int.to_string(count)
            <> " line(s) of "
            <> settings.local_holidays_file
            <> " could not be read and were ignored",
          )
      }
    }
  }

  // An answer to a calendar question, when the listener handed this run one.
  // Taken before the calendar is finished, because changing what the calendar
  // says about today is the entire purpose of the answer.
  let answered = case settings.answer {
    Error(Nil) -> question.NotAnswering
    Ok(token) ->
      question.answer(
        contents: system.read_or_empty(settings.questions_file),
        token: token,
        today: now.date,
      )
  }
  case answered {
    question.Accepted(date) -> {
      let _ =
        system.append_line(settings.expedient_file, clock.date_to_string(date))
      Nil
    }
    question.NotAnswering | question.Refused(_) -> Nil
  }

  // Read after that append, so the answer counts for the run that carried it
  // rather than only for the next one.
  let settings =
    config.Config(
      ..settings,
      calendar: holiday.Calendar(
        ..settings.calendar,
        with_expedient: holiday.parse_dates(system.read_or_empty(
          settings.expedient_file,
        )),
      ),
    )

  Ok(Setup(
    settings: settings,
    secrets: secrets,
    page_selectors: selectors.from_env(env),
    now: now,
    answered: answered,
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
            action: button(message),
            command_url: out.command_url,
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

/// A rehearsal is worth hearing about either way, so it ignores NOTIFY_ON: the
/// whole request was to be told, ahead of time, that the punch will work.
fn rehearsal(
  out: Outputs,
  checked: preflight.Preflight,
) -> promise.Promise(Nil) {
  case out.notify_url {
    Error(Nil) -> promise.resolve(Nil)
    Ok(url) -> {
      let message = notification.from_preflight(checked)
      use sent <- promise.await(system.notify(
        url: url,
        title: message.title,
        body: message.body,
        priority: message.priority,
        tags: message.tags,
        attachment: Error(Nil),
        action: button(message),
        command_url: out.command_url,
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

/// Whether this run is here to spend a token, and with what.
///
/// `Error(Nil)` means it is not a claiming run at all, which is different from
/// `Ok(Error(Nil))` — the deadline, which claims whatever is pending.
fn claimant(claim: config.Claim) -> Result(Result(String, Nil), Nil) {
  case claim {
    config.NoClaim -> Error(Nil)
    config.WithToken(token) -> Ok(Ok(token))
    config.AtDeadline -> Ok(Error(Nil))
  }
}

/// The notification's button, flattened to the pair the system layer takes.
fn button(
  message: notification.Notification,
) -> Result(#(String, String), Nil) {
  case message.action {
    Ok(notification.Action(label:, command:)) -> Ok(#(label, command))
    Error(Nil) -> Error(Nil)
  }
}

/// Every tap gets a reply, including the ones that could not be honoured.
fn declined(
  out: Outputs,
  reason: pending.ClaimError,
  next: Result(#(punch.Punch, clock.TimeOfDay), Nil),
) -> promise.Promise(Nil) {
  case out.notify_url {
    Error(Nil) -> promise.resolve(Nil)
    Ok(url) -> {
      let message = notification.from_declined(reason, next)
      use sent <- promise.await(system.notify(
        url: url,
        title: message.title,
        body: message.body,
        priority: message.priority,
        tags: message.tags,
        attachment: Error(Nil),
        action: Error(Nil),
        command_url: out.command_url,
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

/// An audit notifies whenever it found something new, ignoring NOTIFY_ON for the
/// same reason a rehearsal does: being told is the entire point of running it.
///
/// Returns whether the message actually went out, because the caller records the
/// days it announced and must not record days nobody heard about.
fn audited(
  out: Outputs,
  inspected: timesheet.Inspection,
) -> promise.Promise(Bool) {
  case out.notify_url {
    Error(Nil) -> promise.resolve(False)
    Ok(url) -> {
      let message = notification.from_inspection(inspected)
      use sent <- promise.await(system.notify(
        url: url,
        title: message.title,
        body: message.body,
        priority: message.priority,
        tags: message.tags,
        attachment: Error(Nil),
        action: button(message),
        command_url: out.command_url,
      ))
      case sent {
        Ok(Nil) -> promise.resolve(True)
        Error(error) -> {
          io.println("acuttis-point: " <> system.error_to_string(error))
          promise.resolve(False)
        }
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
  log(out, record)
  system.set_exit_status(report.exit_code(record))
}

/// The log file only. Split out because a claiming run has already printed its
/// own line and set its own status — the record still belongs in the file, but
/// printing it twice would make the journal read like two runs.
fn log(out: Outputs, record: report.Report) -> Nil {
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
    command_url: present(env, "COMMAND_URL"),
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
