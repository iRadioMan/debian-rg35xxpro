#!/bin/sh
# ES-DE quit menu -> whatever session ES-DE was started from: the desktop if it was entered from
# there, the console when ES-DE is the boot session. The switch stops this session, so
# rg35xx-session only queues the start job (--no-block).
exec sudo -n /usr/local/bin/rg35xx-session back
