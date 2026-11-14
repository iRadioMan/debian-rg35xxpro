#!/bin/sh
# ES-DE quit menu -> whatever session ES-DE was started from: the desktop if it was entered from
# there, the console when ES-DE is the boot session. The switch stops this session, so
# rg35xx-session only queues the start job (--no-block).
#
# This hook also runs when ES-DE is stopped *by a switch* (a game launch, the desktop menu,
# poweroff): rg35xx-session records the requested mode in /run/rg35xx/target before the stop. Only
# a user-requested quit leaves the plain "es" there, so every other value must stay silent --
# otherwise "back" overwrites the target and cancels the switch that is already under way.
target=$(cat /run/rg35xx/target 2>/dev/null || true)
[ "$target" = es ] || exit 0
exec sudo -n /usr/local/bin/rg35xx-session back
