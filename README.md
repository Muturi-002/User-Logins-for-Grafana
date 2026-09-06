# User Logins For Grafana Visualization

This project is designed to visualize Grafana user logins using the `journalctl` and `last`/`lastb` commands. This project is a prerequisite in completing the **Grafana Emerging Champions Cohort 2** program, though a hands-on technical project was just one of the options provided.

## Project Structure

```bash

├── logins.sh
├── logins_loki_ingest.sh
└── logins_v2.sh

```

The final file used for this project is the [Loki bash script](./logins_loki_ingest.sh), which is formatted for the log ingestion by Loki and visualization using Grafana. The other login scripts, `logins.sh` and `logins_v2.sh` were used for testing on the server. The [first file](./logins.sh) proved to be too confusing to follow up and make the desired changes (Git was yet to be initialized in the working repo, hence two files).

## Scripting
1. All custom variables are declared at the start of the script.
2. **Check 1:** Checking existing users in the specified user group. This narrows the project scope on particular users logging into the server. For this project, user group name starts with *grafana-*.
3. **Check 2:** Checking whether two log files exist: `script_run.log` and `user-logins.log`. These are the two main files for this project.
   - `script_run.log` records events tied to the execution of the bash script. These include creating new files, deleting temporary files, and log collection processes/stages.
   - `user-logins.log` records all logins defined in the script. Consists of a merger between the log sources `journalctl` command, and  `last`/`lastb` commands that read from the files `/var/log/wtmp` and `/var/log/btmp` respectively.
4. **Check 3:** Checking any changes in user logins, whether sessions are new, active, or have failed. These login logs are collected using three helper functions: `collect_ssh_logs`, `collect_last_logs`, and `collect_user_change_logs`.
   - `collect_ssh_logs`- ssh logs, from the `journalctl` command
   - `collect_last_logs`- output from both the `last -Ff /var/log/wtmp` and `lastb -Ff /var/log/btmp` files, with defined formatting.
   - `collect_user_change_logs`- user switch logs using `journalctl` command. Had to define and correlate logs based on the epoch time and user with sudo privileges. Challenging at best.
5. **Check 4:** Check and merge all logs into `user-logins.log`.
   - Check mainly on `last` logs, with its dynamic nature between active and terminated user sessions.

### Script output images
*To be appended later*

## Conclusion
A Medium blog on this project will be published, highlighting challenges, thought process, and implementation of the project. This project was divided into 2 phases:
  - Scripting
  - Grafana visualization.

[User Logins Grafana Visualization article]()
