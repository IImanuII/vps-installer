# Corpo del systemctl finto dei test di vps-monitor (vedi tool_env in monitor.bats).
# Un servizio è fermo se esiste $T/down.<nome>; restart lo fa ripartire, salvo
# $T/norestart.<nome>. Ogni chiamata è annotata in $T/systemctl.calls.
T="$BATS_TEST_TMPDIR"
echo "$*" >>"$T/systemctl.calls"
case "$1" in
  is-active)
    s="${!#}"
    # fotografia dello stato salvato quando si arriva a php (dopo nginx)
    if [[ "$s" == php*-fpm && -f "$MON_STATE_DIR/state.json" ]]; then cp "$MON_STATE_DIR/state.json" "$T/state.snap"; fi
    if [[ -f "$T/down.$s" ]]; then exit 3; fi
    exit 0
    ;;
  restart)
    # $T/restart.sleep: un riavvio che non finisce (exec: timeout ferma proprio sleep)
    if [[ -f "$T/restart.sleep" ]]; then exec sleep "$(cat "$T/restart.sleep")"; fi
    if [[ ! -f "$T/norestart.$2" ]]; then rm -f "$T/down.$2"; fi
    exit 0
    ;;
  *) exit 0 ;;
esac
