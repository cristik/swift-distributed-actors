#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -e
#set -x # verbose

declare -r my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r root_path="$my_path/.."

declare -r app_name='it_ProcessIsolated_escalatingWorkers'

cd ${root_path}

source ${my_path}/shared.sh

_killall ${app_name}

# ====------------------------------------------------------------------------------------------------------------------
# MARK: the app has workers which fail so hard that the failures reach the top level actors which then terminate the system
#       when the system terminates we kill the process; once the process terminates, the servant supervision kicks in and
#       restarts the entire process; layered supervision for they win!

swift build # synchronously ensure built

declare -r log_file="/tmp/${app_name}.log"
rm -f ${log_file}
swift run ${app_name} > ${log_file} &

declare -r supervision_respawn_grep_txt='supervision: RESPAWN'
declare -r supervision_stop_grep_txt='supervision: STOP'

# we want to wait until 2 RESPAWNs are found in the logs; then we can check if the other conditions are as we expect
echo "Waiting for servant to RESPAWN a few times..."
spin=1 # spin counter
max_spins=20
while [[ $(cat ${log_file} | grep "${supervision_stop_grep_txt}" | wc -l) -ne 2 ]]; do
    sleep 1
    spin=$((spin+1))
    if [[ ${spin} -eq ${max_spins} ]]; then
        echoerr "Never saw enough '${supervision_stop_grep_txt}' in logs."
        cat ${log_file}
        exit -1
    fi
done

echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
cat ${log_file} | grep "${supervision_respawn_grep_txt}"
echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'

echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
cat ${log_file} | grep "${supervision_stop_grep_txt}"
echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'

if [[ $(cat ${log_file} | grep "${supervision_respawn_grep_txt}" | wc -l) -ne 2 ]]; then
    echoerr "ERROR: We expected 2 servants to only respawn once, yet other number of respawns was detected!"
    cat ${log_file}

    _killall ${app_name}
    exit -1
fi

if [[ $(cat ${log_file} | grep "${supervision_stop_grep_txt}" | wc -l) -ne 2 ]]; then
    echoerr "ERROR: Expected the servants to STOP after they are replaced once!"
    cat ${log_file}

    _killall ${app_name}
    exit -2
fi

# === cleanup ----------------------------------------------------------------------------------------------------------

_killall ${app_name}
