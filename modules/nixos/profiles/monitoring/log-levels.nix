# The two options that let a service tell the log pipeline how to read its own severity.
#
# A MODULE OF ITS OWN, not part of monitoring/client.nix, for a reason that is easy to
# rediscover the hard way: the DECLARING module and the DEFINING modules are different
# modules. Every service profile that logs its level into its message text sets one of these
# (blocky, immich, gluetun, vaultwarden, …), and a NixOS VM test imports those profiles à la
# carte rather than through the fleet bundle — so with the options living in the Vector module,
# `parts/checks/blocky-*` failed to evaluate with
#
#   The option `nodes.resolver.custom.profiles.monitoring-client' does not exist
#
# Importing this file alongside the definition makes the option travel with it. Imports are
# deduplicated by path, so the Vector module and a dozen service profiles can all import it.
#
# Nothing here reads these options; monitoring/client.nix does, and only where Vector runs. On
# a host or a test node without the monitoring client they are inert facts.
{ lib, ... }:
{
  options.custom.profiles.monitoring-client = {
    levelFromMessage = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''
        {
          "home-assistant.service" =
            "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d+ (?P<lvl>WARNING|ERROR|CRITICAL) ";
        }
      '';
      description = ''
        Units whose own severity must be read out of the MESSAGE TEXT, keyed by unit name,
        each with the regex that finds it (one named capture group, `lvl`).

        WHY THIS EXISTS. `level` is derived from journald's `PRIORITY`, which is the only
        thing journald knows — and a service that writes to stdout gets PRIORITY=6 for every
        line it ever emits, errors included. Nothing is lost in the journal (the text still
        says `ERROR`), but every query, panel and alert that selects on `level` goes blind:
        the Logs dashboard's entire Errors/Warnings half is `level:in(error,…)`, so such a
        service contributes zero to it no matter how loudly it is failing. Measured on rk1a
        before this landed: 396 Home Assistant ERROR/WARNING lines in 24h, of which
        `level:in(error,warning,critical,fatal)` returned none.

        The fix has to be per-service because the FORMAT is per-service — only the service
        knows how it spells its own severity — so a service profile declares its own pattern
        here rather than this module guessing.

        ⚠ ANCHOR THE PATTERN on the service's line prefix, never on the level word alone.
        A bare `_msg:~"ERROR"` sweep over the fleet reported blocky as the worst offender by
        two orders of magnitude — 45k lines on kelpy, 12.5k on rk1b — and every one of them
        was the substring in `response_code=NOERROR` on a perfectly ordinary query log. The
        anchored count for the same window was zero. (Blocky does hide real errors — 10,939
        of them over 30 days — but that is what the anchored pattern finds, and a sloppy one
        would have relabelled a million query logs as failures.)

        Whatever the pattern captures is mapped through a fixed table of level names, so a
        service may spell them however it likes (postgres LOG/NOTICE, go FATAL, blocky WARN)
        and an unrecognised token leaves `level` alone rather than inventing a label value.

        ⚠ Write a pattern as an INDENTED (two single quotes) string, or double every
        backslash: a regular Nix string eats `\d` into a literal `d`, which then silently
        matches nothing.

        ⚠ Lines that do not match keep their journald level. For a Python service that means
        a traceback's continuation lines stay `info` while the `ERROR` line opening it is
        promoted. Deliberate: merging them needs a stateful `reduce` transform, which buffers
        each unit's last event until the next arrives and so makes the live tail lag — and
        this is the better count anyway, since a 20-line traceback is one error, not twenty.
      '';
    };

    demoteToDebug = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = lib.literalExpression ''
        {
          "home-assistant.service" = [ "Received binary message for non-existing handler" ];
        }
      '';
      description = ''
        Message substrings, keyed by unit, that this fleet has decided are not the severity
        the service gives them. Matching lines are relabelled `debug`; the text itself is
        untouched, so `journalctl` still shows exactly what the service said.

        WHY, and WHEN NOT TO USE IT. An error view is only useful while everything in it is
        worth looking at, and a single service logging one benign condition in a loop can
        bury every real signal on the fleet — Home Assistant's websocket audio-stream race
        was 340 of its 396 daily errors. The existing `boot.isContainer` BPF block below is
        the same idea, hardcoded because it is keyed on a kernel fact rather than a unit.

        ⚠ This is the LAST resort, not the first. A flood of errors usually means something
        is genuinely wrong, and the fix is the cause: kelpy's node-exporter was logging 5760
        collector failures a day, and the answer was to switch off four collectors that
        cannot work in a container, not to relabel them. Reach for this only when the cause
        is outside our control (another party's client, a race in an upstream protocol) AND
        the condition is genuinely harmless. Every entry needs the reason written beside it
        at its declaration, and a demotion that hides a real fault is strictly worse than
        the noise it removed.

        Applied after `levelFromMessage`, so a demotion beats a promotion. Substring match,
        not regex: these are exact known messages, and a pattern here would be one more
        thing that can silently stop matching.
      '';
    };
  };
}
