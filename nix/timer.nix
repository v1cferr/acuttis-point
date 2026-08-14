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
  # when a punch is due and never on a day the rules would refuse anyway.
  times = [
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
  };
}
