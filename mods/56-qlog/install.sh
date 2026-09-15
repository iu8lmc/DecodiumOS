#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# QLog
#==========================
# QLog, the amateur radio logbook (LoTW, eQSL, Club Log, QRZ, rig control via
# Hamlib), comes from its author's PPA, which decodiumos-base (mod 50) adds
# and pins to the qlog package. A copy of the .deb also goes to the
# DecodiumOS update repository, so systems installed before the PPA was added
# get QLog with the same upgrade that adds the PPA.

if [ "${QLOG_INSTALL:-no}" != "yes" ]; then
    print_warn "QLOG_INSTALL is not \"yes\" — QLog will not be shipped."
    exit 0
fi

wait_network

print_ok "Refreshing package lists (QLog PPA)..."
apt-get update
judge "Refresh package lists"

print_ok "Checking where qlog comes from..."
apt-cache policy qlog
candidate=$(apt-cache policy qlog | awk '/Candidate:/ {print $2}')
[ -n "$candidate" ] && [ "$candidate" != "(none)" ]
apt-cache policy qlog | grep -q 'ppa.launchpadcontent.net/foldyna/qlog'
judge "qlog $candidate available from the QLog PPA"

print_ok "Installing QLog $candidate..."
apt-get install -y qlog
judge "Install QLog"

print_ok "Keeping a copy of qlog for the update repository..."
install -d -m 0755 /var/cache/decodiumos-debs
( cd /var/cache/decodiumos-debs && apt-get download "qlog=$candidate" )
ls /var/cache/decodiumos-debs/qlog_*.deb
judge "Keep a copy of qlog"

print_ok "Verifying the QLog installation..."
test -x /usr/bin/qlog
missing=$(ldd /usr/bin/qlog | grep 'not found' || true)
if [ -n "$missing" ]; then
    echo "$missing"
    false
fi
ls /usr/share/applications/ | grep -i qlog
judge "Verify the QLog installation"
