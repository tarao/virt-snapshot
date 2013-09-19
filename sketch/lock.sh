#!/bin/sh

base=$(basename "$0")
lib=$(cd $(dirname "$0"); pwd)
. "$lib/common.sh"

dom="$1"
info start "$dom"
lock "$dom"

sleep 5
info foo "do foo"
sleep 1
info bar "do bar"
sleep 1
warn "something wrong"
sleep 1
info baz "do bar"

unlock "$dom"
info end "$dom"
