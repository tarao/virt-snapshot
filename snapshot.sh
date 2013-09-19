#!/bin/sh

base=$(basename "$0")
lib=$(cd $(dirname "$0"); pwd)
. "$lib/common.sh"

help() {
    cat <<EOF
Usage: $base OPTIONS <domain> [<args>]
Options:
  -v           Verbose messages.
  -t           Test mode; print what will happen instead of actually doing it.
  -s <prefix>  Snapshot prefix.
  -c <config>  Load named configuration.
  -f <file>    Load configuration from file.
  -w           Wait any earlier domain snapshotting in progress.
  -a           Ensure that the domain is activated.
Arguments:
  <domain>     The domain name.
  <args>       Arguments for 'virsh snapshot-create-as'.
Configuration:
  snapshot_domain='$snapshot_domain'
  snapshot_prefix='$snapshot_prefix'
  snapshot_args='$snapshot_args'
  libvirt_leases='$libvirt_leases'
  misc_leases='$misc_leases'
  xml_command='$xml_command'
  max_try_reachable='$max_try_reachable'
  var='$var'
  etc='$etc'
  lib='$lib'
EOF
    exit $1
}

parsing=1
while [ $parsing = 1 ] && [ -n "$1" ]; do
    case "$1" in
    -t|--test)
        test=1; shift
        ;;
    -v|--verbose)
        verbose_level=$(( $verbose_level + 1 )); shift
        ;;
    -s|--snapshot)
        shift; prefix="$1"; shift
        ;;
    -c|--config)
        shift; conf="$1"; shift
        ;;
    -f|--config-file)
        shift; conf_file="$1"; shift
        ;;
    -w|--wait)
        wait=1; shift
        ;;
    -a|--activate)
        activate=1; shift
        ;;
    --)
        args=' '; shift
        ;;
    -*)
        args="$args $1"; shift
        ;;
    *)
        dom="$1"; shift
        ;;
    esac
done

dom="${dom:-$snapshot_domain}"
[ -n "$dom" ] || help 1

[ -n "$conf" ]          && load_config "$dom" "$conf"
[ -n "$conf_file" ]     && load_config_file "$conf_file"
[ -n "$config_loaded" ] || load_config "$dom" snapshot

prefix="${prefix:-$snapshot_prefix}"
args="${args:-$snapshot_args}"

info start "$dom"

[ -n "$activate" ] && {
    dom_activate "$dom"
    ip=$(dom_ip "$dom")
    [ -n "$ip" ] || die "Cannot get IP of domain '$dom'"
    run wait_for_up "$ip"
}

[ -n "$wait" ] && lock "$dom" || try_lock "$dom" || die "Domain '$dom' is busy"
run_hooks snapshot/before "$dom"
dom_snapshot "$dom" "$prefix" $args
run_hooks snapshot/after "$dom"
unlock "$dom"

info end "$dom"
