msg() {
    _msg_command=$(basename $0 .sh)
    _msg_level=$(echo "$1" | tr '[a-z]' '[A-Z]'); shift
    _msg_action="$1"; shift;
    [ -n "$_msg_action" ] && _msg_action=".$_msg_action"
    _msg_time=$(date --iso=ns)
    _msg_tag=$(echo "$_msg_level" | cut -c 1-1)
    echo "$_msg_tag [$_msg_time #$$] $_msg_command$_msg_action : $@" >&2
}

log() {
    _log_dir="$var_prefix/log"
    mkdir -p "$_log_dir"
    _log_file="$_log_dir/virt-snapshot.log"
    echo $(msg "$@" 2>&1) >> "$_log_file"
}

fatal() {
    [ 0 -lt "$verbose_level" ] && msg fatal '' "$@"
    [ 0 -lt "$log_level" ]     && log fatal '' "$@"
}

error() {
    [ 1 -lt "$verbose_level" ] && msg error '' "$@"
    [ 1 -lt "$log_level" ]     && log error '' "$@"
}

warn() {
    [ 2 -lt "$verbose_level" ] && msg warn '' "$@"
    [ 2 -lt "$log_level" ]     && log warn '' "$@"
}

log_test() {
    [ 2 -lt "$verbose_level" ] && msg test "$@"
    [ 2 -lt "$log_level" ]     && log test "$@"
}

info() {
    [ 3 -lt "$verbose_level" ] && msg info "$@"
    [ 3 -lt "$log_level" ]     && log info "$@"
}

debug() {
    [ 4 -lt "$verbose_level" ] && msg debug "$@"
    [ 4 -lt "$log_level" ]     && log debug "$@"
}

die() {
    fatal "$@"
    exit 1
}

testing() {
    [ -n "$test" ] && return 0
    return 1
}

shell_escape1() {
    printf %s\\n "$1" | sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/'/"
}

shell_escape() {
    _args=$(shell_escape1 "$1"); shift
    for a in "$@"; do
        _args="$_args $(shell_escape1 "$a")"
    done
    echo "$_args"
}

run() {
    _cmd=$(shell_escape "$1"); shift
    for x in "$@"; do
        [ "x$x" = 'x|' -o "x$x" = 'x>' -o "x$x" = 'x>>' -o "x$x" = 'x<' ] && {
            _cmd="$_cmd $x"
        } || {
            _cmd="$_cmd $(shell_escape "$x")"
        }
    done
    testing && log_test run "$_cmd" || {
        debug run "$_cmd"
        eval "$_cmd"
    }
}

set_prefix() {
    _dir="$1"; set -- /usr/local/ /usr/ /

    for i in $(seq $#); do
        d=$(eval "echo \$$i")
        [ x$(echo $_dir | cut -c 1-${#d}) = x$d ] && {
            case "$d" in
            "$1")
                etc_prefix=/usr/local/etc
                var_prefix=/var/local
                return
                ;;
            "$2")
                etc_prefix=/etc
                var_prefix=/var
                return
                ;;
            *)
                etc_prefix=$_dir/local/etc
                var_prefix=$_dir/local/var
                return
                ;;
            esac
        }
    done
}

lock() {
    info lock "$1"
    mkdir -p "$var"
    exec 9>>"$var/$1.lock"
    shift
    flock "$@" 9
}

try_lock() {
    lock "$@" -n && return
    return 1
}

unlock() {
    info unlock "$1"
    flock -u 9
}

load_config_file() {
    [ -r "$1" ] && {
        config_loaded=1
        . "$1"
        info load "$1"
    }
}

load_config() {
    d=''
    [ $# -ge 2 ] && {
        d="$1"
        shift
    }
    load_config_file "$etc/$1.conf"
    [ -n "$d" ] && load_config_file "$etc/conf.d/$d/$1.conf"
}

run_hooks() {
    _name="$1"; shift
    _dir="$etc/hooks/$1"
    [ -d "$_dir" ] || return

    for h in $(ls "$_dir"/*); do
        [ -x "$h" ] && {
            info hook "$_name" "$h" "$@"
            run "$h" "$@"
        }
    done
}

unique_id() {
    type uuid >/dev/null && uuid && return
    type uuidgen >/dev/null && uuidgen -t && return
}

dom_activate() {
    info activate "$1"
    _state=$(virsh domstate "$1")
    [ "x$_state" != 'xrunning' ] && run virsh start "$1"
}

dom_xml() {
    d="$1"; shift
    virsh dumpxml "$d" | xmlstarlet sel -t -c "$@"
}

dom_ip() {
    _elem_mac=$(dom_xml "$1" '//interface[@type="network"][1]/mac')
    _mac=$(echo "$_elem_mac" | sed 's/^.*address="\(.*\)".*$/\1/')
    [ -n "$_mac" ] || return

    _leases="$libvirt_leases"
    [ -r "$misc_leases" ] && _leases="$misc_leases"
    grep "$_mac" $_leases | cut -d ' ' -f 3
}

dom_images() {
    dom_xml "$1" '//disk[not(@snapshot="no")]/source' | \
        sed 's/<[^<]*file="\([^"]\+\)"[^<]*\/>/\1\n/g'
}

dom_snapshot() {
    _dom="$1"; shift
    _name="$1_$(unique_id)"; shift
    _list="$var/$_dom/snapshot.list"
    info snapshot "$_dom" "$_name"
    run mkdir -p $(dirname "$_dom")
    run echo "$_name" '>>' "$_list"
    run virsh snapshot-create-as "$_dom" "$_name" "$@"
}

dom_delete_metadata() {
    [ -n "$2" ] && virsh snapshot-info "$1"  "$2" >/dev/null 2>&1 && {
        info delete metadata "$1" "$2"
        run virsh snapshot-delete "$1" "$2" --metadata
    }
}

backing_info() {
    while read i; do
        [ -n "$i" ] && qemu-img info --backing-chain "$i"
    done
}

backing_files() {
    backing_info | grep '^image:' | sed 's/^image:[ \t]*//'
}

target_path() {
    _src=$(dirname "$1")
    _p="$2"
    [ "x$(echo "$_p" | cut -c 1-1)" = 'x/' ] && echo "$_p" || echo "$_src/$_p"
}

reachable() {
    ping -c 1 -W 1 "$1" >/dev/null && return 0
    return 1
}

wait_for_up() {
    _host="$1"
    _try="${2:-$max_try_reachable}"
    for t in $(seq $_try); do
        reachable "$_host" && return 0
    done
    return 1
}

set_prefix $(cd $(dirname $0); pwd)
var=${var_prefix}/lib/virt-snapshot
etc=${etc_prefix}/virt-snapshot

backup_path='backup'
working_dir='new'

shrink_prepare_prefix='prepare'
shrink_base_prefix='base'

snapshot_prefix='snapshot'
snapshot_args='--disk-only'

xml_command='xmlstarlet'
libvirt_leases='/var/lib/libvirt/dnsmasq/*.leases'
misc_leases='/var/lib/misc/dnsmasq.leases'

max_try_reachable=300

verbose_level=3
log_level=4
