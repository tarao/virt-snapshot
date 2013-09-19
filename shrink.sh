#!/bin/sh

base=$(basename "$0")
lib=$(cd $(dirname "$0"); pwd)
. "$lib/common.sh"

help() {
    cat <<EOF
Usage: $base <domain>
Options:
  -v           Verbose messages.
  -t           Test mode; print what will happen instead of actually doing it.
  -c <config>  Load named configuration.
  -f <file>    Load configuration from file.
  -w           Wait any earlier domain snapshotting in progress.
  -a           Ensure that the domain is activated.
  -b           Backup path.
  -d           Working directory.
Arguments:
  <domain>     The domain name.
Configuration:
  backup_path='$backup_path'
  working_dir="$working_dir"
  shrink_domain='$shrink_domain'
  shrink_prepare_prefix='$shrink_prepare_prefix'
  shrink_base_prefix='$shrink_base_prefix'
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
    -b|--backup)
        shift; backup="$1"; shift
        ;;
    -d|--working-directory)
        shift; wd="$1"; shift
        ;;
    *)
        dom="$1"; shift
        ;;
    esac
done

dom="${dom:-$shrink_domain}"
[ -n "$dom" ] || help 1

[ -n "$conf" ]          && load_config "$dom" "$conf"
[ -n "$conf_file" ]     && load_config_file "$conf_file"
[ -n "$config_loaded" ] || load_config "$dom" shrink

prepare_prefix="$shrink_prepare_prefix"
base_prefix="$shrink_base_prefix"
args="$snapshot_args"
backup="${backup:-$backup_path}"
wd="${wd:-$working_dir}"

info start "$dom"

[ -n "$activate" ] && {
    dom_activate "$dom"
    ip=$(dom_ip "$dom")
    [ -n "$ip" ] || die "Cannot get IP of domain '$dom'"
    run wait_for_up "$ip"
}

[ -n "$wait" ] && lock "$dom" || try_lock "$dom" || die "Domain '$dom' is busy"

old_images=$(mktemp)
dom_images "$dom" > "$old_images"

# working image
dom_snapshot "$dom" "$prepare_prefix" $args

working_images=$(mktemp)
dom_images "$dom" > "$working_images"

# before hook
run_hooks shrink/before "$dom"

old_snapshot_list=$(mktemp)
[ -r "$var/$dom/snapshot.list" ] && {
    run mv "$var/$dom/snapshot.list" "$old_snapshot_list"
}

# base file for shrink
dom_snapshot "$dom" "$base_prefix" $args

base_images=$(mktemp)
dom_images "$dom" > "$base_images"

# new head
dom_snapshot "$dom" "$snapshot_prefix" $args

# convert
cat "$base_images" | while read file; do
    [ -r "$file" ] && {
        base_name=$(basename "$file")
        target=$(target_path "$file" "$wd/$base_name")
        info convert "$file -> $target"
        run mkdir -p $(dirname "$target")
        run qemu-img convert -c -O qcow2 "$file" "$target" || {
            die "Cannot convert '$file' to '$target'"
        }
        run mv "$target" "$file"
    }
done

cat "$old_snapshot_list" | while read name; do
    dom_delete_metadata "$dom" "$name"
done

# leave backup
cat "$old_images" | backing_files | while read file; do
    [ -r "$file" ] && {
        base_name=$(basename "$file")
        target=$(target_path "$file" "$backup/$base_name")
        info backup "$file -> $target"
        run mkdir -p $(dirname "$target")
        run mv "$file" "$target"
    }
done

# clean
cat "$working_images" | while read file; do
    [ -r "$file" ] && {
        info clean "$file"
        run rm "$file"
    }
done

# after hook
run_hooks shrink/after "$dom"

rm "$base_images"
rm "$old_snapshot_list"
rm "$working_images"
rm "$old_images"
unlock "$dom"

info end "$dom"
