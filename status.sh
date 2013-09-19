#!/bin/sh

base=$(basename "$0")
lib=$(cd $(dirname "$0"); pwd)
. "$lib/common.sh"

help() {
    cat <<EOF
Usage: $base OPTIONS <domain>
Options:
  -v           Verbose messages.
  -c <config>  Load named configuration.
  -f <file>    Load configuration from file.
  -w           Watch status until the current operation has been finished.
Arguments:
  <domain>     The domain name.
Configuration:
  status_domain='$status_domain'
  var='$var'
  etc='$etc'
  lib='$lib'
EOF
    exit $1
}

parsing=1
while [ $parsing = 1 ] && [ -n "$1" ]; do
    case "$1" in
    -v|--verbose)
        verbose_level=$(( $verbose_level + 1 )); shift
        ;;
    -c|--config)
        shift; conf="$1"; shift
        ;;
    -f|--config-file)
        shift; conf_file="$1"; shift
        ;;
    -w|--watch)
        watch=1; shift
        ;;
    *)
        dom="$1"; shift
        ;;
    esac
done

dom="${dom:-$status_domain}"
[ -n "$dom" ] || help 1

log_level=0
ok="[0;32m"
ko="[m"
ng="[0;31m"
gn="[m"

ok() {
    echo "$ok$@$ko"
}

ng() {
    echo "$ng$@$gn"
}

die() {
    ng "$@"
    exit 1
}

check_lock() {
    try_lock "$1" && sleep 0.2 && try_lock "$1" && return 0
    return 1
}

parse_pid() {
    sed 's/^.*\(#[0-9]*\).*$/\1/'
}

find_last_active() {
    e=$(mktemp)
    grep "end : $1" "$2" | parse_pid > "$e"
    grep "start : $1" "$2" | parse_pid | while read p; do
        grep "$p" "$e" >/dev/null || echo "$p"
    done | tail -1
    rm "$e"
}

ng_pattern() {
    echo 's/^'$1'[^[]*\[[^]]*'$2'\] \([^:]*\) :\(.*\)$/'$ng'\\1:\\2'$gn'/p'
}

show_action() {
    _pat='s/^[^[]*\[[^]]*'$1'\] \([^:]*\) :.*$/'$ok'\1'$ko'/p; d'
    _pat=$(ng_pattern F "$1")"; $_pat"
    _pat=$(ng_pattern E "$1")"; $_pat"
    _pat=$(ng_pattern W "$1")"; $_pat"
    sed "$_pat"
}

watch_status() {
    tail -n 1 --pid="$1" -f "$2" | show_action "$3"
}

[ -n "$conf" ]          && load_config "$dom" "$conf"
[ -n "$conf_file" ]     && load_config_file "$conf_file"
[ -n "$config_loaded" ] || load_config "$dom" status

test -t 1 || { # STDOUT is not a terminal
    ok=''
    ko=''
    ng=''
    gn=''
}

check_lock "$dom" && {
    ok "ready"
    exit
}

log_file="$var_prefix/log/virt-snapshot.log"
[ -r "$log_file" ] || die "Cannot read '$log_file'"
running=$(find_last_active "$dom" "$log_file")

( watch_status "$$" "$log_file" "$running" ) &
[ -n "$watch" ] || exit

until check_lock "$dom"; do
    sleep 0.5
done
