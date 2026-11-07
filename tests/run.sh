#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
bash -n server-auditor.sh
bash -n tests/run.sh
source ./server-auditor.sh
language=en

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { [[ $1 == *"$2"* ]] || fail "missing: $2"; }
omits() { [[ $1 != *"$2"* ]] || fail "unexpected: $2"; }

omits "$(safety_line keep example)" $'\033['
(
    colors_enabled() { return 0; }
    contains "$(safety_line keep example)" $'\033[31m[KEEP]'
    contains "$(safety_line clean example)" $'\033[32m[CLEANUP]'
    contains "$(safety_line review example)" $'\033[33m[REVIEW]'
)

[[ $(usage_status 84) == OK ]]
[[ $(usage_status 85) == WARN ]]
[[ $(usage_status 95) == CRIT ]]
[[ $(size_bytes 100M) == 104857600 ]]
[[ $(size_bytes 1GiB) == 1073741824 ]]
if size_bytes 'secret.invalid'; then fail 'accepted invalid size'; fi

output=$(journal_config $'[Journal]\nStorage=persistent\nSystemMaxUse=1G\nRuntimeMaxUse=110M\n[Other]\nStorage=secret.invalid\n[Journal]\nSystemMaxUse=100M')
contains "$output" 'SystemMaxUse=104857600 bytes'
contains "$output" 'RuntimeMaxUse=115343360 bytes'
contains "$output" 'Storage=persistent'
omits "$output" 'secret.invalid'
output=$(journal_config $'[Journal]\nSystemMaxUse=100M\nSystemMaxUse=')
contains "$output" 'SystemMaxUse uses the systemd default'

logrotate() {
    printf 'rotating pattern: /var/log/private.log weekly (7 rotations)\n'
    printf 'empty log files are not rotated, log files >= 104857600 are rotated earlier\n'
    printf 'unrelated debug output\n'
}
find() {
    case $* in
        *-size*) printf '104857601\t/var/log/other.log\0%s\t%s\0' 209715200 $'/var/log/private\nlog' ;;
        *) printf '104857601\n209715200\n' ;;
    esac
}
output=$(logrotate_check)
contains "$output" 'rotation_rules=1'
omits "$output" 'files_over_100MiB'
omits "$output" '/var/log/private'
output=$(large_logs_check)
contains "$output" 'files_over_100MiB=2'
omits "$output" '/var/log/private'
output=$(details=1 logrotate_check; details=1 large_logs_check)
contains "$output" '104857600'
contains "$output" 'apparent_bytes=209715200 path='
contains "$output" '/var/log/private\nlog'
omits "$output" 'unrelated'
unset -f logrotate find

(
    tail() {
        printf '%s\n' 'Nov  6 17:42:11 host rsyslogd[471]: example' \
            '2026-11-06T17:42:12+01:00 host rsyslogd: example' \
            'Nov  6 17:42:13 host kernel: example'
    }
    [[ $(syslog_sources /var/log/syslog) == $'2 rsyslogd\n1 kernel' ]]
    fuser() { return 1; }
    archive_source_ready /var/log/syslog.1
    if archive_source_ready /var/log/syslog 2>/dev/null; then fail 'accepted active syslog'; fi
    fuser() { printf '1234\n'; }
    if archive_source_ready /var/log/syslog.1 2>/dev/null; then fail 'accepted open syslog archive'; fi
    if archive_source_ready /var/log/syslog.2.gz 2>/dev/null; then fail 'accepted open compressed archive'; fi
    fuser() { printf 'permission denied\n' >&2; return 1; }
    if archive_source_ready /var/log/syslog.1 2>/dev/null; then fail 'ignored fuser error'; fi
    has() { [[ $1 != fuser ]]; }
    proc_archive_closed() { [[ $1 == /var/log/syslog.1 ]]; }
    archive_source_ready /var/log/syslog.1
    if archive_source_ready /var/log/syslog.2 2>/dev/null; then fail 'ignored incomplete proc scan'; fi
    if archive_source_ready /var/log/syslog 2>/dev/null; then fail 'allowed active syslog via proc fallback'; fi
)

docker_local() {
    case $* in
        'container ls -a --format '*) printf 'aabbccddeeff|running|private-app\n112233445566|exited|old-app\n998877665544|paused|app\n' ;;
        'inspect '*project.working_dir*aabbccddeeff)
            printf 'project\t"/srv/my app"\nfiles\t"/srv/my app/compose.yaml"\nbind\t"/srv/data" → "/data"\n' ;;
        'inspect '*project.working_dir*) printf '\n' ;;
        'inspect '*aabbccddeeff) printf 'json-file||\n' ;;
        'inspect '*112233445566) printf 'local||\n' ;;
        'inspect '*998877665544) printf 'json-file|10m|\n' ;;
        'image ls '*) printf '123456abcdef\n123456abcdef\n' ;;
        'system df '*) printf 'Build Cache|9|1|12.5MB|10MB (80%%)\nLocal Volumes|2|1|36 B|0 B (0%%)\n' ;;
        *) fail "unexpected Docker call: $*" ;;
    esac
}
docker() { fail "unexpected unfiltered Docker call: $*"; }
output=$(docker_check)
contains "$output" 'private-app (aabbccddeeff) — running: json-file has no verified'
contains "$output" 'old-app (112233445566) — exited: local rotation, max_size_bytes=20971520 max_files=5'
contains "$output" 'app (998877665544) — paused: json-file rotation, max_size_bytes=10485760 max_files=1'
contains "$output" 'Dangling images: 1'
contains "$output" 'records=9 active=1 size=12.5MB reclaimable=10MB (80%)'
contains "$output" 'Local Volumes: records=2 active=1 size=36 B'
omits "$output" '/srv/'
output=$(details=1 docker_check)
contains "$output" 'Container private-app (aabbccddeeff): state=running'
contains "$output" 'Container old-app (112233445566): state=exited'
contains "$output" 'Compose project directory "/srv/my app"'
contains "$output" 'Compose configuration files "/srv/my app/compose.yaml"'
contains "$output" 'bind mount "/srv/data" → "/data"'
contains "$output" 'Compose project directory is not recorded in labels'
contains "$(language=ru docker_check)" 'Контейнер private-app (aabbccddeeff) — запущен'

(
    test_dir=$(mktemp -d)
    full_id=aabbccddeeff$(printf '%052d' 0)
    log_dir=$test_dir/$full_id
    log_file=$log_dir/$full_id-json.log
    trap 'rm -f -- "$log_file" "$log_file.1" "$log_file.2.gz" "$log_file.unrelated"; rmdir -- "$log_dir" "$test_dir"' EXIT
    mkdir -- "$log_dir"
    touch -- "$log_file" "$log_file.1" "$log_file.2.gz" "$log_file.unrelated"
    docker_local() {
        [[ $* == *'{{.LogPath}}'* ]] || return 1
        printf '%s\n' "$log_file"
    }
    stat() {
        case ${*: -1} in
            "$log_file") printf '2048 1000000\n' ;;
            "$log_file.1") printf '1024 500000\n' ;;
            "$log_file.2.gz") printf '512 250000\n' ;;
            *) fail 'tried to count unrelated Docker file' ;;
        esac
    }
    output=$(docker_json_log_usage aabbccddeeff 'Контейнер app' 'Container app')
    contains "$output" 'logs use 1.75 MiB, files: 3'
    output=$(format=json docker_json_log_usage aabbccddeeff 'Контейнер app' 'Container app')
    contains "$output" 'allocated_bytes=1835008 apparent_bytes=1750000'
    if docker_json_log_usage 112233445566 x x; then fail 'accepted a different container path'; fi
)

output=$(language=ru memory_usage 4009836 2127196 ОЗУ RAM доступно available 'raw-ru' 'raw-en')
contains "$output" 'ОЗУ: занято 1,80 ГиБ из 3,82 ГиБ (46,9%), доступно 2,03 ГиБ'
output=$(memory_usage 2097148 2097148 Подкачка Swap свободно free 'raw-ru' 'raw-en')
contains "$output" 'Swap: 0 KiB used of 2.00 GiB (0.0%), 2.00 GiB free'
contains "$(format=json memory_usage 512 10 ОЗУ RAM доступно available 'raw-ru' 'raw-en')" '"message":"raw-en"'

df() {
    printf 'Use%% Avail IUse%% Size Used Mounted on\n96%% 1024 10%% 2048 1024 /secret.invalid\n80%% 256 90%% 1024 768 /boot\n'
    printf '75%% 2147483648 10%% 10737418240 7516192768 /\n'
}
output=$(disk_check)
contains "$output" 'blocks_used=96% available_bytes=1024'
contains "$output" '(/boot): inodes_used=90%'
omits "$output" 'secret.invalid'
output=$(
    overview_group=2
    declare -a overview_notes=() overview_details=() overview_ranks=() overview_reasons=()
    disk_check
    printf '%s' "${overview_notes[1]}"
)
contains "$output" '/ — total 10.00 GiB · used 7.00 GiB · available 2.00 GiB'
contains "$output" 'Local filesystems: 3'
unset -f df

dpkg-query() {
    printf 'installed linux-image-6.12.43+deb13-amd64\ninstalled proxmox-kernel-6.8.12-4-pve-signed\n'
    printf 'installed linux-image-6.1.0-9-secret.invalid\nconfig-files linux-image-6.1.0-8-amd64\n'
}
uname() { printf '6.12.43+deb13-amd64\n'; }
output=$(kernel_check)
contains "$output" 'Running kernel: 6.12.43+deb13-amd64'
contains "$output" 'Installed kernel release: 6.8.12-4-pve'
contains "$output" '6.12.43+deb13-amd64 (running)'
contains "$output" '6.8.12-4-pve (inactive)'
contains "$output" 'Versioned kernel packages: 3'
contains "$output" 'APT removal plan unavailable'
omits "$output" 'secret.invalid'
omits "$output" 'no matching installed package'
autoremove_known=1
output=$(kernel_check)
contains "$output" 'Inactive kernel packages: 2. Among these, in the APT removal plan: 0'
autoremove_candidates=(proxmox-kernel-6.8.12-4-pve-signed:amd64 linux-image-6.12.43+deb13-amd64)
output=$(kernel_check)
contains "$output" 'APT removal candidate for kernel image: proxmox-kernel-6.8.12-4-pve-signed'
contains "$output" 'APT proposes removing the running kernel'
contains "$output" 'Inactive kernel packages: 2. Among these, in the APT removal plan: 1'
unset -f uname dpkg-query

dpkg() { printf 'broken package with private name secret.invalid\n'; }
apt-mark() { printf 'private-package\n'; }
apt-get() {
    [[ $1 == -s && $* == *'Dir::Cache::pkgcache='* && $* == *--with-new-pkgs* ]] ||
        fail 'audit did not request a cache-free simulation using the upgrade options'
    printf 'Repository: https://user:password@secret.invalid\n'
    printf '2 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.\n'
}
output=$(apt_check)
contains "$output" 'dpkg reports incomplete'
contains "$output" 'Held packages: 1'
contains "$output" 'upgraded=2 new=0 kept=1'
omits "$output" 'secret.invalid'
omits "$output" 'private-package'
unset -f dpkg apt-mark apt-get

find() { printf '4\n2\n'; }
apt-get() {
    [[ $1 == -s && $* == *'Dir::Cache::pkgcache='* && ${*: -1} == autoremove ]] ||
        fail 'unsafe or unexpected autoremove call'
    printf '0 upgraded, 0 newly installed, %s to remove and 0 not upgraded.\n' "${MOCK_REMOVE_COUNT:-2}"
    printf 'Remv linux-image-6.1.0-9-amd64 [1]\nRemv private-lib:amd64 [1]\n'
}
dpkg-query() {
    case ${*: -1} in
        linux-image-6.1.0-9-amd64) printf 1024 ;;
        *) return 1 ;;
    esac
}
output=$(cleanup_check)
contains "$output" 'files=2 allocated_bytes=3072'
contains "$output" 'candidates=2 estimated_installed_KiB=1024 unknown_sizes=1'
omits "$output" 'private-lib'
contains "$(details=1 cleanup_check)" 'linux-image-6.1.0-9-amd64 installed_KiB=1024'
contains "$(MOCK_REMOVE_COUNT=3 cleanup_check)" 'removal actions do not match'
unset -f find apt-get dpkg-query

apt-get() {
    printf 'apt:%s:%s\n' "${DEBIAN_FRONTEND:-unset}" "$*"
    case " $* " in
        *' update ') return "${MOCK_APT_FAILURE:-0}" ;;
        *' --no-remove '*' APT::Get::AutomaticRemove=false --with-new-pkgs '*' upgrade ') ;;
        *) fail "unexpected APT call: $*" ;;
    esac
}
output=$(apply_update 1)
contains "$output" 'apt:unset:-o APT::Update::Error-Mode=any update'
contains "$output" 'apt:noninteractive:--no-remove -o APT::Get::AutomaticRemove=false --with-new-pkgs -y'
if output=$(MOCK_APT_FAILURE=42 apply_update 1); then fail 'ignored failed refresh'; fi
omits "$output" ' upgrade'
output=$(apply_update 0 <<< n)
contains "$output" 'apt:unset:-s --no-remove'
contains "$output" 'Installation cancelled'
omits "$output" 'Assume-Yes'
output=$(apply_update 0 <<< yes)
contains "$output" 'Assume-Yes=false'
unset -f apt-get

(
    run_logged_maintenance() { shift; "$@"; }
    apt-get() {
        if [[ $1 == -s ]]; then
            printf '0 upgraded, 0 newly installed, 1 to remove and 0 not upgraded.\nRemv unused-lib [1]\n'
        else
            printf 'apt action: %s\n' "$*"
        fi
    }
    journalctl() { printf 'journal action: %s\n' "$*"; }
    cleanup_check() {
        autoremove_known=1
        autoremove_candidates=("$MOCK_PACKAGE")
    }
    output=$(maintenance_action clean <<< n)
    omits "$output" 'apt action:'
    contains "$(maintenance_action clean <<< yes)" 'apt action: clean'
    contains "$(maintenance_action rotate <<< yes)" 'journal action: --rotate'
    output=$(maintenance_action vacuum <<< n)
    contains "$output" 'journal action: --disk-usage'
    omits "$output" 'journal action: --rotate'
    contains "$(maintenance_action vacuum <<< yes)" 'journal action: --rotate --vacuum-size=104857600'
    output=$(MOCK_PACKAGE=linux-image-6.8.0-142-generic maintenance_action autoremove <<< yes 2>&1) &&
        fail 'allowed kernel removal'
    contains "$output" 'Removal from the menu was stopped'
    omits "$output" 'apt action:'
    output=$(MOCK_PACKAGE=unused-lib maintenance_action autoremove <<< $'yes\nyes')
    contains "$output" 'apt action: -o quiet=0 -o APT::Get::Assume-Yes=false -o APT::Get::Purge=false -o APT::Get::AutomaticRemove=false remove unused-lib'
    df() { printf 'Avail\n123456789\n'; }
    logrotate() {
        if [[ $1 == -d ]]; then
            printf 'considering log /var/log/syslog\n  log needs rotating\n'
        else
            printf 'rotation action: %s\n' "$*"
        fi
    }
    output=$(maintenance_action logrotate <<< n)
    contains "$output" 'identified files due for rotation:'
    contains "$output" '/var/log/syslog'
    omits "$output" 'rotation action:'
    contains "$(maintenance_action logrotate <<< yes)" 'rotation action: -v /etc/logrotate.conf'
)

(
    test_dir=$(mktemp -d)
    trap 'rm -f -- "$test_dir/history.log" "$test_dir/restore.info" "$test_dir/journald.conf.before" "$test_dir/journald.conf" "$test_dir/term.once" "$test_dir/rsyslog.conf.before" "$test_dir/rsyslog" "$test_dir/maintenance.lock" "$test_dir/example.gz" "$test_dir/backup/example.gz"; if [[ -d $test_dir/backup ]]; then rmdir -- "$test_dir/backup"; fi; rmdir -- "$test_dir"' EXIT
    maintenance_state=$test_dir
    journal_dropin=$test_dir/journald.conf
    history_begin() { printf '%s\n' "$test_dir"; }
    sync() { :; }
    flock() { :; }
    systemd-analyze() { cat "$journal_dropin"; }
    systemctl() {
        if [[ ${MOCK_EXTERNAL_EDIT:-0} == 1 ]]; then
            printf '# external edit\n' > "$journal_dropin"
            return 1
        fi
        if [[ ${MOCK_CONFIG_TERM:-0} == 1 && ! -e $test_dir/term.once ]]; then
            touch -- "$test_dir/term.once"
            kill -TERM "$BASHPID"
        fi
        return "${MOCK_RESTART_FAILURE:-0}"
    }
    printf '[Journal]\nSystemMaxUse=200M\n' > "$journal_dropin"
    output=$(run_logged_maintenance limit configure_journal_limit)
    contains "$output" 'History:'
    contains "$(cat "$journal_dropin")" 'SystemMaxUse=104857600'
    contains "$(cat "$test_dir/journald.conf.before")" 'SystemMaxUse=200M'
    contains "$(cat "$test_dir/history.log")" 'exit_status=0'
    printf '[Journal]\nSystemMaxUse=300M\n' > "$journal_dropin"
    if output=$(MOCK_RESTART_FAILURE=1 run_logged_maintenance limit configure_journal_limit); then
        fail 'accepted failed journald restart'
    fi
    contains "$(cat "$journal_dropin")" 'SystemMaxUse=300M'
    contains "$(cat "$test_dir/history.log")" 'exit_status=1'
    if output=$(MOCK_EXTERNAL_EDIT=1 run_logged_maintenance limit configure_journal_limit 2>&1); then
        fail 'accepted a concurrent journald edit'
    fi
    contains "$(cat "$journal_dropin")" '# external edit'
    contains "$output" 'changed externally'
    printf '[Journal]\nSystemMaxUse=300M\n' > "$journal_dropin"
    if output=$(MOCK_CONFIG_TERM=1 run_logged_maintenance limit configure_journal_limit 2>&1); then
        fail 'lost interrupted configuration status'
    fi
    contains "$(cat "$journal_dropin")" 'SystemMaxUse=300M'
    [[ $(tail -n 1 "$test_dir/history.log") == exit_status=143 ]]
    rm -- "$journal_dropin" "$test_dir/journald.conf.before"
    if output=$(MOCK_RESTART_FAILURE=1 run_logged_maintenance limit configure_journal_limit 2>&1); then
        fail 'accepted failed creation of a journald drop-in'
    fi
    [[ ! -e $journal_dropin ]]
    rsyslog_rule=$test_dir/rsyslog
    chown() { :; }
    logrotate() {
        if [[ ${MOCK_POLICY_FAILURE:-0} == 1 ]] && [[ $(cat "$rsyslog_rule") == *'maxsize 100M'* ]]; then
            return 1
        fi
    }
    original=$'/var/log/syslog\n/var/log/auth.log\n{\n    weekly\n    compress\n    delaycompress\n    postrotate\n        /usr/lib/rsyslog/rsyslog-rotate\n    endscript\n}'
    printf '%s\n' "$original" > "$rsyslog_rule"
    if output=$(MOCK_POLICY_FAILURE=1 run_logged_maintenance rsyslog-policy configure_rsyslog_rotation); then
        fail 'accepted failed logrotate validation'
    fi
    [[ $(cat "$rsyslog_rule") == "$original" ]]
    output=$(run_logged_maintenance rsyslog-policy configure_rsyslog_rotation)
    contains "$(cat "$rsyslog_rule")" $'daily\n    maxsize 100M'
    contains "$(cat "$rsyslog_rule")" '/usr/lib/rsyslog/rsyslog-rotate'
    [[ $(cat "$test_dir/rsyslog.conf.before") == "$original" ]]
    contains "$(run_logged_maintenance rsyslog-policy configure_rsyslog_rotation)" 'already configured'
    trusted_directory() { :; }
    fuser() { return 1; }
    log_archive_path_is_allowed() { [[ $1 == "$test_dir/example.gz" ]]; }
    stat() {
        if [[ $* == "-c %d -- $test_dir" ]]; then printf '999999\n'; else command stat "$@"; fi
    }
    mktemp() { mkdir -- "$test_dir/backup" && printf '%s\n' "$test_dir/backup"; }
    printf 'archive contents\n' > "$test_dir/example.gz"
    fingerprint=$(stat -c '%d:%i:%s:%y:%z' -- "$test_dir/example.gz")
    cmp() {
        if [[ ${MOCK_COPY_MISMATCH:-0} == 1 ]]; then return 1; fi
        command cmp "$@"
    }
    if output=$(MOCK_COPY_MISMATCH=1 run_logged_maintenance archive archive_log "$test_dir/example.gz" "$test_dir" "$fingerprint"); then
        fail 'deleted an archive without a verified copy'
    fi
    [[ -f $test_dir/example.gz ]]
    rm -- "$test_dir/backup/example.gz"
    rmdir -- "$test_dir/backup"
    output=$(run_logged_maintenance archive archive_log "$test_dir/example.gz" "$test_dir" "$fingerprint")
    contains "$output" 'Verified backup:'
    [[ ! -e $test_dir/example.gz ]]
    contains "$(cat "$test_dir/backup/example.gz")" 'archive contents'
    contains "$(cat "$test_dir/history.log")" 'backup_verified=yes'
    history_begin() { return 1; }
    if output=$(run_logged_maintenance test printf 'unexpected execution' 2>&1); then
        fail 'allowed action without history'
    fi
    omits "$output" 'unexpected execution'
)

if bash server-auditor.sh audit --format xml >/dev/null 2>&1; then fail 'accepted unknown format'; fi
if bash server-auditor.sh update --yes --extra >/dev/null 2>&1; then fail 'accepted extra update argument'; fi
if bash server-auditor.sh --lang fr >/dev/null 2>&1; then fail 'accepted unsupported language'; fi
if bash server-auditor.sh menu </dev/null >/dev/null 2>&1; then fail 'opened menu without a terminal'; fi
contains "$(bash server-auditor.sh --help)" 'Использование'
contains "$(bash server-auditor.sh --lang en --help)" 'Usage'
contains "$(bash server-auditor.sh --version)" 'Server Auditor v1.0'

# Stub each audit section to exercise report output without accessing host services.
os_id() { printf ubuntu; }
apt_check() { record apt WARN 'Значение в "кавычках" с обратной чертой \' 'A "quoted" value with a backslash \'; }
cleanup_check() { :; }
disk_check() {
    record disk CRIT 'Disk critical'
    overview_note '/ — всего 10 ГиБ' '/ — total 10 GiB'
}
docker_check() { record docker UNKNOWN 'No access'; }
kernel_check_definition=$(declare -f kernel_check)
for name in journal_check logrotate_check kernel_check memory_check systemd_check pve_check zfs_check; do
    unset -f "$name"
done
journal_check() { :; }
logrotate_check() { :; }
logrotate_timer_check() { :; }
large_logs_check() { :; }
kernel_check() { :; }
memory_check() { :; }
systemd_check() { :; }
pve_check() { :; }
zfs_check() { :; }
output=$(main)
contains "$output" 'Summary: checks=4 warnings=1 critical=1 unknown=1'
contains "$output" '=== System and memory ==='
contains "$output" '=== Large files in /var/log ==='
contains "$(main --lang ru)" 'Итог: проверок 4'
output=$(main --format json --details)
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys
r = json.load(sys.stdin)
assert r["version"] == "1.0"
assert r["summary"] == dict(checks=4, warnings=1, critical=1, unknown=1)
assert r["checks"][1]["message"] == "A \"quoted\" value with a backslash \\"' <<< "$output"
    python3 -c 'import json, sys
r = json.loads(sys.stdin.buffer.read())
assert r["checks"][1]["status"] == "WARN"
assert r["checks"][1]["message"].startswith("\u0417\u043d\u0430\u0447\u0435\u043d\u0438\u0435")
assert r["summary"]["warnings"] == 1' <<< "$(main --lang ru --format json)"
else
    contains "$output" '"summary":{"checks":4,"warnings":1,"critical":1,"unknown":1}'
fi
update() { printf 'test update %s\n' "$1"; }
sudo() {
    [[ ${*: -3} == 'update --lang en' ]] || fail 'unexpected sudo command'
    update 0
}
output=$(interactive_overview <<< '0')
contains "$output" '=== 4. Disks and filesystems ==='
contains "$output" 'Critical issue'
contains "$output" '/ — total 10 GiB'
omits "$output" 'Disk critical'
output=$(menu <<< $'bad\n1\n4\ns\n0\n2\n3\n4\n0\n0')
contains "$output" 'Choose an action from the list.'
contains "$output" '4. Rotate and vacuum journald archives to 100 MiB'
contains "$output" 'test update 0'
contains "$output" '=== Disks and filesystems ==='
contains "$output" '[CRIT   ] Disk critical'
[[ $(awk '/^=== 4\. Disks and filesystems ===$/ {n++} END {print n+0}' <<< "$output") == 2 ]]
[[ $(awk '/^Summary: checks=4 warnings=1 critical=1 unknown=1$/ {n++} END {print n+0}' <<< "$output") == 1 ]]
(
    test_dir=$(mktemp -d)
    trap 'rmdir -- "$test_dir/cache" "$test_dir/journal" "$test_dir"' EXIT
    mkdir -- "$test_dir/cache" "$test_dir/journal"
    df() { printf 'Use%% Avail Mounted on\n80%% 2147483648 /\n89%% 1096663040 /test disk\n'; }
    stat() {
        case $2:${*: -1} in
            %b:*) printf '1502928\n' ;;
            %d:*) printf '42\n' ;;
        esac
    }
    find() { :; }
    swapon() { printf '/swap.img\n/swapfile2\n'; }
    dpkg-query() { printf 'libllvm15:amd64: /usr/lib/libLLVM-15.so.1\n'; }
    largest_files() {
        [[ $1 == '/test disk' ]] || fail 'scanned the wrong mount'
        printf '%s\t%s\t%s\t%s\0' \
            1700000 99:12 1 /var/log/other-filesystem.gz \
            1502928 42:12 1 /var/log/syslog.1 \
            1502928 42:12 1 /var/log/duplicate.gz \
            700000 42:13 1 /var/log/syslog \
            500000 42:14 2 '/var/log/with space.gz' \
            400000 42:15 1 /var/lib/docker/container-data \
            300000 42:16 1 /swap.img \
            200000 42:17 1 /usr/lib/libLLVM-15.so.1 \
            100000 42:18 1 /var/lib/apt/lists/bookworm_Sources
        return "${MOCK_SCAN_STATUS:-0}"
    }
    du() { printf '1052672 /mock-journal\n'; }
    cleanup_check() {
        autoremove_known=1
        autoremove_estimate=1199174
        autoremove_candidates=(linux-image-6.1.0-29-amd64 unused-lib)
    }
    run_maintenance_action() { printf 'selected: %s\n' "$*"; }
    output=$(cleanup_plan "$test_dir/cache" "$test_dir/journal" <<< 0)
    contains "$output" 'Plan for /test disk: 89% used'
    contains "$output" '1. 733.85 MiB · /var/log/syslog.1 · archive, transfer or confirmed deletion available'
    contains "$output" '/var/log/syslog · looks like a current log'
    contains "$output" '/var/log/with\ space.gz · archive with hard links'
    contains "$output" '/var/lib/docker/container-data · Docker or containerd data'
    contains "$output" '/swap.img · active swap file, keep it'
    contains "$output" '/usr/lib/libLLVM-15.so.1 · file owned by libllvm15:amd64'
    contains "$output" '/var/lib/apt/lists/bookworm_Sources · APT index'
    contains "$(grep -F ' · /swap.img · ' <<< "$output")" '[KEEP]'
    contains "$(grep -F ' · /usr/lib/libLLVM-15.so.1 · ' <<< "$output")" '[KEEP]'
    contains "$(grep -F ' · /var/log/syslog.1 · ' <<< "$output")" '[REVIEW]'
    omits "$output" $'\033['
    omits "$output" 'other-filesystem.gz'
    omits "$output" 'duplicate.gz'
    contains "$output" 'APT cache: 0 KiB'
    contains "$output" 'Journald on this filesystem: 1.00 MiB'
    contains "$output" 'Automatic removal is blocked'
    omits "$output" '3. Vacuum'
    omits "$output" 'selected:'
    contains "$(cleanup_plan "$test_dir/cache" "$test_dir/journal" <<< 1)" 'selected: archive-options /var/log/syslog.1'
    contains "$(cleanup_plan "$test_dir/cache" "$test_dir/journal" <<< 2)" 'action is not available'
    contains "$(MOCK_SCAN_STATUS=1 cleanup_plan "$test_dir/cache" "$test_dir/journal" <<< 0)" 'list may be incomplete'
)
(
    eval "$kernel_check_definition"
    plan_state=$(mktemp)
    trap 'rm -f -- "$plan_state"' EXIT
    uname() { printf '6.1.0-49-amd64\n'; }
    dpkg-query() {
        printf 'installed linux-image-%s\n' 6.1.0-41-amd64 6.1.0-44-amd64 6.1.0-49-amd64 6.1.0-53-amd64 amd64
    }
    dpkg() { [[ $1 == --compare-versions && $2 > $4 ]]; }
    kernel_has_boot_files() {
        [[ ${MOCK_NO_FALLBACK:-0} == 0 && $1 == 6.1.0-53-amd64 ]] &&
            { [[ ${MOCK_FALLBACK_DISAPPEARS:-0} == 0 ]] || [[ ! -s $plan_state ]]; }
    }
    cleanup_check() {
        autoremove_known=1
        autoremove_candidates=(linux-image-6.1.0-41-amd64 linux-image-6.1.0-44-amd64 linux-image-6.1.0-49-amd64 linux-image-6.1.0-53-amd64)
    }
    cleanup_check
    output=$(kernel_check)
    contains "$output" '6.1.0-49-amd64 (running) — keep: running'
    contains "$output" '6.1.0-53-amd64 (inactive) — keep: newest and fallback'
    contains "$output" '6.1.0-44-amd64 (inactive) — removal candidate via menu 4 → 11'
    contains "$output" 'linux-image-6.1.0-53-amd64. Excluded from the removal menu.'
    output=$(MOCK_NO_FALLBACK=1 kernel_check)
    contains "$output" '6.1.0-44-amd64 (inactive) — keep: boot protection could not be verified'
    omits "$output" 'removal candidate via menu'
    apt-get() {
        if [[ $1 == -s ]]; then
            printf '0 upgraded, 0 newly installed, 1 to remove and 0 not upgraded.\nRemv %s [1]\n' "${*: -1}"
            if [[ ${MOCK_EXTRA_REMOVAL:-0} == 1 ]]; then printf 'Remv unrelated [1]\n'; fi
            if [[ ${MOCK_PLAN_CHANGE:-0} == 1 && -s $plan_state ]]; then printf 'Remv another-package [1]\n'; fi
            printf 'planned\n' > "$plan_state"
        else
            printf 'kernel action: %s\n' "$*"
        fi
    }
    run_logged_maintenance() { shift; "$@"; }
    output=$(choose_kernel_removal <<< $'2\nyes')
    contains "$output" 'running 6.1.0-49-amd64, newest 6.1.0-53-amd64, fallback 6.1.0-53-amd64'
    contains "$output" '1. linux-image-6.1.0-41-amd64'
    contains "$output" '2. linux-image-6.1.0-44-amd64'
    contains "$output" 'remove linux-image-6.1.0-44-amd64'
    omits "$output" 'remove linux-image-6.1.0-41-amd64'
    output=$(choose_kernel_removal <<< $'2\nn')
    contains "$output" 'Cancelled: linux-image-6.1.0-44-amd64 was kept.'
    omits "$output" 'kernel action:'
    output=$(choose_kernel_removal <<< 0)
    omits "$output" 'linux-image-6.1.0-49-amd64'
    omits "$output" 'linux-image-6.1.0-53-amd64'
    omits "$output" 'kernel action:'
    if output=$(choose_kernel_removal <<< 3 2>&1); then fail 'accepted out-of-range number'; fi
    if output=$(choose_kernel_removal <<< '1+1' 2>&1); then fail 'accepted arithmetic input'; fi
    if output=$(MOCK_NO_FALLBACK=1 choose_kernel_removal <<< '' 2>&1); then fail 'allowed removal without fallback'; fi
    if output=$(MOCK_EXTRA_REMOVAL=1 remove_selected_kernel linux-image-6.1.0-44-amd64 <<< yes 2>&1); then
        fail 'allowed unrelated package removal'
    fi
    omits "$output" 'kernel action:'
    : > "$plan_state"
    if output=$(MOCK_PLAN_CHANGE=1 remove_selected_kernel linux-image-6.1.0-44-amd64 <<< yes 2>&1); then
        fail 'removed packages after the APT plan changed'
    fi
    contains "$output" 'changed after confirmation'
    omits "$output" 'kernel action:'
    : > "$plan_state"
    if output=$(MOCK_FALLBACK_DISAPPEARS=1 remove_selected_kernel linux-image-6.1.0-44-amd64 <<< yes 2>&1); then
        fail 'removed an image after the fallback disappeared'
    fi
    omits "$output" 'kernel action:'
)
(
    if ! has python3; then exit 0; fi
    test_dir=$(mktemp -d)
    trap 'rm -f -- "$test_dir/docker-compose.yml" "$test_dir/server-auditor.logging.yml" "$test_dir/compose.before.yml" "$test_dir/restore.info" "$test_dir/history.log" "$test_dir/applied-marzban" "$test_dir/applied-angie"; rmdir -- "$test_dir"' EXIT
    original=$'# Keep this comment\nservices:\n  marzban:\n    image: marzban\n  angie:\n    image: angie'
    printf '%s\n' "$original" > "$test_dir/docker-compose.yml"
    printf '# Legacy override\n' > "$test_dir/server-auditor.logging.yml"
    trusted_directory() { [[ $1 == "$test_dir" ]]; }
    sync() { :; }
    chown() { :; }
    marzban_id=ee677dcf82f6$(printf '%052d' 0)
    angie_id=5d94bf64d168$(printf '%052d' 0)
    docker_local() {
        case $1:${*: -1} in
            container:*)
                [[ $* == *'ls -a --no-trunc'* ]] || fail 'did not list all Docker containers'
                printf '%s|marzban|running\n%s|angie|exited\n' "$marzban_id" "$angie_id" ;;
            "inspect:$marzban_id"|"inspect:$angie_id")
                local service=marzban
                if [[ ${*: -1} == "$angie_id" ]]; then service=angie; fi
                if [[ $* == *'{{.State.Status}}'* ]]; then
                    if [[ -f $test_dir/applied-$service && ${MOCK_VERIFY_FAILURE:-0} == 0 ]]; then
                        printf 'running|json-file|10m|3\n'
                    else
                        printf 'running|json-file||\n'
                    fi
                else
                    printf '%s|example|%s|%s/docker-compose.yml,%s/server-auditor.logging.yml|json-file\n' \
                        "$service" "$test_dir" "$test_dir" "$test_dir"
                fi ;;
            compose:marzban) printf '%s\n' "$marzban_id" ;;
            compose:angie) printf '%s\n' "$angie_id" ;;
            compose:--services) printf 'marzban\nangie\n' ;;
            compose:json)
                local file=$test_dir/docker-compose.yml logging= image=angie
                if [[ $* != *' -f '* ]]; then
                    if [[ ${MOCK_EXTERNAL_COMPOSE:-0} == 1 ]]; then
                        printf '# external configuration\n' > "$file"
                        return 1
                    fi
                    if [[ ${MOCK_BAD_DISCOVERY:-0} == 1 ]]; then return 1; fi
                fi
                while (( $# )); do
                    if [[ $1 == -f ]]; then file=$2; break; fi
                    shift
                done
                if grep -q 'logging:' "$file"; then
                    [[ ${MOCK_BAD_COMPOSE:-0} == 0 ]] || return 1
                    logging=',"logging":{"driver":"json-file","options":{"max-size":"10m","max-file":"3"}}'
                    if [[ ${MOCK_OTHER_CHANGE:-0} == 1 ]]; then image=wrong; fi
                fi
                printf '{"services":{"marzban":{"image":"marzban"%s},"angie":{"image":"%s"%s}}}\n' "$logging" "$image" "$logging" ;;
            *) fail "unexpected Docker call: $*" ;;
        esac
    }
    docker_local_write() {
        [[ $* == *'up -d --no-deps --no-build --pull never '* ]] || fail "unexpected Docker write: $*"
        touch -- "$test_dir/applied-${*: -1}"
    }
    run_logged_maintenance() {
        local operation_dir=$test_dir logfile=$test_dir/history.log
        shift
        "$@"
    }
    output=$(prepare_compose_logging <<< $'1 2\nn')
    contains "$output" '1. marzban (ee677dcf82f6) — running'
    contains "$output" '2. angie (5d94bf64d168) — exited'
    contains "$output" "'marzban':"
    contains "$output" "'angie':"
    [[ $(cat "$test_dir/docker-compose.yml") == "$original" ]]
    if output=$(prepare_compose_logging <<< '1 3' 2>&1); then fail 'accepted a number outside the container list'; fi
    contains "$output" 'Choose numbers from the list.'
    omits "$output" "'marzban':"
    if output=$(MOCK_BAD_COMPOSE=1 prepare_compose_logging <<< $'1 2\nyes'); then
        fail 'published invalid Compose configuration'
    fi
    [[ $(cat "$test_dir/docker-compose.yml") == "$original" ]]
    if output=$(MOCK_OTHER_CHANGE=1 prepare_compose_logging <<< $'1 2\nyes'); then
        fail 'accepted unrelated Compose change'
    fi
    [[ $(cat "$test_dir/docker-compose.yml") == "$original" ]]
    if output=$(MOCK_BAD_DISCOVERY=1 prepare_compose_logging <<< $'1 2\nyes'); then
        fail 'accepted failed implicit Compose discovery'
    fi
    [[ $(cat "$test_dir/docker-compose.yml") == "$original" ]]
    if output=$(MOCK_EXTERNAL_COMPOSE=1 prepare_compose_logging <<< $'1 2\nyes' 2>&1); then
        fail 'accepted an external Compose edit during validation'
    fi
    [[ $(cat "$test_dir/docker-compose.yml") == '# external configuration' ]]
    contains "$output" 'changed externally'
    printf '%s\n' "$original" > "$test_dir/docker-compose.yml"
    output=$(prepare_compose_logging <<< $'1 2\nyes')
    contains "$output" 'Apply the limits now?'
    [[ ! -e $test_dir/applied-marzban && ! -e $test_dir/applied-angie ]]
    contains "$(cat "$test_dir/docker-compose.yml")" 'max-size: "10m"'
    contains "$(cat "$test_dir/docker-compose.yml")" 'max-file: "3"'
    contains "$(cat "$test_dir/docker-compose.yml")" '# Keep this comment'
    [[ $(cat "$test_dir/compose.before.yml") == "$original" ]]
    [[ $(cat "$test_dir/server-auditor.logging.yml") == '# Legacy override' ]]
    if output=$(MOCK_VERIFY_FAILURE=1 prepare_compose_logging <<< $'1 2\nyes\nyes' 2>&1); then
        fail 'continued after Docker verification failed'
    fi
    contains "$output" 'running state or log limits could not be verified'
    [[ -e $test_dir/applied-marzban && ! -e $test_dir/applied-angie ]]
    output=$(prepare_compose_logging <<< $'1 2\nyes\nyes')
    contains "$output" 'marzban: the desired limits are already active.'
    contains "$output" 'angie: running, verified json-file, 10 MiB × 3.'
)
(
    has() { [[ $1 != pveversion ]]; }
    uname() { printf '6.8.0-149-generic\n'; }
    dpkg-query() { printf 'installed linux-image-6.8.0-149-generic\ninstalled linux-image-6.8.0-147-generic\n'; }
    dpkg() { [[ $1 == --compare-versions && $2 > $4 ]]; }
    kernel_has_boot_files() { [[ $1 == 6.8.0-147-generic ]]; }
    cleanup_check() {
        autoremove_known=1
        autoremove_candidates=(libslirp0 linux-headers-6.8.0-142 linux-modules-extra-6.8.0-142-generic
            linux-tools-6.8.0-147-generic linux-headers-6.8.0-149 linux-modules-6.8.0-149-generic)
    }
    run_logged_maintenance() { shift; "$@"; }
    apt-get() {
        if [[ $1 == -s ]]; then
            printf '0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.\n'
            printf 'Remv %s [1]\n' "${@: -2}"
            if [[ ${MOCK_EXTRA:-0} == 1 ]]; then printf 'Remv libslirp0 [1]\n'; fi
        else
            printf 'packages removed: %s\n' "${*: -2}"
        fi
    }
    output=$(choose_orphan_kernel_group <<< 0)
    contains "$output" '1. 6.8.0-142 — linux-headers-6.8.0-142 linux-modules-extra-6.8.0-142-generic'
    omits "$output" 'linux-tools-6.8.0-147'
    omits "$output" 'linux-headers-6.8.0-149'
    omits "$output" 'libslirp0'
    omits "$output" 'packages removed:'
    output=$(choose_orphan_kernel_group <<< $'1\nn')
    omits "$output" 'packages removed:'
    if output=$(MOCK_EXTRA=1 choose_orphan_kernel_group <<< $'1\nyes' 2>&1); then
        fail 'allowed unrelated package in group removal'
    fi
    omits "$output" 'packages removed:'
    output=$(choose_orphan_kernel_group <<< $'1\nyes')
    contains "$output" 'packages removed: linux-headers-6.8.0-142 linux-modules-extra-6.8.0-142-generic'
)
(
    test_dir=$(mktemp -d)
    maintenance_state=$test_dir
    newest=$test_dir/20261106T193956Z.newest
    older=$test_dir/20261106T193343Z.older
    trap 'rm -f -- "$newest/history.log" "$older/history.log"; rmdir -- "$newest" "$older" "$test_dir"' EXIT
    mkdir -- "$newest" "$older"
    printf 'action=orphan-kernel\nstarted=2026-11-06T19:39:56Z\nReading packages: 0%%\rReading packages: 50%%\rReading packages: Done\r\nRemoved six packages\nexit_status=0\n' > "$newest/history.log"
    printf 'action=kernel\nstarted=2026-11-06T19:33:43Z\nPrivate detail\n' > "$older/history.log"
    output=$(maintenance_action history <<< $'9\n1\n0')
    contains "$output" '1. 2026-11-06T19:39:56Z · orphan-kernel · exit code 0'
    contains "$output" '2. 2026-11-06T19:33:43Z · kernel · result not recorded yet'
    contains "$output" 'Choose a number from the list.'
    contains "$output" 'Removed six packages'
    contains "$output" 'Reading packages: Done'
    omits "$output" 'Reading packages: 50%'
    omits "$output" 'Private detail'
)
(
    test_dir=$(mktemp -d)
    trap 'rm -f -- "$test_dir/history.log" "$test_dir/state/maintenance.lock" "$test_dir/changed"; rmdir -- "$test_dir/state" "$test_dir/src" "$test_dir/dest" "$test_dir"' EXIT
    mkdir -- "$test_dir/state" "$test_dir/src" "$test_dir/dest"
    maintenance_state=$test_dir/state
    history_begin() { printf '%s\n' "$test_dir"; }
    flock() { :; }
    sync() { :; }
    stat() {
        if [[ ${*: -1} == "$test_dir/dest" ]]; then printf '99\n'
        elif [[ -e $test_dir/changed && ${MOCK_REMOUNT:-0} == 1 ]]; then printf '43\n'
        else printf '42\n'; fi
    }
    df() {
        local destination=0
        if [[ ${*: -1} == "$test_dir/dest" ]]; then destination=1; fi
        if [[ $* == *--output=target* ]]; then
            if (( destination )); then printf 'Mounted on\n/backup\n'; else printf 'Mounted on\n/data\n'; fi
        elif [[ ! -e $test_dir/changed ]]; then
            if (( destination )); then printf 'Avail\n2147483648\n'
            elif [[ ${MOCK_INITIAL_FAILURE:-0} == 1 ]]; then return 1
            else printf 'Avail\n1073741824\n'; fi
        elif (( destination )); then printf 'Avail\n1728053248\n'
        else printf 'Avail\n1493172224\n'; fi
    }
    simulated_action() { touch -- "$test_dir/changed"; return "${MOCK_ACTION_STATUS:-0}"; }
    output=$(run_logged_maintenance archive simulated_action "$test_dir/src/archive.gz" "$test_dir/dest")
    contains "$output" '/data — before 1.00 GiB, after 1.39 GiB, change +400.00 MiB'
    contains "$output" '/backup — before 2.00 GiB, after 1.61 GiB, change -400.00 MiB'
    omits "$output" 'space_change_bytes['
    contains "$(cat "$test_dir/history.log")" 'space_change_bytes[0]=419430400'
    contains "$(cat "$test_dir/history.log")" 'space_change_bytes[1]=-419430400'
    [[ $(grep -c '^space_path\[' "$test_dir/history.log") == 2 ]]
    [[ $(tail -n 1 "$test_dir/history.log") == exit_status=0 ]]
    rm -- "$test_dir/changed"
    if output=$(MOCK_ACTION_STATUS=7 run_logged_maintenance archive simulated_action "$test_dir/src/archive.gz" "$test_dir/dest"); then
        fail 'lost failed action status during space measurement'
    fi
    [[ $(tail -n 1 "$test_dir/history.log") == exit_status=7 ]]
    rm -- "$test_dir/changed"
    output=$(MOCK_INITIAL_FAILURE=1 run_logged_maintenance archive simulated_action "$test_dir/src/archive.gz" "$test_dir/dest")
    contains "$output" '/data — the initial measurement is unavailable.'
    contains "$(cat "$test_dir/history.log")" 'space_change_bytes[0]=unknown'
    rm -- "$test_dir/changed"
    output=$(MOCK_REMOUNT=1 run_logged_maintenance archive simulated_action "$test_dir/src/archive.gz" "$test_dir/dest")
    contains "$output" '/data — the final measurement is unavailable.'
    contains "$(cat "$test_dir/history.log")" 'space_change_bytes[0]=unknown'
    rm -- "$test_dir/changed"
    tee() { command cat >/dev/null; return 1; }
    if output=$(run_logged_maintenance archive simulated_action "$test_dir/src/archive.gz" "$test_dir/dest" 2>&1); then
        fail 'ignored a history recording failure'
    fi
    contains "$(cat "$test_dir/history.log")" 'recording_status=incomplete'
    [[ $(tail -n 1 "$test_dir/history.log") == exit_status=0 ]]
    rm -- "$test_dir/changed"
    flock() { return 1; }
    if output=$(run_logged_maintenance archive simulated_action "$test_dir/src/archive.gz" "$test_dir/dest" 2>&1); then
        fail 'ran a concurrent maintenance operation'
    fi
    [[ ! -e $test_dir/changed ]]
)
(
    test_dir=$(mktemp -d)
    maintenance_state=$test_dir/history
    first=$maintenance_state/20261107T120000Z.first
    restored=$maintenance_state/20261107T121000Z.restored
    created=$maintenance_state/20261107T130000Z.created
    mkdir -- "$maintenance_state" "$first" "$restored" "$created"
    trap 'for directory in "$first" "$restored" "$created"; do rm -f -- "$directory/history.log" "$directory/restore.info" "$directory/journald.conf.before" "$directory/restore.before"; rmdir -- "$directory"; done; rm -f -- "$test_dir/journald.conf" "$maintenance_state/maintenance.lock"; rmdir -- "$maintenance_state" "$test_dir"' EXIT
    journal_dropin=$test_dir/journald.conf
    active_operation=$first
    history_begin() { printf '%s\n' "$active_operation"; }
    trusted_directory() { [[ $1 == "$test_dir"* ]]; }
    sync() { :; }
    flock() { :; }
    df() {
        if [[ $* == *--output=target* ]]; then printf 'Mounted on\n/test\n'
        else printf 'Avail\n1073741824\n'; fi
    }
    systemd-analyze() { if [[ -f $journal_dropin ]]; then cat "$journal_dropin"; fi; }
    systemctl() { return "${MOCK_RESTART_FAILURE:-0}"; }
    printf '[Journal]\nStorage=persistent\n' > "$journal_dropin"
    output=$(run_logged_maintenance limit configure_journal_limit)
    [[ -f $first/restore.info ]]
    applied=$(cat "$journal_dropin")
    output=$(choose_config_restore <<< 0)
    contains "$output" '20261107T120000Z.first · journald'
    [[ $(cat "$journal_dropin") == "$applied" ]]
    original_backup=$(cat "$first/journald.conf.before")
    printf '# damaged backup\n' > "$first/journald.conf.before"
    output=$(choose_config_restore <<< 0)
    contains "$output" 'No eligible new entries.'
    [[ $(cat "$journal_dropin") == "$applied" ]]
    printf '%s\n' "$original_backup" > "$first/journald.conf.before"
    printf '# external edit\n' > "$journal_dropin"
    if output=$(choose_config_restore <<< $'1\nyes' 2>&1); then fail 'restored over an external config edit'; fi
    contains "$output" 'current file changed'
    [[ $(cat "$journal_dropin") == '# external edit' ]]
    printf '%s\n' "$applied" > "$journal_dropin"
    active_operation=$restored
    if output=$(MOCK_RESTART_FAILURE=1 choose_config_restore <<< $'1\nyes' 2>&1); then
        fail 'accepted failed validation after restoration'
    fi
    [[ $(cat "$journal_dropin") == "$applied" ]]
    output=$(choose_config_restore <<< $'1\nyes')
    contains "$output" 'Configuration restored:'
    contains "$(cat "$journal_dropin")" 'Storage=persistent'
    [[ $(tail -n 1 "$restored/history.log") == exit_status=0 ]]
    [[ $(cat "$restored/restore.before") == "$applied" ]]
    rm -- "$journal_dropin"
    active_operation=$created
    output=$(run_logged_maintenance limit configure_journal_limit)
    [[ ! -e $created/journald.conf.before ]]
    active_operation=$restored
    output=$(choose_config_restore <<< $'1\nyes')
    [[ ! -e $journal_dropin ]]
    contains "$output" 'Configuration restored:'
)
(
    test_dir=$(mktemp -d)
    source_file=$test_dir/syslog.1
    trap 'for directory in "$test_dir"/.server-auditor-delete.*; do if [[ -d $directory && ! -L $directory ]]; then rm -f -- "$directory/syslog.1"; rmdir -- "$directory"; fi; done; rm -f -- "$source_file" "$test_dir/hardlink" "$test_dir/history.log" "$test_dir/maintenance.lock"; rmdir -- "$test_dir"' EXIT
    maintenance_state=$test_dir
    history_begin() { printf '%s\n' "$test_dir"; }
    trusted_directory() { [[ $1 == "$test_dir" ]]; }
    log_archive_path_is_allowed() { [[ $1 == "$source_file" ]]; }
    flock() { :; }
    maintenance_space_paths() { printf '%s\0' "$test_dir"; }
    df() {
        if [[ $* == *--output=target* ]]; then printf 'Mounted on\n/test\n'
        else printf 'Avail\n1073741824\n'; fi
    }
    sync() {
        if [[ ${MOCK_INTENT_LOG_FAIL:-0} == 1 ]] && grep -q '^archive_delete_intent=yes' "$test_dir/history.log"; then return 1; fi
    }
    fuser() {
        if [[ ${MOCK_OPEN:-0} == 1 || ( ${MOCK_OPEN_STAGED:-0} == 1 && ${*: -1} == */.server-auditor-delete.*/* ) ]]; then
            printf '1234\n'
            return 0
        fi
        return 1
    }
    mv() {
        if [[ ${MOCK_REPLACE:-0} == 1 && ${@: -2:1} == "$source_file" ]]; then printf 'replacement archive\n' > "$source_file"; fi
        command mv "$@" || return
        if [[ ${MOCK_RECREATE_SOURCE:-0} == 1 && ${@: -2:1} == "$source_file" ]]; then printf 'new file at the original path\n' > "$source_file"; fi
    }
    printf 'original archive\n' > "$source_file"
    output=$(choose_archive_action "$source_file" <<< $'2\nn')
    contains "$output" 'permanently lost'
    [[ -f $source_file && ! -e $test_dir/history.log ]]
    if output=$(MOCK_OPEN=1 maintenance_action delete-archive "$source_file" <<< yes 2>&1); then
        fail 'deleted an open archive'
    fi
    [[ -f $source_file ]]
    ln -- "$source_file" "$test_dir/hardlink"
    if maintenance_action delete-archive "$source_file" <<< yes; then fail 'accepted a hard-linked archive'; fi
    rm -- "$test_dir/hardlink"
    fingerprint=$(stat -c '%d:%i:%s:%y:%z' -- "$source_file")
    printf 'changed before action\n' > "$source_file"
    if output=$(run_logged_maintenance delete-archive delete_log_archive "$source_file" "$fingerprint" 2>&1); then
        fail 'deleted an archive changed after preview'
    fi
    [[ -f $source_file ]]
    if output=$(MOCK_INTENT_LOG_FAIL=1 maintenance_action delete-archive "$source_file" <<< yes 2>&1); then
        fail 'deleted an archive without durable intent history'
    fi
    [[ -f $source_file ]]
    if output=$(MOCK_REPLACE=1 maintenance_action delete-archive "$source_file" <<< yes 2>&1); then
        fail 'deleted a substituted archive'
    fi
    [[ $(cat "$source_file") == 'replacement archive' ]]
    if output=$(MOCK_OPEN_STAGED=1 maintenance_action delete-archive "$source_file" <<< yes 2>&1); then
        fail 'deleted an archive opened during staging'
    fi
    [[ -f $source_file ]]
    if output=$(MOCK_OPEN_STAGED=1 MOCK_RECREATE_SOURCE=1 maintenance_action delete-archive "$source_file" <<< yes 2>&1); then
        fail 'overwrote a recreated source during recovery'
    fi
    [[ $(cat "$source_file") == 'new file at the original path' ]]
    contains "$output" 'File kept for manual recovery:'
    digest=$(file_sha256 "$source_file")
    output=$(maintenance_action delete-archive "$source_file" <<< yes)
    [[ ! -e $source_file ]]
    contains "$output" 'Archive deleted:'
    contains "$(cat "$test_dir/history.log")" "archive_sha256=$digest"
    contains "$(cat "$test_dir/history.log")" 'archive_deleted=yes'
    contains "$(cat "$test_dir/history.log")" 'backup=none'
    [[ $(tail -n 1 "$test_dir/history.log") == exit_status=0 ]]
)
if command -v python3 >/dev/null 2>&1; then
(
    image_id="sha256:$(printf 'a%.0s' {1..64})"
    container_id=$(printf 'b%.0s' {1..64})
    used=0 removed=0 multi=0 changed=0
    has() { [[ $1 == docker ]] || command -v "$1" >/dev/null 2>&1; }
    docker_local() {
        case "$1 $2" in
            'image ls') ((removed)) || printf '%s\n%s\n' "$image_id" "$image_id" ;;
            'container ls') ((used)) && printf '%s\n' "$container_id"; return 0 ;;
            'image inspect')
                local tags='["example:latest"]'
                ((multi)) && tags='["example:latest","example:backup"]'
                ((changed)) && tags='["example:changed"]'
                printf '["%s",1048576,%s,[]]\n' "$image_id" "$tags" ;;
            'container inspect') printf '["%s","/stopped-app","exited"]\n' "$image_id" ;;
            'system df') printf 'Build cache overview\n' ;;
            *) return 1 ;;
        esac
    }
    docker_local_write() {
        case "$1 $2" in
            'image rm') [[ $3 == --no-prune && $4 == "$image_id" && $# == 4 ]]; removed=1 ;;
            'builder prune') [[ $3 == --all && $4 == --filter && $5 == until=168h && $# == 5 ]] ;;
            *) return 1 ;;
        esac
    }
    sync() { return 0; }
    logfile=$(mktemp)
    trap 'rm -f -- "$logfile"' EXIT
    snapshot=$(docker_cleanup_inventory)
    [[ $(printf '%s\n' "$snapshot" | wc -l) == 1 ]]
    contains "$snapshot" $'\t1\t["example:latest"]\t[]'
    used=1
    contains "$(docker_cleanup_inventory)" 'stopped-app'
    if remove_docker_image "$snapshot"; then fail 'removed image used by stopped container'; fi
    used=0; multi=1
    contains "$(docker_cleanup_inventory)" $'\t0\t'
    if remove_docker_image "$snapshot"; then fail 'removed retagged image'; fi
    multi=0; changed=1
    if remove_docker_image "$snapshot"; then fail 'removed changed image'; fi
    changed=0
    remove_docker_image "$snapshot"
    [[ $removed == 1 ]]
    contains "$(cat "$logfile")" "image_id=$image_id"
    prune_docker_builder 168h
    if prune_docker_builder 0; then fail 'accepted unrestricted cache filter'; fi
    contains "$(cat "$logfile")" 'cache_filter=until=168h'
    # Cancelling either selection must not issue a write.
    removed=0
    docker_local_write() { fail 'write after menu cancellation'; }
    docker_cleanup_menu <<< $'1\n0\n0' >/dev/null
    docker_cleanup_menu <<< $'2\n0\n0' >/dev/null
)
fi
printf 'All tests passed.\n'
