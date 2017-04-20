#!/usr/bin/env bash

set -e
set -o pipefail

function usage()
{
    echo "$0 Usage: "
    echo "This script runs a postgresql backup" 
    echo "OPTIONS: "
    echo "-h Help (prints usage)"
    echo "-c configuration file location. Defaults to the cwd of pgbackup.sh with a file of pgbackup.config"
    echo "-d Take a backup with a datestamp of %Y-%m-%d_%H:%M:%S_%Z, or your own date(1) compatible format string"
}

DATESTAMP="$(date +%a)"
CONFIG="$(pwd)/pgbackup.config"

while getopts ":hd::c:" OPTIONS; do
	case ${OPTIONS} in
	h)
		usage
		exit 1
		;;
	d)
		# shellcheck disable=SC2086
		# If this is invalid, date fails and exits
		DATESTAMP="$(date $OPTARG)"
		;;
	:)
		DATESTAMP="$(date +%a_%F_%T_%Z)"
	    ;;
	c)
		CONFIG="$OPTARG"
		;;
	?)
		echo "Invalid option: ${OPTIONS}"
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
	MD5=$("$WHICH" md5sum)
	MD5FLAGS="--tag"
elif [[ $(uname -s) == "FreeBSD" ]]; then
	# BSD Date
	YESTERDAY=$(date -v "-1d" "+%a")
	LASTWEEK=$(date -v "-1w" "+week_%W_of_%Y")
	MD5=$("$WHICH" md5)
	MD5FLAGS=""
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

# Past this point, we don't want to stop on failed commands,
# because having backups of some databases is better than 
# having backups of no databases.
set +e

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
if [[ $WEEKLYONLY == false ]]; then 
	# shellcheck disable=SC2086
	for DATNAME in $($PSQL -U $PGUSER template1 $PGHOST -p $PGPORT ${PSQL_FLAGS} -c "SELECT datname FROM pg_database WHERE datistemplate IS FALSE;"); do
		PGFILE="${BACKUPDIR}/${SERVERNAME}_${DATNAME}_${PGPORT}_${DATESTAMP}.sqlc"
		# Clean up the previous checksum file
		rm -vf "${PGFILE}.checksum"
		# shellcheck disable=SC2086
		$PGDUMP -U $PGUSER $PGHOST -p $PGPORT "$DATNAME" "$PGDUMP_FLAGS" -f "$PGFILE"
		RETVAL=$?
		STATUS=("${STATUS[@]}" "$RETVAL")
		"$MD5" $MD5FLAGS "$PGFILE" >| "${PGFILE}.checksum"
	done
	# Back Up The Globals.
	PGGLOBALS="${BACKUPDIR}/${SERVERNAME}_globals_${PGPORT}_${DATESTAMP}.sql"
	# Clean up the previous checksum file
	rm -vf "${PGGLOBALS}.checksum"
	# shellcheck disable=SC2086
	$PGDUMPALL -U $PGUSER $PGHOST -p $PGPORT "$PGDUMPALL_FLAGS" > "$PGGLOBALS"
	RETVAL=$?
	STATUS=("${STATUS[@]}" "$RETVAL")
	"$MD5" $MD5FLAGS "$PGGLOBALS" >| "${PGGLOBALS}.checksum"
fi

# Take a weekly backup of each DB if needed.
if [[ $WEEKLY == true ]] && [[ $DATESTAMP == "$WEEKLYDAY" ]]; then
	# shellcheck disable=SC2086 
	for DATNAME in $($PSQL -U $PGUSER template1 $PGHOST -p $PGPORT ${PSQL_FLAGS} -c "SELECT datname FROM pg_database WHERE datistemplate IS FALSE;"); do
		PGFILE="${BACKUPDIR}/${SERVERNAME}_${DATNAME}_${PGPORT}_${WEEKSTAMP}.sqlc"
		# Clean up the previous checksum file
		rm -vf "${PGFILE}.checksum"
		# shellcheck disable=SC2086 
		$PGDUMP -U $PGUSER $PGHOST -p $PGPORT "$DATNAME" "$PGDUMP_FLAGS" -f "$PGFILE"
		RETVAL=$?
		STATUS=("${STATUS[@]}" "$RETVAL")
		"$MD5" $MD5FLAGS "$PGFILE" >| "${PGFILE}.checksum"
	done
	# Back Up The Globals.
	PGGLOBALS="${BACKUPDIR}/${SERVERNAME}_globals_${PGPORT}_${WEEKSTAMP}.sql"
	# shellcheck disable=SC2086
	$PGDUMPALL -U $PGUSER $PGHOST -p $PGPORT "$PGDUMPALL_FLAGS" > "$PGGLOBALS"
	RETVAL=$?
	STATUS=("${STATUS[@]}" "$RETVAL")
	"$MD5" $MD5FLAGS "$PGGLOBALS" >| "${PGGLOBALS}.checksum"
fi

# We only delete if everything returned successfully.
check_all_success "${STATUS[@]}"
ALLOK=$?

# For deletion, we actually want shell expansion, so we don't double-quote the full rm command

# Delete yesterday's backups.
if [[ $ALLOK -eq 0 ]] && [[ $ONEDAY == true ]]; then
	# shellcheck disable=SC2086
	rm -vf ${BACKUPDIR}/*${YESTERDAY}*
fi

# Delete weekly backups on the one-week day.
# On the weekly backup day, we double-check that it finished before deleting it.
# If it isn't the weekly backup day, we delete because the backup, by default,
# should have been picked up in the last six days and moved off the server.
if ( [[ $ALLOK -eq 0 ]] && [[ $WEEKLYDAY == "$TODAY" ]] && [[ $ONEWEEK == true ]] && [[ $WEEKLYDELETEDAY == "$TODAY" ]] ) || \
	( [[ $ONEWEEK == true ]] && [[ $WEEKLYDAY != "$TODAY" ]] && [[ $WEEKLYDELETEDAY == "$TODAY" ]] ) ; then
	# shellcheck disable=SC2086
	rm -vf ${BACKUPDIR}/*${LASTWEEK}*
fi
