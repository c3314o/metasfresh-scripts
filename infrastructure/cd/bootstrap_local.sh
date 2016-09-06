#!/bin/bash

#
# NOTE: this script does not to any parameter parsing anymore. It is driven by environment variables.
# Those environment variables are:
#
# 	DATABASE			if "true", then execute the migration scripts against the database specified in the local.properties
#						optional; if not set, then "false" is assumed
#
#	MINOR				if "true", then rollout the code and jasper report files
#						optional; if not set, then "false" is assumed
#
#	VALIDATE_MIGRATION	if "true", then create a copy of a reference DB and execute the migration scripts against that DB
#						optional; if not set, then "false" is assumed
#
#	LOCAL_ROLLOUT_FILE	if set, then the script will not attempt to download the distributable tar.gz, but assume that it's already lying in the workspace
#						needs to be a "local" filename, without path
#
#	ROLLOUT_FILE_URL	if set and LOCAL_ROLLOUT_FILE is not set, then the script will attempt to wget the distributable tar.gz from this URL
#
#	ROLLOUT_BUILD_URL	if neither LOCAL_ROLLOUT_FILE nor ROLLOUT_FILE_URL are set, then the script will construct an URL 
#						by combining this variable with DIST_ARCHIVE and then attempt to wget the distributable tar.gz from there
#
#	DIST_ARCHIVE		see ROLLOUT_BUILD_URL
#
#	TARGET_HOST			the hostname of the rollout target server
#
#   SSH_PORT            the ssh port to be used. If not set, then the script will go with port 22
#
#	TARGET_USER			the user this script will attempt to login with when ssh'ing to the rollout server
#

#Don't do anything by default
if [ "$DATABASE" == "" ]; then
	DATABASE="false"
fi
if [ "$MINOR" == "" ]; then
	MINOR="false"
fi
if [ "$VALIDATE_MIGRATION" == "" ]; then
	# FRESH-336
	VALIDATE_MIGRATION="false"
fi

# note that ROLLOUT_BUILD_URL and DIST_ARCHIVE are mandatory, *unless* either ROLLOUT_FILE_URL or LOCAL_ROLLOUT_FILE are set 
if [ "$LOCAL_ROLLOUT_FILE" == "" ]; then
	LOCAL_ROLLOUT_FILE="NOT_SPECIFIED"
fi
if [ "$ROLLOUT_FILE_URL" == "" ]; then
	ROLLOUT_FILE_URL="NOT_SPECIFIED"
fi

# Note that in recent rollout jobs, 
# BUILD_URL is not the URL of the build that contains the rollout artifact, but instead the URL of the job that is actually performing the rollout.
if [ "$BUILD_URL" == "" ]; then
	BUILD_URL="NOT_SPECIFIED"
fi

if [ "$TARGET_USER" == "" ]; then
	TARGET_USER="metas"
fi

if [ "$TARGET_HOST" == "" ]; then
	TARGET_HOST="NOT_YET_SPECIFIED"
fi

## Port used for ssh and scp. 
if [ "$SSH_PORT" == "" ]; then
	SSH_PORT=22
fi

if [ "$ROLLOUT_DIR" == "" ]; then
	ROLLOUT_DIR="NOT_YET_SPECIFIED"
fi

if [ "$CLEAN_ROLLOUT_APPSERVER" == "" ]; then
	CLEAN_ROLLOUT_APPSERVER="true"
fi

if [ "$WORKSPACE" == "" ]; then
	#fallback
	WORKSPACE=$(pwd) 
fi

set -o nounset  #don't allow access to unset variables
set -o errexit  #don't allow any command to exit with an error code !=0

RELEASE_TIME=$(date "+%Y%m%d_%H%M%S")
REMOTE_DIR="/home/${TARGET_USER}/${RELEASE_TIME}"
REMOTE_EXEC_DIR="${REMOTE_DIR}/dist/install"
WRAPPER_APP="metasfresh_server"	
####
# Seting local and rollout dir
####
LOCAL_DIR=$(dirname $0)
if [ "$LOCAL_DIR" == "." ]; then
	LOCAL_DIR=$(pwd)
fi

TOOLS=${LOCAL_DIR}/tools.sh
if [ -f $TOOLS ] && [ -r $TOOLS ]; then
	source $TOOLS
else
	echo "Missing file ${TOOLS}"
	exit 1
fi

prepare()
{
	trace prepare BEGIN
	
	check_std_tool ssh
	check_std_tool scp
	check_std_tool wget
	
	check_var BUILD_URL ${BUILD_URL:-NOT_SET}
	
	check_var DATABASE ${DATABASE:-NOT_SET}
	check_var MINOR ${MINOR:-NOT_SET}
	
	if [ "$LOCAL_ROLLOUT_FILE" != "NOT_SPECIFIED" ]; then
	
		trace prepare "LOCAL_ROLLOUT_FILE was already set. Ignoring ROLLOUT_FILE_URL, ROLLOUT_BUILD_URL and DIST_ARCHIVE"
		check_var LOCAL_ROLLOUT_FILE "${LOCAL_ROLLOUT_FILE}"
	
		DIST_FILE=$LOCAL_ROLLOUT_FILE
		check_var DIST_FILE $DIST_FILE

	else 
		if [ "$ROLLOUT_FILE_URL" != "NOT_SPECIFIED" ]; then
		
			trace prepare "ROLLOUT_FILE_URL was already set. Ignoring ROLLOUT_BUILD_URL and DIST_ARCHIVE"
			check_var ROLLOUT_FILE_URL "${ROLLOUT_FILE_URL}"

		else
			trace prepare "Setting ROLLOUT_FILE_URL from ROLLOUT_BUILD_URL and DIST_ARCHIVE"

			# FRESH-286:
			# In jenkins, the envInject plugin aparently overwrites our BUILD_URL build parameter with the URL of the currently running job.
			# We therefore introduce the ROLLOUT_BUILD_URL, but provide a fallback for those cases where the ROLLOUT_BUILD_URL is not specified, 
			# but the BUILD_URL is actually the desired one
			check_var_fallback ROLLOUT_BUILD_URL ${ROLLOUT_BUILD_URL:-NOT_SET} BUILD_URL ${BUILD_URL:-NOT_SET}
			check_var DIST_ARCHIVE ${DIST_ARCHIVE:-NOT_SET}
						
			ROLLOUT_FILE_URL=${ROLLOUT_BUILD_URL}/${DIST_ARCHIVE}
			check_var ROLLOUT_FILE_URL "${ROLLOUT_FILE_URL}"	fi
		
			check_var ROLLOUT_DIR ${ROLLOUT_DIR:-NOT_SET}
			check_var TARGET_HOST ${TARGET_HOST:-NOT_SET}
			check_var SSH_PORT ${SSH_PORT:-NOT_SET}
		fi
		
		# basename should also work with an URL, and note that DIST_ARCHIVE might not actually be set after all
		DIST_FILE=$(basename ${ROLLOUT_FILE_URL})
		check_var DIST_FILE $DIST_FILE

		trace prepare "Downloading rollout file from URL ${ROLLOUT_FILE_URL}"
		wget --no-verbose ${ROLLOUT_FILE_URL}

	fi
	
	if [ "$DATABASE" = "false" ] && [ "$MINOR" = "false" ]; 
	then
		trace prepare "============================================================================================"
		trace prepare "= IMPORTANT: we will only copy the data, but do not actual rollout!                        ="
		trace prepare "= Set at least one of DATABASE or MINOR environment variables to do more than just copying ="
		trace prepare "============================================================================================"
		START_STOP="false"
	else
		START_STOP="true"
	fi
		
		
	ROLLOUT_DIR=${WORKSPACE}
	
	check_var ROLLOUT_DIR "${ROLLOUT_DIR}"

	check_var TARGET_HOST "${TARGET_HOST}"
	
	rollout_common $TARGET_HOST
	
	trace prepare END
}

rollout_common()
{
	trace rollout_common BEGIN

	local TARGET_HOST=$1
	check_var TARGET_HOST $TARGET_HOST
	check_ssh $TARGET_HOST $SSH_PORT $TARGET_USER
	
	trace rollout_common "Creating remote directory ${REMOTE_DIR}"
	ssh -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST} "mkdir -p ${REMOTE_DIR}"
		
	trace rollout_common "Copying file ${DIST_FILE} to remote directory ${TARGET_HOST}:${REMOTE_DIR}"
	scp -P ${SSH_PORT} ${ROLLOUT_DIR}/${DIST_FILE} ${TARGET_USER}@${TARGET_HOST}:${REMOTE_DIR}
	
	trace rollout_common "Extracting the file ${DIST_FILE} on ${TARGET_HOST}"
	ssh -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST} "cd ${REMOTE_DIR} && tar -xf ${REMOTE_DIR}/${DIST_FILE}"
	
	trace rollout_common END
}

rollout_minor()
{
	trace rollout_minor BEGIN

	local MINOR_SH=${LOCAL_DIR}/minor_remote.sh
	check_file_exists $MINOR_SH

	#invoking script
	trace rollout_minor "Invoking remote script minor_remote.sh"
	trace rollout_minor "=========================================================="
	# Note: 
	#   the -tt is necessary because we might call sudo on the remote site and sudo requries a tty 
	#   Multiple -t options force tty allocation, even if ssh has no local tty.
	ssh -tt -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST} "${REMOTE_EXEC_DIR}/minor_remote.sh -n" 
	trace rollout_minor "=========================================================="
	trace rollout_minor "Done with remote script minor_remote.sh"
	
	trace rollout_minor END
}

#
# FRESH-336
# Similar to rollout_database() in that it invokes sql_remote.sh, 
# but it calls that script with "-n ${VALIDATE_MIGRATION_TEMPLATE_DB} ${VALIDATE_MIGRATION_TEST_DB}".
#
validate_migration()
{
	trace validate_migration BEGIN
	
	check_var VALIDATE_MIGRATION_TEMPLATE_DB ${VALIDATE_MIGRATION_TEMPLATE_DB:-NOT_SET}
	check_var VALIDATE_MIGRATION_TEST_DB ${VALIDATE_MIGRATION_TEST_DB:-NOT_SET}
	
	trace validate_migration "Invoking remote script sql_remote.sh to verify our migration scripts against a short-lived copy of ${VALIDATE_MIGRATION_TEMPLATE_DB}."
	trace validate_migration "=========================================================="

	ssh -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST} "${REMOTE_EXEC_DIR}/sql_remote.sh -d ${REMOTE_EXEC_DIR}/.. -n ${VALIDATE_MIGRATION_TEMPLATE_DB} ${VALIDATE_MIGRATION_TEST_DB}" 
	trace validate_migration "=========================================================="
	trace validate_migration "Done with remote script sql_remote.sh"

	check_var VALIDATE_MIGRATION_TEST_DB ${VALIDATE_MIGRATION_TEST_DB:-NOT_SET}
		
	trace validate_migration END
}

rollout_database()
{
	trace rollout_database BEGIN

	trace rollout_database "Invoking remote script sql_remote.sh"
	trace rollout_database "=========================================================="

	ssh -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST} "${REMOTE_EXEC_DIR}/sql_remote.sh -d ${REMOTE_EXEC_DIR}/.." 
	trace rollout_database "=========================================================="
	trace rollout_database "Done with remote script sql_remote.sh"

	trace rollout_database END
}

clean_rollout_appserver()
{
	trace clean_rollout_appserver BEGIN

	if [ "$CLEAN_ROLLOUT_APPSERVER" != "true" ]; then
		trace clean_rollout_appserver "SKIPPING deletion of dir ${REMOTE_DIR} on host ${TARGET_HOST} (CLEAN_ROLLOUT_APPSERVER=${CLEAN_ROLLOUT_APPSERVER})"
	else
		trace clean_rollout_appserver "Making remote script cleanrollout_remote.sh executable"
		ssh -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST} "chmod a+x ${REMOTE_EXEC_DIR}/cleanrollout_remote.sh"
	
		trace clean_rollout_appserver "Invoking remote script cleanrollout_remote.sh"
		trace clean_rollout_appserver "=========================================================="
		# Note: 
		#   the -tt is necessary because we might call sudo on the remote site and sudo requries a tty 
		#   Multiple -t options force tty allocation, even if ssh has no local tty.
		ssh -tt -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST} "${REMOTE_EXEC_DIR}/cleanrollout_remote.sh" 
		trace clean_rollout_appserver "=========================================================="
		trace clean_rollout_appserver "Done with remote script cleanrollout_remote.sh"
	fi
	
	trace clean_rollout_appserver END
}

check_ssh()
{
	trace check_ssh BEGIN

	local host=$1
	local port=$2
	local user=$3
	
	trace check_ssh "Trying to log into TARGET_HOST ${host} port ${port} as user ${user}"
	
	#check if we can connect to the remote host as user adempiere	
	ssh -p ${port} ${user}@${host} 'echo ssh connect to TARGET_HOST ${host} port ${port} successfull'
	if [ "$?" != "0" ]  ; then
		trace check_ssh "Can't log into TARGET_HOST ${host} port ${port} as user ${user}, trying metas"
		ssh -p ${port} metas@${host} 'echo ssh connect to TARGET_HOST ${host} port ${port} successfull'
		if [ "$?" != "0" ]  ; then
		  trace check_ssh "Can't log into TARGET_HOST ${host} port ${port} as user metas either"
		  exit 2
		fi
	fi
	
	trace check_ssh END
}

prepare

if [ "$VALIDATE_MIGRATION" == "true" ]; then
	# FRESH-336
	validate_migration
fi

if [ "$START_STOP" = "true" ]; 
then
	trace $(basename $0) "Stopping remote metasfresh or adempiere service"
	ssh -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST} "${REMOTE_EXEC_DIR}/stop_service.sh" 
fi

if [ "$DATABASE" == "true" ]; then
	rollout_database
fi
if [ "$MINOR" == "true" ]; then
	rollout_minor
fi

if [ "$START_STOP" = "true" ]; 
then
	trace $(basename $0) "Starting remote metasfresh or adempiere service"
	ssh -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST} "${REMOTE_EXEC_DIR}/start_service.sh" 
fi


clean_rollout_appserver

trace $(basename $0) "END"
