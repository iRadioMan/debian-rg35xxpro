#!/bin/sh
# PortMaster launcher for ES-DE's Ports list.
#
# ES-DE runs this through /usr/local/bin/rg35xx-run-sh, which stops the frontend and hands the
# script to rg35xx-game.service: PortMaster's GUI then owns the DRM device and the RAM.
exec /roms/ports/PortMaster/PortMaster.sh
