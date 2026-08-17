{ config, lib, ... }:
let
  cfg = config.services.acuttis-point;

  # WORK_DAYS uses the three letter codes the application reads; systemd wants
  # them capitalised its own way.
  systemdDay = {
    MON = "Mon";
    TUE = "Tue";
    WED = "Wed";
    THU = "Thu";
    FRI = "Fri";
    SAT = "Sat";
    SUN = "Sun";
  };

  days = lib.concatStringsSep "," (map (day: systemdDay.${day}) cfg.workDays);

  # The same times the service reads as its schedule, so the timer fires exactly
  # when a punch is due and never on a day the rules would refuse anyway. The
  # sweep rides along on the same timer: it is the same program, and by its hour
  # every window has closed, so it can only report.
  times =
    [
      cfg.schedule.entry
      cfg.schedule.lunchStart
      cfg.schedule.lunchEnd
      cfg.schedule.exit
    ]
    ++ lib.optional (cfg.sweepTime != null) cfg.sweepTime;

  # toIntBase10, not toInt: an HH:MM is always zero padded, and lib.toInt calls
  # "07" ambiguous between octal and decimal and throws rather than choose.
  minutes = time: lib.toIntBase10 (lib.substring 0 2 time) * 60 + lib.toIntBase10 (lib.substring 3 2 time);

  pad = number: lib.fixedWidthNumber 2 number;

  # A lead reaching back past midnight is refused by an assertion in the service
  # module, which is where the explanation belongs. Yielding nothing here rather
  # than a negative hour only keeps that assertion the message the user sees,
  # instead of a fixedWidthString complaint from somewhere inside lib.
  ahead =
    time:
    let
      total = minutes time - cfg.preflightLeadMinutes;
    in
    lib.optional (total >= 0) "${pad (total / 60)}:${pad (lib.mod total 60)}";

  # The punches only. Rehearsing the sweep would be rehearsing a report: by its
  # hour every window has closed and there is no punch left to be ready for.
  rehearsals = lib.concatMap ahead [
    cfg.schedule.entry
    cfg.schedule.lunchStart
    cfg.schedule.lunchEnd
    cfg.schedule.exit
  ];
in
{
  config = lib.mkIf cfg.enable {
    systemd.timers.acuttis-point = {
      description = "Timekeeping punches due today on Acuttis";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = map (time: "${days} *-*-* ${time}:00") times;
        Unit = "acuttis-point.service";

        # Close enough to the mark that the tolerance window does most of the
        # work rather than being spent on timer slack.
        AccuracySec = "1s";

        # Only ever a delay, never an advance, which is what decides how the
        # schedule has to be written. See the option's description.
        RandomizedDelaySec = cfg.jitterSeconds;

        # A machine asleep at the scheduled minute runs on resume instead of
        # skipping the punch. This is only safe because a run that resumes too
        # late refuses to register anything: the tolerance window, not the
        # timer, is what decides whether a catch-up is honest.
        Persistent = true;
      };
    };

    systemd.timers.acuttis-point-preflight = lib.mkIf (cfg.preflightLeadMinutes > 0) {
      description = "Rehearsals ahead of today's Acuttis punches";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = map (time: "${days} *-*-* ${time}:00") rehearsals;
        Unit = "acuttis-point-preflight.service";
        AccuracySec = "1s";

        # No RandomizedDelaySec, unlike the punch timer: the punch drifts up to
        # jitterSeconds later, and a rehearsal free to drift the same way could
        # land inside the window it is supposed to run ahead of.

        # And no Persistent either. A rehearsal is only worth anything before its
        # punch; running one on resume, after the window it warned about had
        # already closed, would be reporting the weather for yesterday.
        Persistent = false;
      };
    };
  };
}
