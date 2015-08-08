#!/usr/bin/env bash

set -e
set -o pipefail

#######################################################################################################################################################################
# Copyright (c) 2008-2015, Lacey Powers
#
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer 
# in the documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, 
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS 
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE 
# GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, 
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
######################################################################################################################################################################

function usage()
{
   echo "$0 Usage: "
   echo "This script runs a postgresql backup" 
   echo "OPTIONS: "
   echo "-h Help (prints usage)"
   echo "-c configuration file location. Defaults to the cwd of pgbackup.sh with a file of pgbackup.config"
   echo "-d Take a backup with a datestamp of NOW"
}

DATESTAMP="$(date +%a)"
CONFIG="$(pwd)/pgbackup.config"

while getopts ":hdc:" OPTIONS; do
   case ${OPTIONS} in
      h)  
        usage
        exit 1
        ;;
      d)  
		DATESTAMP="$(date +%a_%F_%T_%Z)"
        ;;
      c)

        CONFIG="$OPTARG"
        ;;
      ?)  
        echo "Invalid option: ${OPTARG}"
        usage
        exit 1
        ;;
   esac
done
shift $((OPTIND-1))

. "$CONFIG"

# Find Utilities.
PSQL=$("$WHICH" psql)
PGDUMP=$("$WHICH" pg_dump)
PGDUMPALL=$("$WHICH" pg_dumpall)

# Niceties.
if [[ $PGHOST == "localhost" ]]; then
	SERVERNAME=$(uname -n)
else 
	SERVERNAME="$PGHOST"
fi

TODAY=$(date +%a)
WEEKSTAMP=$(date +week_%W_of_%Y)

if [[ $(uname -s ) == "Linux" ]]; then
	# GNU Date
	YESTERDAY=$(date --date="yesterday" "+%a")
	LASTWEEK=$(date --date="last-week" "+week_%W_of_%Y")
elif [[ $(uname -s) == "FreeBSD" ]]; then
	# BSD Date
	YESTERDAY=$(date -v "-1d" "+%a")
	LASTWEEK=$(date -v "-1w" "+week_%W_of_%Y")
else 
	echo "Unsupported OS Type"
	exit 1
fi

if [[ $PGHOST == "localhost" ]]; then
	PGHOST=""
else 
	PGHOST="-h $PGHOST"
fi

declare -a STATUS

function check_all_success()
{
	ARRAY=("${@}")

	# If there is nothing in this array, that's wrong.
	if [[ ${#ARRAY[@]} -eq 0 ]]; then
		return 1
	fi

	for val in "${ARRAY[@]}"; do 
		# Nonzero return code is an error.
		if [[ $val -gt 0 ]]; then
			return 1
		fi
	done
	# If we get here, all should be well.
	return 0
}


# $PGHOST is already double-quoted above. Additional double quoting changes the behavior
# Suppressions for shellcheck added accordingly.

# Back Up Each Database in compressed format.
# shellcheck disable=SC2086
for DATNAME in $($PSQL -U $PGUSER template1 $PGHOST -p $PGPORT --tuples-only -c "SELECT datname FROM pg_database WHERE datistemplate IS FALSE;"); do
	# shellcheck disable=SC2086
	 $PGDUMP -U $PGUSER $PGHOST -p $PGPORT "$DATNAME" "$PGDUMP_FLAGS" -f "${BACKUPDIR}/${SERVERNAME}_${DATNAME}_${PGPORT}_${DATESTAMP}.sqlc"
	 RETVAL=$?
	 STATUS=("${STATUS[@]}" "$RETVAL")
done

# Back Up The Globals.
# shellcheck disable=SC2086 
$PGDUMPALL -U $PGUSER $PGHOST -p $PGPORT "$PGDUMPALL_FLAGS" > "${BACKUPDIR}/${SERVERNAME}_globals_${PGPORT}_${DATESTAMP}.sql"
RETVAL=$?
STATUS=("${STATUS[@]}" "$RETVAL")

# Take a weekly backup of each DB if needed.
if [[ $WEEKLY == true ]] && [[ $DATESTAMP == "$WEEKLYDAY" ]]; then
	# shellcheck disable=SC2086 
	for DATNAME in $($PSQL -U $PGUSER template1 $PGHOST -p $PGPORT --tuples-only -c "SELECT datname FROM pg_database WHERE datistemplate IS FALSE;"); do
		# shellcheck disable=SC2086 
		 $PGDUMP -U $PGUSER $PGHOST -p $PGPORT "$DATNAME" "$PGDUMP_FLAGS" -f "${BACKUPDIR}/${SERVERNAME}_${DATNAME}_${PGPORT}_${WEEKSTAMP}.sqlc"
		 RETVAL=$?
		 STATUS=("${STATUS[@]}" "$RETVAL")
	done
fi

# We only delete if everything returned successfully.
check_all_success "${STATUS[@]}"
ALLOK=$?

# Delete yesterday's backups.
if [[ $ALLOK -eq 0 ]] && [[ $ONEDAY == true ]]; then
	rm -vf "${BACKUPDIR}/*${YESTERDAY}*"
fi

# Delete weekly backups on the one-week day.
if [[ $ALLOK -eq 0 ]] && [[ $ONEWEEK == true ]] && [[ $WEEKLYDAY == "$TODAY" ]]; then
	rm -vf "${BACKUPDIR}/*${LASTWEEK}*"
fi
