#!/bin/bash


# Script is running on an Ubuntu instance. Currently, no other Linux distro(RHEL, OpenSuse OSs) are considered
#

# =========================================================================================================================
# ---- Setting up base files ---
SERVICE_LOGS_DIR="/var/log"
DIR="$SERVICE_LOGS_DIR/grafana-users-loki"
SUPER_LOG_FILE="$DIR/user-logins.log"
SSH_LOGS_FILE="$DIR/user-ssh-logs.log"
LAST_LOGS_FILE="$DIR/user-last-logs.log"
USER_SWITCH_LOGS_FILE="$DIR/user-chg-logs.log"

# --- Setting up temporary files for log comparison and ammendment ---
TEMP_LOG_DIR="/tmp/temp-grafana-loggers-loki"
TEMP_LOG_FILE="$TEMP_LOG_DIR/tmp-grafana-"$(basename $SUPER_LOG_FILE)""
TEMP_SSH_LOGS_FILE="$TEMP_LOG_DIR/tmp-grafana-"$(basename $SSH_LOGS_FILE)""
TEMP_LAST_LOGS_FILE="$TEMP_LOG_DIR/tmp-grafana-"$(basename $LAST_LOGS_FILE)""
TEMP_USER_SWITCH_LOGS_FILE="$TEMP_LOG_DIR/tmp-grafana-"$(basename $USER_SWITCH_LOGS_FILE)""

# --- Setup log file for script execution. This will 'put' out the noise on first script run. ---
SCRIPT_RUN_FILE="$DIR/script_run.log"

# ========================================================================================================================
#
user_log_success () {
        local epoch="$1" source="$2" username="$3" message="$4"
        local human_ts=$(date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S')
        printf 'epoch=%s loginSource=%s loginLevel=SUCCESS user=%s timestamp="%s" systemMessage="%s"\n' "$epoch" "$source" "$username" "$human_ts" "$message" | sudo tee -a "$SUPER_LOG_FILE" > /dev/null
}
# Record failed login attempts
user_log_fail () {
        local epoch="$1" source="$2" username="$3" message="$4"
        local human_ts=$(date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S')
        printf 'epoch=%s loginSource=%s loginLevel=FAIL user=%s timestamp="%s" systemMessage="%s"\n' "$epoch" "$source" "$username" "$human_ts" "$message" | sudo tee -a "$SUPER_LOG_FILE" > /dev/null
}
# Record only user change logs format
user_log_info () {
	local epoch="$1" source="$2" username="$3" message="$4"
	local human_ts=$(date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S')
	printf 'epoch=%s loginSource=%s loginLevel=INFO user=%s timestamp="%s" systemMessage="%s"\n' "$epoch" "$source" "$username" "$human_ts" "$message" | sudo tee -a "$SUPER_LOG_FILE" > /dev/null
}

# ----- Run script logs ------
script_log_success () {
        echo "$(date '+%Y-%m-%d %H:%M:%S') SUCCESS: $1" | sudo tee -a "$DIR/script_run.log" > /dev/null
}
script_log_error () {
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $1" | sudo tee -a "$DIR/script_run.log" > /dev/null
}
script_log_info () {
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: $1" | sudo tee -a "$DIR/script_run.log" > /dev/null
}

# =========================================================================================================================

# Record time of run
script_log_info "Script executed at $(date '+%Y-%m-%d %H:%M:%S') by user $(whoami)..."
# Placeholder group name - replace with your group
GROUP_NAME="$(getent group | awk -F: '{print $1}' | grep grafana-)"
script_log_info "User group assessed: $GROUP_NAME"

GROUP_MEMBERS="$(getent group $GROUP_NAME | awk -F: '{print $4}' | tr ',' '\n')"

is_group_member () {
        echo "$GROUP_MEMBERS" | grep -qxF "$1"
}

if [[ -z "$GROUP_MEMBERS" ]]; then
        script_log_info "WARNING: no members resolved for group(s) '$GROUP_NAME' — check GROUP_NAME matches a real group. No logins will be recorded until this is fixed."
else
        script_log_info "Group members tracked:$(echo "$GROUP_MEMBERS")"
fi

## Creating an array for the user members. This array needed for the log functions
GROUP_MEMBERS_ARRAY=()
if [[ -n "$GROUP_MEMBERS" ]]; then
        while IFS= read -r m; do
                [[ -n "$m" ]] && GROUP_MEMBERS_ARRAY+=("$m")
        done <<< "$GROUP_MEMBERS"
fi

GROUP_REGEX=""
if [[ ${#GROUP_MEMBERS_ARRAY[@]} -gt 0 ]]; then
        GROUP_REGEX=$(IFS='|'; echo "${GROUP_MEMBERS_ARRAY[*]}")
fi

# Check if current user has sudo permissions

script_log_info "Current user running script '$0': $(whoami)"
if id -nG $(whoami) | grep -qw sudo; then
        script_log_info "User '$(whoami)' has sudo privileges. Proceed with caution!!!"
elif [ "$(whoami)" == "root" ]; then
	script_log_info "Script running as root user. Execution of script done by cron job with root user as permitted user"
else
        script_log_info "User does not have sudo privileges. Ensure user $(whoami) has these privileges or use another user with sudo privileges. Contact your admin for support and any enquiries on this script"
        exit 0
fi

# ========================================================================================================================
# ***** Base functions for checking required log files exist *****

create_dir () {
        script_log_info "Directory '$DIR' does not exist!\\nCreating directory '$(basename $"DIR")' in root subdirectory '$SERVICE_LOGS_DIR' now..."
        sudo mkdir "$DIR"
        if [[ -d $DIR ]]; then
                script_log_success "Directory '$DIR' created"
        fi
        create_log_file
}
create_log_file () {
        script_log_info "Creating new log files: $SUPER_LOG_FILE $SSH_LOG_FILE $LAST_LOGS_FILE $USER_SWITCH_LOGS_FILE"
        sudo touch "$SUPER_LOG_FILE" "$SSH_LOGS_FILE" "$LAST_LOGS_FILE" "$USER_SWITCH_LOGS_FILE"
        if [[ -f $SUPER_LOG_FILE && -f "$SSH_LOGS_FILE" && -f "$LAST_LOGS_FILE" && -f "$USER_SWITCH_LOGS_FILE" ]]; then
                script_log_success "Log files created and ready for use"
        fi
}

# Ensure log and state files exist
log_file_checker () {
        script_log_info "Checking base directory and file"
        if [[ -d $DIR ]]; then
                script_log_info "Directory '$DIR' exists. Checking required log files exist..."
                if [[ -f $SUPER_LOG_FILE && -f "$SSH_LOGS_FILE" && -f "$LAST_LOGS_FILE" && -f "$USER_SWITCH_LOGS_FILE" ]]; then
                        script_log_info "Log files exists in the directory '$DIR'. Creating temp files now..."
                else
                        create_log_file
                fi
        else
                script_log_info "Directory '$DIR' does not exist. Creating new one...\n"
                create_dir
        fi
}


# ========================================================================================================================
# ----- Functions for tempoary log creation and comparison -----
create_temp_dir () {
        script_log_info "Creating new temp directory: $TEMP_LOG_DIR"
        sudo mkdir "$TEMP_LOG_DIR"
        if [[ -d $TEMP_LOG_DIR ]]; then 
                script_log_success "Temporary directory created successfully."
        fi
        create_temp_logfile
}
create_temp_logfile () {
        script_log_info "Creating new temp log file: $TEMP_LOG_FILE"
        sudo touch "$TEMP_LOG_FILE" "$TEMP_LAST_LOGS_FILE" "$TEMP_SSH_LOGS_FILE" "$TEMP_USER_SWITCH_LOGS_FILE"
        if [[ -f "$TEMP_LOG_FILE" && -f "$TEMP_LAST_LOGS_FILE" && -f "$TEMP_SSH_LOGS_FILE" && -f "$TEMP_USER_SWITCH_LOGS_FILE" ]]; then
                script_log_success "Temporary log file created successfully."
        fi
}

# Check files exist
temp_log_checker () {
        script_log_info "--- Checking required temporary directory and file(s) exist..."
        if [[ -d $TEMP_LOG_DIR ]]; then 
                script_log_info "Directory '$TEMP_LOG_DIR' exists. Checking temp log file..."
		if [[ -f $TEMP_LOG_FILE && -f $TEMP_SSH_LOGS_FILE && -f $TEMP_LAST_LOGS_FILE && -f $TEMP_USER_SWITCH_LOGS_FILE ]]; then
                        script_log_info "Temp log files exist. Proceed to handle log collection"
                else
                        script_log_info "One or more temp files missing. Creating now..."
                        create_temp_logfile
                fi
        else
                script_log_info "Temporary directory '$TEMP_LOG_DIR' does not exist. Creating now..."
                create_temp_dir
        fi
}

clean_up_temp_files () {
        script_log_info "Cleaning up temporary files $TEMP_LOG_DIR/*..."
        sudo rm -rf $TEMP_LOG_DIR
        if [[ -d $TEMP_LOG_DIR ]]; then
                script_log_error "Cleanup failed!! Contact admin"
        else
                script_log_success "Cleanup successful. $TEMP_LOG_DIR and its contents deleted successfully."
        fi
}

collect_ssh_logs () {
	# SSH logs collection using journalctl. Alternatively, these logs can be referred to from the file '/var/log/auth.log', but we need logs from the direct source as generated.
	# Using /var/log/auth.log file is okay if it was the only source of information I'm looking for.
        if [[ -z "$GROUP_REGEX" ]]; then
                script_log_info "No group members resolved; skipping SSH log collection"
                return
        fi
 
        journalctl -u ssh -o short-iso --no-pager -g "for (${GROUP_REGEX}) from" 2>/dev/null | while IFS= read -r line; do
                ts=$(echo "$line" | awk '{print $1}')
                epoch=$(date -d "$ts" +%s 2>/dev/null) # Time in Epoch (check 'man date' with search reference '%'.
                [[ -z "$epoch" ]] && continue
                username=$(echo "$line" | grep -oP 'for \K(invalid user )?\S+(?= from)' | sed 's/^invalid user //') # Lack of 'P' flag results in the logs not to be written.
                [[ -z "$username" ]] && username="unknown"
                is_group_member "$username" || continue
                echo "$epoch ssh $username $line" | sudo tee -a "$TEMP_SSH_LOGS_FILE" > /dev/null
        done

}

collect_last_logs () {
	# Using the log files, btmp and wtmp, to recreate logs from the last and lastb commands. Using utmpdump leads to complexities I am yet to get and know.
	# Formatting the outputs is easier with reading from a file. No need of reinventing the wheel for this matter.
        if [[ ${#GROUP_MEMBERS_ARRAY[@]} -eq 0 ]]; then
                script_log_info "No group members resolved; skipping last/lastb log collection"
                return
        fi
 
        local user
        user=$(IFS='|'; echo "${GROUP_MEMBERS_ARRAY[*]}")
 
        sudo last -Ff /var/log/wtmp 2>/dev/null | grep -E "^(${user})[[:space:]]" | while IFS= read -r line; do
                username=$(echo "$line" | awk '{print $1}')
                is_group_member "$username" || continue
                raw_ts=$(echo "$line" | grep -oE '[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}' | head -1)
                epoch=$(date -d "$raw_ts" +%s 2>/dev/null)
                [[ -z "$epoch" ]] && continue
                echo "$epoch last $username $line" | sudo tee -a "$TEMP_LAST_LOGS_FILE" > /dev/null
        done
 
        sudo lastb -Ff /var/log/btmp 2>/dev/null | grep -E "^(${user})[[:space:]]" | while IFS= read -r line; do
                username=$(echo "$line" | awk '{print $1}')
                is_group_member "$username" || continue
                raw_ts=$(echo "$line" | grep -oE '[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}' | head -1)
                epoch=$(date -d "$raw_ts" +%s 2>/dev/null)
                [[ -z "$epoch" ]] && continue
                echo "$epoch lastb $username $line" | sudo tee -a "$TEMP_LAST_LOGS_FILE" > /dev/null
        done
}

collect_user_changes_logs () {
	# These logs are collected using the journalctl command. In this scenario, all members of the grafana-user-loggers group do not have sudo permissions to carry out changeability.
	# These logs would therefore look at which user switched to a user member of the 'grafana-users-loggers' group.
	if [[ -z "$GROUP_REGEX" ]]; then
                script_log_info "No group members resolved; skipping user-change log collection"
                return
        fi
 
        journalctl -t su -t sudo -t systemd-logind -o short-iso --no-pager \
		-g "(for user (${GROUP_REGEX})|of user (${GROUP_REGEX})|USER=(${GROUP_REGEX}))" 2>/dev/null \
                | grep -E "session opened|session closed|USER=" | while IFS= read -r line; do
                ts=$(echo "$line" | awk '{print $1}')
                epoch=$(date -d "$ts" +%s 2>/dev/null)
                [[ -z "$epoch" ]] && continue
                # Three distinct line shapes here:
		# Group members do not have sudo privileges. For testing purposes, one user member would be given these privileges to for the logs to be updated.
		# All user switch changes are assumed to be done by someone outside the group.
		#  1. PAM "session opened for user TARGET(...) by ACTOR(...)" (sudo, su)  — ACTOR authenticated; TARGET is just the identity assumed. 
		#  	Attribute to ACTOR, since being sudo'd INTO isn't a login.
                #  2. systemd-logind "New session N of user X." — X's own real interactive session; attribute to X directly.
                #  3. PAM "session closed for user TARGET" (sudo, su) — closed messages carry no actor info at all, 
		#  	so there's no reliable way to attribute this without risking the exact misattribution being fixed here. Skip rather than guess.
		#  4. sudo's own command-invocation line ("ACTOR : TTY=... ; USER=TARGET
		#  	; COMMAND=...") — a separate log line from the PAM session line,
		#    	and the one actually produced for a plain `sudo -u TARGET cmd`
		#    	switch. TARGET is the account the command runs as.
                if echo "$line" | grep -qP 'for user \S+'; then
                        username=$(echo "$line" | grep -oP 'for user \K[^ (]+')
                elif echo "$line" | grep -qP 'session \d+ of user'; then
                        username=$(echo "$line" | grep -oP 'session \d+ of user \K\S+' | sed 's/\.$//')
		elif echo "$line" | grep -qP '\bUSER=\S+'; then
			username=$(echo "$line" | grep -oP 'USER=\K\S+')
                else
                        continue
                fi
                [[ -z "$username" ]] && username="unknown"
                is_group_member "$username" || continue
                echo "$epoch usrchg $username $line" | sudo tee -a "$TEMP_USER_SWITCH_LOGS_FILE" > /dev/null
        done
}

compare_and_merge () {
	# Purpose: compare and merge logs from all sources as defined by the previous 3 functions.
	# Output file to act as destination of the files. Separate files for each log type (based on source) will be kept.
	#
	# -----Compare and update SSH logs-----
	if [ $(wc -l < $SSH_LOGS_FILE) -eq 0 ]; then
		script_log_info "SSH Log file '$SSH_LOGS_FILE' empty. Appending file from $TEMP_SSH_LOGS_FILE..."
		sudo cat $TEMP_SSH_LOGS_FILE | sudo tee -a "$SSH_LOGS_FILE" >/dev/null 2>&1
		script_log_success "'$SSH_LOGS_FILE' appended successfully."
	else
		if diff -q $SSH_LOGS_FILE $TEMP_SSH_LOGS_FILE > /dev/null; then
			script_log_info "No changes on SSH logs"
		else
			grep -Fvxf $SSH_LOGS_FILE $TEMP_SSH_LOGS_FILE | sudo tee -a "$SSH_LOGS_FILE" 2>/dev/null
			script_log_success "'$SSH_LOGS_FILE' appended successfully."
		fi
	fi

	# -----Compare and update LAST logs -----
	if [ $(wc -l < $LAST_LOGS_FILE) -eq 0 ]; then
                script_log_info "LAST Log file '$LAST_LOGS_FILE' empty. Appending file from $TEMP_LAST_LOGS_FILE..."
                sudo cat $TEMP_LAST_LOGS_FILE | sudo tee -a "$LAST_LOGS_FILE" >/dev/null 2>&1
                script_log_success "'$LAST_LOGS_FILE' appended successfully."
        else
                if diff -q $LAST_LOGS_FILE $TEMP_LAST_LOGS_FILE > /dev/null; then
                        script_log_info "No changes on LAST logs"
                else
                        grep -Fvxf $LAST_LOGS_FILE $TEMP_LAST_LOGS_FILE | sudo tee -a "$SSH_LAST_FILE" 2>/dev/null
                        script_log_success "'$LAST_LOGS_FILE' appended successfully."
                fi
        fi

	# -----Compare and update USER SWITCH logs-----
	if [ $(wc -l < $USER_SWITCH_LOGS_FILE) -eq 0 ]; then
                script_log_info "User Switch log file '$USER_SWITCH_LOGS_FILE' empty. Appending file from $TEMP_USER_SWITCH_LOGS_FILE..."
                sudo cat $TEMP_USER_SWITCH_LOGS_FILE | sudo tee -a "$USER_SWITCH_LOGS_FILE" >/dev/null 2&>1
                script_log_success "'$USER_SWITCH_LOGS_FILE' appended successfully."
        else
		if diff -q $USER_SWITCH_LOGS_FILE $TEMP_USER_SWITCH_LOGS_FILE > /dev/null; then
                        script_log_info "No changes on user switch logs"
                else
                        grep -Fvxf $USER_SWITCH_LOGS_FILE $TEMP_USER_SWITCH_LOGS_FILE | sudo tee -a "$USER_SWITCH_LOGS_FILE" 2>/dev/null
                        script_log_success "'$USER_SWITCH_LOGS_FILE' appended successfully."
                fi
        fi
	# =======================================================================================================================================
	 existing_keys=$(awk '{
                epoch=""; source="";
                for (i=1;i<=NF;i++) {
                        split($i, kv, "=")
                        if (kv[1]=="epoch") epoch=kv[2]
                        if (kv[1]=="loginSource") source=kv[2]
                }
                if (epoch!="" && source!="") print epoch","source
	        }' "$SUPER_LOG_FILE" 2>/dev/null | sort -u)
		# The change in the key-value pair is as a result of the reformatted log output for Loki. Initial format (check previous commit hash) 
		# resulted in duplication of existing logs.
       	cat "$SSH_LOGS_FILE" "$LAST_LOGS_FILE" "$USER_SWITCH_LOGS_FILE" 2>/dev/null | sort -k1,1n | awk '!seen[$1","$2]++' | while IFS=' ' read -r epoch source username message; do
		[[ -z "$epoch" ]] && continue
       		key="$epoch,$source"
 	
	 	if echo "$existing_keys" | grep -qxF "$key"; then
			if [[ "$source" == "last" ]]; then
				existing_line=$(grep "^${epoch} ${source} SUCCESS ${username}" "$SUPER_LOG_FILE" 2>/dev/null)
				existing_message=$(echo "$existing_line" | grep -oP 'systemMessage=\K.*') # 'grep -oP' eases capture of last fields, does not depend on the field's column position as compared to 'awk' and 'cut'
				if [[ -n "$existing_line" && "$existing_message" != "$message" ]]; then
					script_log_info "Updating changed 'last' record for $username (session $epoch details changed)"
					sudo sed -i "\#epoch=${epoch} loginSource=${source} loginLevel=SUCCESS user=${username} #d" "$SUPER_LOG_FILE"
					user_log_success "$epoch" "$source" "$username" "$message"
				else
					script_log_info "No existing sessions have been ended. All previously recorded sessions remain intact. Proceed to check other sources."
				fi
			fi
			continue
		fi

                if [[ "$source" == "lastb" ]]; then
                        user_log_fail "$epoch" "$source" "$username" "$message"
		elif [[ "$source" == "last" ]]; then 
			user_log_success "$epoch" "$source" "$username" "$message"
		else 
			user_log_info "$epoch" "$source" "$username" "$message"
		fi

	done

}

collect_logs () {
	script_log_info "Starting log collection"
	collect_ssh_logs
	collect_last_logs
	collect_user_changes_logs
	compare_and_merge
	script_log_info "Log collection completed."	
}

script_run () {
	log_file_checker
	temp_log_checker
	collect_logs
	clean_up_temp_files
}

# Run program
script_run

# Set cron job for script execution
if id -nG $(whoami) | grep -qw sudo; then
       if [[ -f /etc/cron.d/collect-logins-loki ]]; then
	       if [ $(awk '{print $6, $7}' | grep $0)]; then
		       script_log_info "Automated execution of $0 is set and enabled"
	       fi
	       sudo systemctl daemon-reload
       else
	       sudo touch /etc/cron.d/collect-logins-loki
	       # Run script after every 3 minutes
	       echo "*/5 * * * * root /bin/bash /home/ubuntu/grafana-user-logins/logins_loki_ingest.sh" | sudo tee /etc/cron.d/collect-logins-loki >/dev/null
	       sudo chmod 700 /etc/cron.d/collect-logins-loki
	       script_log_success "Cron job for this script - $0 - set successfully"
	       sudo systemctl daemon-reload
       fi
else
        script_log_info "User does not have sudo privileges. Cannot set up this script's cron job."
fi


# Denote time of end script execution
script_log_info "Script run successfully. End time: $(date '+%Y-%m-%d %H:%M:%S')"
exit

