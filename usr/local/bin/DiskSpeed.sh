#!/bin/bash

DSDIR=${1-/opt/zimbra}
trap "rm -f $DSDIR/1024m" EXIT

sync;dd if=/dev/zero of=$DSDIR/1024m bs=1024k count=1024
sync;dd if=$DSDIR/1024m of=/dev/null bs=1024k;sync

exit 0
