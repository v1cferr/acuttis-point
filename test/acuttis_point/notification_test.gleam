import acuttis_point/clock
import acuttis_point/config
import acuttis_point/decision
import acuttis_point/notification
import acuttis_point/pending
import acuttis_point/preflight
import acuttis_point/ptbr
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/state

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn moment(time: String) -> clock.Instant {
  let assert Ok(date) = clock.parse_date("2026-08-14")
  clock.Instant(date: date, time: at(time))
}

fn registered() -> report.Report {
  report.Decided(
    at: moment("07:57"),
    state: state.Waiting(punch.Entry),
    decision: decision.Register(punch: punch.Entry, expected_at: at("07:51")),
    // The day as Acuttis shows it after the punch, which is what the runner
    // reports: the confirmation is a second read, not a hope.
    registered: [state.Registered(punch: punch.Entry, at: at("07:57"))],
    outcome: report.Confirmed(at: at("07:57")),
  )
}

fn nothing_to_do() -> report.Report {
  report.Decided(
    at: moment("08:00"),
    state: state.Waiting(punch.LunchStart),
    decision: decision.Skip(decision.AlreadyRegistered(
      punch: punch.Entry,
      at: at("07:57"),
    )),
    registered: [],
    outcome: report.NothingToDo,
  )
}

fn refused() -> report.Report {
  report.Decided(
    at: moment("10:30"),
    state: state.Waiting(punch.Entry),
    decision: decision.Abort(decision.WindowClosed(
      punch: punch.Entry,
      expected_at: at("07:51"),
      minutes_late: 159,
    )),
    registered: [],
    outcome: report.Refused,
  )
}

fn broke() -> report.Report {
  report.Broke(
    at: moment("07:57"),
    stage: report.Authenticating,
    detail: "acuttis rejected the sign in",
  )
}

// In Portuguese, and in the words Gestão de Pessoas uses in its own e-mails, so
// what arrives on the phone can be compared to Acuttis without translating
// anything first.
pub fn a_registered_punch_says_which_and_when_test() {
  assert notification.from_report(registered())
    == notification.Notification(
      title: "Ponto batido: entrada",
      body: "bati a entrada às 07:57. Hoje: entrada 07:57",
      // High: this is the message that stops the same punch being made again at
      // the totem in the building.
      priority: "high",
      tags: "white_check_mark",
      action: Error(Nil),
    )
}

pub fn a_problem_arrives_at_high_priority_test() {
  let failed = notification.from_report(broke())
  assert failed.title == "Ponto NÃO foi batido"
  assert failed.body
    == "Falhou ao fazer login no Acuttis: acuttis rejected the sign in"
  assert failed.priority == "high"
  assert failed.tags == "warning"

  let refusal = notification.from_report(refused())
  assert refusal.title == "Ponto NÃO foi batido"
  assert refusal.body
    == "a entrada era às 07:51 e já passou 159 min, tarde para registrar sem"
    <> " mentir a hora"
  assert refusal.priority == "high"
}

// Low priority arrives without a sound, which is what a run with nothing to do
// deserves if it is sent at all.
pub fn nothing_to_do_arrives_quietly_test() {
  let quiet = notification.from_report(nothing_to_do())
  assert quiet.title == "Nada a fazer"
  assert quiet.body == "a entrada já consta às 07:57"
  assert quiet.priority == "low"
}

pub fn a_dry_run_says_it_registered_nothing_test() {
  let withheld =
    notification.from_report(report.Decided(
      at: moment("07:57"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("07:51")),
      registered: [],
      outcome: report.Withheld,
    ))
  assert withheld.body == "a entrada era agora, e DRY_RUN está ligado"
}

pub fn the_reason_comes_from_the_decision_test() {
  // The rule is still the only source of the reason — the notification renders
  // it in Portuguese rather than restating it, so the two cannot disagree about
  // WHY, only about which language says so.
  let record = refused()
  let assert report.Decided(decision: chosen, ..) = record
  let assert decision.Abort(reason) = chosen
  assert notification.from_report(record).body == ptbr.abort_reason(reason)
}

pub fn always_sends_everything_test() {
  assert notification.wanted(notification.Always, registered())
  assert notification.wanted(notification.Always, nothing_to_do())
  assert notification.wanted(notification.Always, refused())
  assert notification.wanted(notification.Always, broke())
}

pub fn action_stays_quiet_when_there_was_nothing_to_do_test() {
  assert notification.wanted(notification.OnAction, registered())
  assert notification.wanted(notification.OnAction, refused())
  assert notification.wanted(notification.OnAction, broke())
  assert !notification.wanted(notification.OnAction, nothing_to_do())
}

pub fn problem_sends_only_failures_and_refusals_test() {
  assert notification.wanted(notification.OnProblem, refused())
  assert notification.wanted(notification.OnProblem, broke())
  assert !notification.wanted(notification.OnProblem, registered())
  assert !notification.wanted(notification.OnProblem, nothing_to_do())
}

pub fn a_confirmation_failure_is_a_problem_test() {
  let record =
    report.Decided(
      at: moment("07:57"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("07:51")),
      registered: [],
      outcome: report.Failed(
        stage: report.ConfirmingPunch,
        detail: "acuttis does not show ENTRY after registering it",
      ),
    )
  assert notification.wanted(notification.OnProblem, record)
  assert notification.from_report(record).priority == "high"
}

pub fn parse_trigger_names_the_three_modes_test() {
  assert notification.parse_trigger("always") == Ok(notification.Always)
  assert notification.parse_trigger("action") == Ok(notification.OnAction)
  assert notification.parse_trigger("problem") == Ok(notification.OnProblem)
  assert notification.parse_trigger("sometimes")
    == Error("sometimes is not one of always, action, problem")
}

// "Tudo pronto para a retorno do almoço" went to a real phone on the first day
// this ran. Three of the four punch names are feminine and one is not, so any
// sentence built from a bare noun gets one of them wrong.
pub fn the_portuguese_agrees_with_the_punch_it_names_test() {
  assert ptbr.punch_with_article(punch.Entry) == "a entrada"
  assert ptbr.punch_with_article(punch.LunchStart) == "a saída para o almoço"
  assert ptbr.punch_with_article(punch.LunchEnd) == "o retorno do almoço"
  assert ptbr.punch_with_article(punch.Exit) == "a saída"

  // And the sentences built from it read as Portuguese for every one of them.
  let ready = fn(missing) {
    notification.from_preflight(
      preflight.Ready(
        at: moment("12:20"),
        day: state.Waiting(missing),
        registered: [],
      ),
    ).title
  }
  assert ready(punch.LunchEnd) == "Tudo pronto para o retorno do almoço"
  assert ready(punch.Exit) == "Tudo pronto para a saída"

  let done = fn(kind) {
    notification.from_report(report.Decided(
      at: moment("13:52"),
      state: state.Waiting(kind),
      decision: decision.Register(punch: kind, expected_at: at("13:51")),
      registered: [state.Registered(punch: kind, at: at("13:52"))],
      outcome: report.Confirmed(at: at("13:52")),
    )).body
  }
  assert done(punch.LunchEnd)
    == "bati o retorno do almoço às 13:52. Hoje: retorno do almoço 13:52"
}

// The one notification that asks instead of telling, and the safety net stated
// in the body: a tap nobody makes costs a later punch, not a missing one.
pub fn an_offer_carries_a_button_and_says_what_happens_without_it_test() {
  let offer =
    notification.from_report(report.Decided(
      at: moment("12:35"),
      state: state.Waiting(punch.LunchStart),
      decision: decision.Register(
        punch: punch.LunchStart,
        expected_at: at("12:35"),
      ),
      registered: [state.Registered(punch: punch.Entry, at: at("07:59"))],
      outcome: report.Offered(
        token: "abc123",
        expires_at: at("12:45"),
        repeated: False,
      ),
    ))

  assert offer.title == "Bater a saída para o almoço?"
  assert offer.body
    == "Toque para bater agora. Se não tocar, eu bato sozinho às 12:45."
    <> " Hoje: entrada 07:59"
  assert offer.priority == "high"
  assert offer.action
    == Ok(notification.Action(label: "Bater agora", command: "punch abc123"))

  // An offer is something happening, so the default trigger sends it.
  let record =
    report.Decided(
      at: moment("12:35"),
      state: state.Waiting(punch.LunchStart),
      decision: decision.Register(
        punch: punch.LunchStart,
        expected_at: at("12:35"),
      ),
      registered: [],
      outcome: report.Offered(
        token: "abc123",
        expires_at: at("12:45"),
        repeated: False,
      ),
    )
  assert notification.wanted(notification.OnAction, record)
  // And it is not a problem, so the problem-only trigger stays quiet.
  assert !notification.wanted(notification.OnProblem, record)
}

// A reminder is not a repeat of the question. It says what is still true, at a
// priority that gets through, and holds out the same token — the notification
// already on the phone is the one most likely to be tapped.
pub fn a_reminder_escalates_and_keeps_the_same_button_test() {
  let remind = fn(repeated) {
    notification.from_report(report.Decided(
      at: moment("12:41"),
      state: state.Waiting(punch.LunchStart),
      decision: decision.Register(
        punch: punch.LunchStart,
        expected_at: at("12:35"),
      ),
      registered: [state.Registered(punch: punch.Entry, at: at("07:59"))],
      outcome: report.Offered(
        token: "abc123",
        expires_at: at("12:45"),
        repeated: repeated,
      ),
    ))
  }

  let first = remind(False)
  assert first.title == "Bater a saída para o almoço?"
  assert first.priority == "high"

  let again = remind(True)
  assert again.title == "AINDA falta bater a saída para o almoço"
  assert again.priority == "urgent"
  // The same button, so an older notification still works.
  assert again.action == first.action
}

// The confirmation is the only thing standing between a punch made here and the
// same punch made again at the totem in the building. It is not a quiet message.
pub fn a_confirmed_punch_is_loud_test() {
  let done = notification.from_report(registered())
  assert done.priority == "high"
  assert done.title == "Ponto batido: entrada"
}

// A tap that cannot be honoured still gets an answer. Silence is what sends
// somebody to the totem in the building to make sure, and that second marking is
// the whole problem.
pub fn a_tap_that_cannot_be_honoured_still_answers_test() {
  let schedule =
    config.Schedule(
      entry: at("07:51"),
      lunch_start: at("12:35"),
      lunch_end: at("13:51"),
      exit: at("17:30"),
    )

  // Tapping the entry notification again, mid morning: already honoured, and the
  // reply says what comes next without touching Acuttis to find out.
  let again =
    notification.from_declined(
      pending.NothingPending,
      config.next_scheduled(schedule, at("08:30")),
    )
  assert again.title == "Esse pedido já foi atendido"
  assert again.body
    == "Nada foi registrado agora. O próximo é a saída para o almoço, às 12:35."
  assert again.priority == "low"
  assert again.action == Error(Nil)

  // An old notification tapped long after its window closed.
  let stale =
    notification.from_declined(
      pending.Expired(expired_at: at("08:01")),
      config.next_scheduled(schedule, at("10:00")),
    )
  assert stale.title == "Esse pedido expirou às 08:01"
  assert stale.body
    == "Nada foi registrado agora. O próximo é a saída para o almoço, às 12:35."

  // And after the last punch of the day there is nothing to promise.
  let done =
    notification.from_declined(
      pending.NothingPending,
      config.next_scheduled(schedule, at("18:00")),
    )
  assert done.body
    == "Nada foi registrado agora. Não há mais nada para bater hoje."
}

// The schedule alone answers "what is next", so a stale tap costs no browser.
pub fn the_next_punch_comes_from_the_schedule_test() {
  let schedule =
    config.Schedule(
      entry: at("07:51"),
      lunch_start: at("12:35"),
      lunch_end: at("13:51"),
      exit: at("17:30"),
    )

  assert config.next_scheduled(schedule, at("00:00"))
    == Ok(#(punch.Entry, at("07:51")))
  assert config.next_scheduled(schedule, at("07:51"))
    == Ok(#(punch.LunchStart, at("12:35")))
  assert config.next_scheduled(schedule, at("13:00"))
    == Ok(#(punch.LunchEnd, at("13:51")))
  assert config.next_scheduled(schedule, at("17:30")) == Error(Nil)
}
