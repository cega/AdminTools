#!/bin/bash
#####################################################################
## (c) CopyRight 2014 B-LUC Consulting and Thomas Bullinger
#
# Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#####################################################################

DSDIR=${1-/opt/zimbra}
trap "rm -f $DSDIR/1024m" EXIT

sync;dd if=/dev/zero of=$DSDIR/1024m bs=1024k count=1024
sync;dd if=$DSDIR/1024m of=/dev/null bs=1024k;sync

exit 0
