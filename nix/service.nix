{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.acuttis-point;

  timeType = lib.types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]";

  dateType = lib.types.strMatching "[0-9]{4}-[0-9]{2}-[0-9]{2}";

  weekdayType = lib.types.enum [
    "MON"
    "TUE"
    "WED"
    "THU"
    "FRI"
    "SAT"
    "SUN"
  ];

  boolean = value: if value then "true" else "false";
in
{
  options.services.acuttis-point = {
    enable = lib.mkEnableOption "the Acuttis timekeeping automation";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The acuttis-point package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "acuttis-point";
      description = "User the automation runs as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "acuttis-point";
      description = "Group the automation runs as.";
    };

    # The schedule is declared once, here: the service reads it as environment
    # variables and the timer turns the same times into OnCalendar entries, so
    # the two cannot drift apart.
    schedule = {
      entry = lib.mkOption {
        type = timeType;
        example = "08:00";
        description = "Time the first punch of the day is due.";
      };

      lunchStart = lib.mkOption {
        type = timeType;
        example = "12:00";
        description = "Time the lunch break punch is due.";
      };

      lunchEnd = lib.mkOption {
        type = timeType;
        example = "14:00";
        description = "Time the return from lunch punch is due.";
      };

      exit = lib.mkOption {
        type = timeType;
        example = "17:30";
        description = "Time the last punch of the day is due.";
      };
    };

    workDays = lib.mkOption {
      type = lib.types.nonEmptyListOf weekdayType;
      default = [
        "MON"
        "TUE"
        "WED"
        "THU"
        "FRI"
      ];
      description = "Days the automation may act on.";
    };

    toleranceMinutes = lib.mkOption {
      type = lib.types.ints.between 0 240;
      default = 10;
      description = ''
        How many minutes after a scheduled time a punch may still be registered.
        Outside this window a run aborts instead of registering a time that no
        longer reflects reality, which is also what makes a catch-up run after a
        suspend safe.
      '';
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/Sao_Paulo";
      description = "IANA timezone the schedule is written in.";
    };

    skipDates = lib.mkOption {
      type = lib.types.listOf dateType;
      default = [ ];
      example = [ "2026-09-07" ];
      description = "Holidays, vacation and other days without an expedient.";
    };

    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decide and log, but never register a punch.";
    };

    punchListSelector = lib.mkOption {
      type = lib.types.nonEmptyStr;
      example = ".punch-row";
      description = ''
        Selector matching one element per punch already registered today, in the
        order Acuttis lists them. It has no default because reading the wrong
        elements is how a punch ends up registered against the wrong event.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      example = "/run/secrets/acuttis-point";
      description = ''
        File holding ACUTTIS_USERNAME and ACUTTIS_PASSWORD, read by systemd at
        start. Point this at a sops-nix or agenix secret; it must not be a path
        inside the Nix store, which is world readable.
      '';
    };

    logFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/lib/acuttis-point/runs.log";
      description = ''
        File the block-formatted run records are appended to. The one-line form
        always goes to the journal. Set to null to keep only the journal; a path
        outside the state directory needs its own ReadWritePaths entry.
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        PUNCH_TRIGGER_SELECTOR = "button.open-punch";
      };
      description = "Extra environment variables, for the remaining selectors.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !lib.hasPrefix builtins.storeDir (toString cfg.environmentFile);
        message = ''
          services.acuttis-point.environmentFile must not be in the Nix store:
          everything there is world readable.
        '';
      }
    ];

    users.users = lib.mkIf (cfg.user == "acuttis-point") {
      acuttis-point = {
        isSystemUser = true;
        group = cfg.group;
        description = "Acuttis timekeeping automation";
      };
    };

    users.groups = lib.mkIf (cfg.group == "acuttis-point") {
      acuttis-point = { };
    };

    systemd.services.acuttis-point = {
      description = "Register the timekeeping punch due now on Acuttis";
      # Started by the timer only. A punch outside its window is refused
      # anyway, so nothing is lost by not running at boot.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        ENTRY_TIME = cfg.schedule.entry;
        LUNCH_START = cfg.schedule.lunchStart;
        LUNCH_END = cfg.schedule.lunchEnd;
        EXIT_TIME = cfg.schedule.exit;
        WORK_DAYS = lib.concatStringsSep "," cfg.workDays;
        TIME_TOLERANCE_MINUTES = toString cfg.toleranceMinutes;
        TIMEZONE = cfg.timezone;
        SKIP_DATES = lib.concatStringsSep "," cfg.skipDates;
        DRY_RUN = boolean cfg.dryRun;
        HEADLESS = "true";
        PUNCH_LIST_SELECTOR = cfg.punchListSelector;
        # Chromium wants somewhere to put its profile and crash dumps.
        HOME = "/var/lib/acuttis-point";
      }
      // lib.optionalAttrs (cfg.logFile != null) { LOG_FILE = cfg.logFile; }
      // cfg.extraEnvironment;

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe cfg.package;
        EnvironmentFile = cfg.environmentFile;
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "acuttis-point";
        WorkingDirectory = "/var/lib/acuttis-point";

        # A refusal exits 2 and a failure exits 1, so both show the unit red,
        # which is the point: those are the runs that want a human.
        SuccessExitStatus = [ 0 ];

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        # Chromium sandboxes itself with user namespaces and needs /dev/shm, so
        # the tighter sandboxing options are deliberately left off.
      };
    };

    environment.systemPackages = [ cfg.package ];
  };
}
