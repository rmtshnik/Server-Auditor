#!/usr/bin/env bash
set -u
set -o pipefail
export LC_ALL=C

VERSION=1.0
format=txt
details=0
language=ru
checks=0
warnings=0
critical=0
unknown=0
autoremove_known=0
autoremove_candidates=()
autoremove_estimate=0
upgrade_options=(--no-remove -o APT::Get::AutomaticRemove=false --with-new-pkgs)
journal_limit=$((100 * 1024 * 1024))
rsyslog_size_mib=100
rsyslog_archive_count=4
rsyslog_custom=0
docker_log_mib=10
docker_log_files=3
maintenance_state=/var/lib/server-auditor
journal_dropin=/etc/systemd/journald.conf.d/90-server-auditor.conf
rsyslog_rule=/etc/logrotate.d/rsyslog
logrotate_config=/etc/logrotate.conf
logrotate_rules_directory=/etc/logrotate.d

usage() {
    printf '%s\n' "Server Auditor v$VERSION" "$(message 'Использование' 'Usage')" \
        '  bash server-auditor.sh [menu] [--lang ru|en]' \
        '  bash server-auditor.sh [audit] [--format txt|json] [--details] [--lang ru|en]' \
        '  sudo bash server-auditor.sh update [--yes] [--lang ru|en]' \
        '  bash server-auditor.sh --help | --version'
}

has() { command -v "$1" >/dev/null 2>&1; }

message() {
    if [[ $language == en ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

# Stable action IDs are shared by navigation and report hints.
declare -A menu_parent=() menu_number=() menu_ru=() menu_en=() menu_action=() menu_items=()
register_menu_item() {
    local id=$1 parent=$2
    menu_parent[$id]=$parent menu_number[$id]=$3 menu_ru[$id]=$4 menu_en[$id]=$5 menu_action[$id]=${6:-}
    menu_items[$parent]="${menu_items[$parent]:-} $id"
}
register_menu_item overview root 1 'Сводка с подробностями по разделам' 'Overview with section details' overview
register_menu_item update root 2 'Обновить пакеты' 'Update packages' update
register_menu_item full-audit root 3 'Подробный аудит системы' 'Detailed system audit' audit
register_menu_item maintenance root 4 'Обслуживание системы' 'System maintenance'
register_menu_item cleanup-plan maintenance 1 'План освобождения места' 'Disk space recovery plan' cleanup-plan
register_menu_item packages maintenance 2 'Пакеты APT и ядра' 'APT packages and kernels'
register_menu_item logs maintenance 3 'Журналы и ротация' 'Logs and rotation'
register_menu_item docker maintenance 4 'Docker' 'Docker'
register_menu_item history-menu maintenance 5 'История и восстановление' 'History and restoration'
register_menu_item clean packages 1 'Очистить кэш APT' 'Clear APT cache' clean
register_menu_item autoremove packages 2 'Проверить ненужные зависимости' 'Review unused dependencies' autoremove
register_menu_item kernel packages 3 'Удалить одно старое ядро' 'Remove one old kernel' kernel
register_menu_item orphan-kernel packages 4 'Очистить связанные пакеты удалённого ядра' 'Clean leftover kernel packages' orphan-kernel
register_menu_item journal logs 1 'Системный журнал journald' 'System journal (journald)'
register_menu_item regular-logs logs 2 'Обычные логи — logrotate' 'Regular logs — logrotate'
register_menu_item docker-logs logs 3 'Журналы Docker' 'Docker logs'
register_menu_item archives logs 4 'Архивы логов' 'Log archives'
register_menu_item log-history logs 5 'Общая история и восстановление' 'Shared history and restoration' @history-menu
register_menu_item journal-status journal 1 'Текущее состояние и объём' 'Current settings and usage' journal-status
register_menu_item limit journal 2 'Настроить постоянный лимит' 'Configure persistent size limit' limit
register_menu_item rotate journal 3 'Ротировать без очистки' 'Rotate without cleanup' rotate
register_menu_item vacuum journal 4 'Очистить старые записи до выбранного объёма' 'Vacuum old entries to selected size' vacuum
register_menu_item rotation-status regular-logs 1 'Текущие правила и ограничения' 'Current rules and size controls' rotation-status
register_menu_item logrotate-editor regular-logs 2 'Изменить выбранное правило' 'Edit selected rule' logrotate-editor
register_menu_item rsyslog-policy regular-logs 3 'Настроить профиль rsyslog' 'Configure rsyslog profile' rsyslog-policy
register_menu_item logrotate regular-logs 4 'Показать план и запустить ротацию' 'Preview and run rotation' logrotate
register_menu_item logrotate-guide regular-logs 5 'Инструкция для ручной настройки' 'Manual configuration guide' logrotate-guide
register_menu_item docker-log-status docker-logs 1 'Контейнеры, объём и ограничения логов' 'Containers, log usage and limits' docker-log-status
register_menu_item compose-logging docker-logs 2 'Настроить и применить лимиты Compose' 'Configure and apply Compose limits' compose-logging
register_menu_item archive-plan archives 1 'Найти архив: проверить, перенести или удалить' 'Find an archive: review, move or remove' cleanup-plan
register_menu_item archive archives 2 'Перенести архив по указанному пути' 'Move an archive by path' archive
register_menu_item docker-status docker 1 'Состояние контейнеров и использование места' 'Container status and disk usage' docker-log-status
register_menu_item docker-cleanup docker 2 'Очистить образы и кэш сборки' 'Clean images and build cache' docker-cleanup
register_menu_item docker-logging-link docker 3 'Настройка журналов Docker' 'Docker log settings' @docker-logs
register_menu_item docker-images docker-cleanup 1 'Проверить и удалить неиспользуемый образ' 'Review and remove an unused image'
register_menu_item docker-cache docker-cleanup 2 'Очистить кэш локального Docker Engine' 'Clean local Docker Engine build cache'
register_menu_item history history-menu 1 'История операций' 'Operation history' history
register_menu_item restore-config history-menu 2 'Восстановить конфигурацию' 'Restore a configuration' restore-config

menu_title() { message "${menu_ru[$1]}" "${menu_en[$1]}"; }
menu_path() {
    local id=$1 path='' depth=0
    while [[ $id != root ]]; do
        [[ -n ${menu_number[$id]:-} ]] && ((depth < 12)) || return 2
        path="${menu_number[$id]}${path:+ → $path}"
        id=${menu_parent[$id]}; ((depth+=1))
    done
    printf '%s' "$path"
}

colors_enabled() {
    [[ $format == txt && -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]
}

safety_line() {
    local level=$1 text=$2 label color
    case $level in
        keep) label=$(message 'НЕ УДАЛЯТЬ ВРУЧНУЮ' 'KEEP'); color=31 ;;
        clean) label=$(message 'МОЖНО ОЧИСТИТЬ' 'CLEANUP'); color=32 ;;
        *) label=$(message 'ТРЕБУЕТ ПРОВЕРКИ' 'REVIEW'); color=33 ;;
    esac
    if colors_enabled; then
        printf '\033[%sm[%s] %s\033[0m\n' "$color" "$label" "$text"
    else
        printf '[%s] %s\n' "$label" "$text"
    fi
}

report_heading() {
    if [[ ${overview_group:-0} != 0 ]]; then
        overview_titles[overview_group]=$(message "$1" "$2")
        overview_group=$((overview_group + 1))
    elif [[ $format == txt ]]; then
        printf '\n=== %s ===\n' "$(message "$1" "$2")"
    fi
}

overview_note() {
    if [[ ${overview_group:-0} != 0 ]]; then
        local section=$((overview_group - 1))
        overview_notes[section]+="$(message "$1" "$2")"$'\n'
    fi
}

json_string() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

# Callers supply static text, validated fields, or shell-quoted paths.
record() {
    local section=$1 status=$2 message=$3 hint=${5:-}
    if [[ $language == en ]]; then message=${4:-$3}; fi
    if [[ $language == en ]]; then hint=${6:-${5:-}}; fi
    if [[ $format == txt && -n $hint ]]; then message+=" · [$hint]"; fi
    case $status in
        WARN) ((warnings+=1)) ;;
        CRIT) ((critical+=1)) ;;
        UNKNOWN) ((unknown+=1)) ;;
    esac
    if [[ ${overview_group:-0} != 0 ]]; then
        local group=$((overview_group - 1)) line rank
        printf -v line '[%-7s] %s\n' "$status" "$message"
        overview_details[group]+=$line
        case $status in
            CRIT) rank=4 ;;
            WARN) rank=3 ;;
            UNKNOWN) rank=2 ;;
            SKIP) rank=0 ;;
            *) rank=1 ;;
        esac
        if (( rank > ${overview_ranks[group]:--1} )); then
            overview_ranks[group]=$rank
            overview_reasons[group]=$message
        fi
    elif [[ $format == json ]]; then
        if (( checks )); then printf ',\n'; fi
        printf '    {"section":'; json_string "$section"
        printf ',"status":'; json_string "$status"
        printf ',"message":'; json_string "$message"
        if [[ -n $hint ]]; then printf ',"hint":'; json_string "$hint"; fi
        printf '}'
    else
        printf '[%-7s] %s\n' "$status" "$message"
    fi
    ((checks+=1))
}

os_id() {
    local key value
    if [[ ! -r /etc/os-release ]]; then printf 'other'; return; fi
    while IFS='=' read -r key value; do
        [[ $key == ID ]] || continue
        value=${value%\"}
        value=${value#\"}
        case $value in debian|ubuntu|linuxmint) printf '%s' "$value"; return ;; esac
        break
    done < /etc/os-release
    printf 'other'
}

apt_check() {
    local result installed held upgraded kept
    if ! has apt-get || ! has dpkg; then
        record apt SKIP 'APT или dpkg недоступны' 'APT or dpkg unavailable'
        return
    fi
    if result=$(dpkg --audit 2>/dev/null); then
        if [[ -n $result ]]; then
            record apt CRIT 'dpkg обнаружил пакеты в неполном или несогласованном состоянии' 'dpkg reports incomplete or inconsistent package state'
        else
            record apt OK 'dpkg не обнаружил проблем' 'dpkg audit found no issues'
        fi
    else
        record apt UNKNOWN 'Проверка dpkg завершилась ошибкой' 'dpkg audit failed'
    fi
    if result=$(apt-mark -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= showhold 2>/dev/null); then
        held=$(awk 'NF {n++} END {print n+0}' <<< "$result")
        if (( held )); then record apt WARN "Удерживаемых пакетов: $held" "Held packages: $held"
        else record apt OK 'Удерживаемых пакетов: 0' 'Held packages: 0'; fi
    else
        record apt UNKNOWN 'Не удалось прочитать список удерживаемых пакетов' 'Could not read package holds'
    fi
    if ! compgen -G '/var/lib/apt/lists/*_Packages*' >/dev/null; then
        record apt UNKNOWN 'В стандартном каталоге APT не видны индексы пакетов' 'No package indexes visible in the default APT directory'
    fi
    if result=$(apt-get -s "${upgrade_options[@]}" \
        -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= upgrade 2>/dev/null) &&
        [[ $result =~ ([0-9]+)\ upgraded,\ ([0-9]+)\ newly\ installed,\ [0-9]+\ to\ remove\ and\ ([0-9]+)\ not\ upgraded ]]; then
        upgraded=${BASH_REMATCH[1]} installed=${BASH_REMATCH[2]} kept=${BASH_REMATCH[3]}
        overview_note "Обновлений: $upgraded · новых пакетов: $installed · отложено: $kept" \
            "Upgrades: $upgraded · new packages: $installed · kept back: $kept"
        if (( upgraded || installed || kept )); then
            record apt WARN "План по локальным индексам: обновить $upgraded, установить $installed, отложить $kept" "Cached upgrade plan: upgraded=$upgraded new=$installed kept=$kept" \
                "Обновление пакетов: главное меню → $(menu_path update)" "Update packages: main menu → $(menu_path update)"
        else
            record apt OK 'По локальным индексам обновлений нет' 'Cached upgrade plan: no upgrades'
        fi
    else
        record apt UNKNOWN 'Не удалось получить сводку пробного обновления APT' 'APT upgrade simulation failed or returned an unrecognized summary'
    fi
}

cleanup_check() {
    local result archives bytes package action count=0 expected kib total=0 unknown_sizes=0
    local -a candidates=()
    autoremove_known=0
    autoremove_candidates=()
    autoremove_estimate=0
    if ! has apt-get || ! has dpkg-query; then
        record cleanup SKIP 'APT или dpkg-query недоступны' 'APT or dpkg-query unavailable'
        return
    fi
    if result=$(find /var/cache/apt/archives -maxdepth 1 -type f -name '*.deb' \
        -printf '%b\n' 2>/dev/null | awk '{n++; b+=$1} END {printf "%d %.0f", n,b*512}') &&
        read -r archives bytes <<< "$result"; then
        record cleanup INFO "Стандартный кэш APT: файлов $archives, занято $(human_bytes "$bytes"). Команда apt-get clean очищает скачанные архивы" \
            "Default APT archive cache: files=$archives allocated_bytes=$bytes; apt-get clean clears downloaded archives" \
            "Очистить кэш: $(menu_path clean). Установленные пакеты сохранятся" "Clear cache: $(menu_path clean). Installed packages are kept"
    else
        record cleanup UNKNOWN 'Не удалось измерить стандартный кэш APT' 'Could not measure the default APT archive cache'
    fi
    if ! result=$(apt-get -s -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= \
        autoremove 2>/dev/null) ||
        ! [[ $result =~ ([0-9]+)\ upgraded,\ ([0-9]+)\ newly\ installed,\ ([0-9]+)\ to\ remove ]]; then
        record cleanup UNKNOWN 'Не удалось получить план apt-get autoremove' 'APT autoremove simulation failed or returned an unrecognized plan'
        return
    fi
    expected=${BASH_REMATCH[3]}
    if (( BASH_REMATCH[1] || BASH_REMATCH[2] )); then
        record cleanup UNKNOWN 'План apt-get autoremove включает другие изменения пакетов. Проверьте его вручную' 'APT autoremove simulation also changes installed packages; review it manually'
        return
    fi
    while read -r action package _; do
        [[ $action == Remv && $package =~ ^[a-z0-9][a-z0-9.+-]*(:[a-z0-9-]+)?$ ]] || continue
        candidates+=("$package")
        ((count+=1))
    done <<< "$result"
    if (( count != expected )); then
        record cleanup UNKNOWN 'Число операций удаления расходится со сводкой APT' 'APT removal actions do not match the simulation summary'
        return
    fi
    autoremove_known=1
    autoremove_candidates=("${candidates[@]}")
    for package in "${candidates[@]}"; do
        if kib=$(dpkg-query -W -f='${Installed-Size}' "$package" 2>/dev/null) &&
            [[ $kib =~ ^[0-9]{1,12}$ ]]; then
            total=$((total + 10#$kib))
        else
            kib=unknown
            ((unknown_sizes+=1))
        fi
        if (( details )); then
            local displayed_size
            if [[ $kib == unknown ]]; then displayed_size='неизвестен'; else displayed_size=$(human_kib "$kib"); fi
            record cleanup INFO "Кандидат на удаление: $package. Размер по dpkg: $displayed_size" "APT removal candidate: $package installed_KiB=$kib"
        fi
    done
    autoremove_estimate=$total
    local cleanup_hint_ru='Удалять зависимости не требуется' cleanup_hint_en='No dependency cleanup needed'
    if (( count )); then
        cleanup_hint_ru="Проверить удаление: $(menu_path autoremove). Для ядер: $(menu_path kernel), связанные пакеты: $(menu_path orphan-kernel)"
        cleanup_hint_en="Review removal: $(menu_path autoremove). Kernels: $(menu_path kernel), leftover packages: $(menu_path orphan-kernel)"
    fi
    record cleanup INFO "План apt-get autoremove: кандидатов $count, оценка $(human_kib "$total"), неизвестных размеров $unknown_sizes. Проверьте план перед удалением" "APT autoremove simulation: candidates=$count estimated_installed_KiB=$total unknown_sizes=$unknown_sizes; review before removal" "$cleanup_hint_ru" "$cleanup_hint_en"
    overview_note "Кандидатов на очистку APT: $count" "APT cleanup candidates: $count"
}

usage_status() {
    if (( $1 >= 95 )); then printf CRIT
    elif (( $1 >= 85 )); then printf WARN
    else printf OK; fi
}

disk_check() {
    local result blocks free inodes total used mount label status n=0
    local root_total root_used root_free
    if ! result=$(df -l -B1 -x tmpfs -x devtmpfs -x squashfs \
        --output=pcent,avail,ipcent,size,used,target 2>/dev/null); then
        record disk UNKNOWN 'df не смог прочитать все локальные файловые системы' 'df could not read all local filesystems'
    fi
    while read -r blocks free inodes total used mount; do
        [[ $blocks =~ ^([0-9]+)%$ && $free =~ ^-?[0-9]+$ && $total =~ ^[0-9]+$ ]] || continue
        blocks=${blocks%\%}
        ((n+=1))
        if [[ ${overview_group:-0} != 0 && $mount == / && $used =~ ^[0-9]+$ ]]; then
            root_total=$(human_kib "$((total / 1024))")
            root_used=$(human_kib "$((used / 1024))")
            root_free=$(human_kib "$((free / 1024))")
        fi
        label="$(message "Файловая система $n" "filesystem $n")"
        case $mount in
            /|/boot|/boot/efi|/var|/var/log|/var/lib/docker|/var/lib/vz|/home|/tmp)
                label+=" ($mount)" ;;
        esac
        if (( details )); then
            printf -v label "$(message 'Точка монтирования %q' 'mount %q')" "$mount"
        fi
        status=$(usage_status "$blocks")
        record disk "$status" "$label: занято $blocks%, доступно $(human_bytes "$free") из $(human_bytes "$total")" "$label: blocks_used=$blocks% available_bytes=$free total_bytes=$total" \
            "Проверить крупные файлы: $(menu_path cleanup-plan). Не каждый файл можно удалить" "Review large files: $(menu_path cleanup-plan). Not every file is removable"
        if [[ $inodes =~ ^([0-9]+)%$ ]]; then
            inodes=${inodes%\%}
            record disk "$(usage_status "$inodes")" "$label: занято $inodes% inode" "$label: inodes_used=$inodes%"
        else
            record disk SKIP "$label: Доля занятых inode недоступна" "$label: inode percentage unavailable"
        fi
    done <<< "$result"
    if (( n == 0 )); then record disk UNKNOWN 'Подходящих локальных файловых систем не найдено' 'No matching local filesystems'; fi
    if [[ -n ${root_total:-} ]]; then
        overview_note "/ — всего $root_total · занято $root_used · доступно $root_free" \
            "/ — total $root_total · used $root_used · available $root_free"
    fi
    if (( n )); then overview_note "Локальных файловых систем: $n" "Local filesystems: $n"; fi
}

size_bytes() {
    local value=${1^^}
    [[ $value =~ ^([0-9]{1,15})([KMGTPE]?)(I?B)?$ ]] || return 1
    numfmt --from=iec "${BASH_REMATCH[1]}${BASH_REMATCH[2]}" 2>/dev/null
}

journal_config() {
    local config=$1 key value bytes
    local -A settings=()
    while IFS='=' read -r key value; do
        settings[$key]=$value
    done < <(awk '
        /^[[:space:]]*\[/ {
            section=$0
            gsub(/[[:space:]]/, "", section)
        }
        section=="[Journal]" && /^[[:space:]]*(Storage|SystemMaxUse|RuntimeMaxUse|SystemKeepFree|RuntimeKeepFree|MaxRetentionSec)[[:space:]]*=/ {
            sub(/^[[:space:]]*/, "")
            sub(/[[:space:]]*=[[:space:]]*/, "=")
            sub(/[[:space:]]+$/, "")
            print
        }
    ' <<< "$config")
    value=${settings[Storage]:-auto}
    case $value in
        auto|persistent|volatile|none) record journald INFO "Настроено Storage=$value" "Configured Storage=$value" ;;
        *) record journald UNKNOWN 'Неизвестное значение Storage' 'Unrecognized Storage setting' ;;
    esac
    for key in SystemMaxUse RuntimeMaxUse; do
        value=${settings[$key]:-}
        if [[ -z $value ]]; then
            record journald WARN "Для $key действует значение systemd по умолчанию. Лимит 100 МиБ явно не задан" "$key uses the systemd default; 100 MiB cap is not explicit" \
                "Настроить лимит: $(menu_path limit)" "Configure limit: $(menu_path limit)"
        elif bytes=$(size_bytes "$value") && [[ $bytes =~ ^[0-9]{1,18}$ ]]; then
            if (( bytes > 0 && bytes <= journal_limit )); then
                record journald OK "$key=$(human_bytes "$bytes")" "$key=$bytes bytes" \
                    "Лимит настроен. Изменить: $(menu_path limit)" "Limit configured. Change: $(menu_path limit)"
            else
                record journald WARN "$key=$(human_bytes "$bytes"). Порог аудита: положительный лимит до 100 МиБ" "$key=$bytes bytes; expected a positive cap up to 100 MiB" \
                    "Настроить лимит: $(menu_path limit)" "Configure limit: $(menu_path limit)"
            fi
        else
            record journald UNKNOWN "Не удалось разобрать $key" "$key could not be interpreted"
        fi
    done
    for key in SystemKeepFree RuntimeKeepFree MaxRetentionSec; do
        value=${settings[$key]:-}
        if [[ $value =~ ^[0-9]+([a-zA-Z]+)?([[:space:]]+[0-9]+([a-zA-Z]+)?)*$ ]]; then
            printf -v value '%q' "$value"
            record journald INFO "Настроено $key=$value" "Configured $key=$value"
        fi
    done
}

journal_check() {
    local config directory result bytes
    if ! has journalctl; then record journald SKIP 'journalctl недоступен' 'journalctl unavailable'; return; fi
    if has systemd-analyze &&
        config=$(systemd-analyze --no-pager cat-config systemd/journald.conf 2>/dev/null); then
        journal_config "$config"
    else
        record journald UNKNOWN 'Не удалось прочитать основную конфигурацию journald и дополнения к ней' 'Could not resolve the main journald configuration and drop-ins'
    fi
    if (( EUID != 0 )); then
        record journald INFO 'Без прав root объём журналов может быть неполным' 'Journal usage may be partial without root privileges'
    fi
    for directory in /var/log/journal /run/log/journal; do
        if [[ ! -d $directory ]]; then
            record journald INFO "$directory: каталог отсутствует или недоступен" "$directory: directory absent or inaccessible"
        elif result=$(find "$directory" -type f \( -name '*.journal' -o -name '*.journal~' \) \
            -printf '%b\n' 2>/dev/null | awk '{n+=$1} END {printf "%.0f", n*512}') &&
            [[ $result =~ ^[0-9]{1,18}$ ]]; then
            bytes=$result
            if (( bytes > journal_limit )); then
                record journald WARN "$directory: занято $(human_bytes "$bytes"), выше 100 МиБ" "$directory: allocated_bytes=$bytes, above 100 MiB" \
                    "Очистить старые записи: $(menu_path vacuum). Они будут потеряны; настроить лимит: $(menu_path limit)" "Delete old entries: $(menu_path vacuum). Entries will be lost; configure limit: $(menu_path limit)"
            else
                record journald OK "$directory: занято $(human_bytes "$bytes")" "$directory: allocated_bytes=$bytes" \
                    'Срочная очистка не требуется' 'No urgent cleanup needed'
            fi
        else
            record journald UNKNOWN "$directory: не удалось измерить объём" "$directory: disk usage inaccessible"
        fi
    done
}

logrotate_rule_text() {
    local entry=$1 number
    if [[ $entry =~ [[:cntrl:]] ]]; then printf -v entry '%q' "$entry"; fi
    if [[ $language == ru ]]; then
        entry=${entry// monthly / ежемесячно }
        entry=${entry// weekly / еженедельно }
        entry=${entry// daily / ежедневно }
        entry=${entry// yearly / ежегодно }
        entry=${entry// hourly / ежечасно }
        while [[ $entry =~ after\ ([0-9]+)\ days ]]; do
            number=${BASH_REMATCH[1]}
            entry=${entry/"${BASH_REMATCH[0]}"/"период: $number сут."}
        done
        entry=${entry//rotations/архивов}
        entry=${entry//rotation)/архивов)}
        entry=${entry//(1 архивов)/(1 архив)}
        entry=${entry//(2 архивов)/(2 архива)}
        entry=${entry//(3 архивов)/(3 архива)}
        entry=${entry//(4 архивов)/(4 архива)}
        entry=${entry//empty log files are not rotated/пустые логи пропускаются}
        entry=${entry//empty log files are rotated/пустые логи ротируются}
        entry=${entry//only log files >=/только файлы размером от}
        entry=${entry//log files >=/файлы размером от}
        entry=${entry//are rotated earlier/ротируются раньше срока}
        entry=${entry//bytes are rotated/байт ротируются}
        entry=${entry//old logs are removed/старые архивы удаляются по правилу хранения}
        while [[ $entry =~ ([0-9]+)\ bytes ]]; do
            number=${BASH_REMATCH[1]}
            entry=${entry/"${BASH_REMATCH[0]}"/"$(human_bytes "$number")"}
        done
        while [[ $entry =~ ([0-9]+)\ байт ]]; do
            number=${BASH_REMATCH[1]}
            entry=${entry/"${BASH_REMATCH[0]}"/"$(human_bytes "$number")"}
            ((number >= 1024)) || break
        done
    fi
    printf '%s' "$entry"
}

logrotate_capacity_report() {
    local result=$1 kind header='' entry number=0 threshold=0 time_only=0 unrecognized=0
    local bytes retention status note bounded=0 title policy description hint_ru hint_en separator
    while IFS=$'\t' read -r kind entry; do
        if [[ $kind == rule ]]; then
            header=$entry
            ((number+=1))
            continue
        fi
        bytes=; retention=
        if [[ $header =~ \(([0-9]+)\ rotations?\) ]]; then retention=${BASH_REMATCH[1]}; fi
        # minsize ("only log files >=") is a lower bound, not a size cap.
        if [[ $entry =~ log\ files\ \>=\ ([0-9]+)\ are\ rotated\ earlier ]]; then
            bytes=${BASH_REMATCH[1]}
        elif [[ $header =~ (^|[[:space:]])([0-9]+)\ bytes && $header != *'after '* &&
            $header != *'daily'* && $header != *'weekly'* && $header != *'monthly'* &&
            $header != *'yearly'* && $entry != *'only log files >='* ]]; then
            bytes=${BASH_REMATCH[2]}
        fi
        if [[ -n $bytes ]]; then
            ((threshold+=1))
            if [[ -n $retention ]]; then ((bounded+=1)); fi
            note=$(message "Есть порог ротации $(human_bytes "$bytes"); это не жёсткий предел размера." \
                "Rotation threshold $(human_bytes "$bytes"); this is not a hard size cap.")
        elif [[ $header == *'after '* || $header == *'daily'* || $header == *'weekly'* ||
            $header == *'monthly'* || $header == *'yearly'* || $header == *'hourly'* ]]; then
            ((time_only+=1))
            note=$(message 'Порог максимального размера не обнаружен. Период и число архивов не ограничивают объём в байтах.' \
                'No maximum-size rotation threshold detected. Period and archive count do not cap bytes.')
        else
            ((unrecognized+=1))
            note=$(message 'Условия ограничения размера не распознаны; проверьте конфигурацию.' \
                'Size control conditions unrecognized; check the configuration.')
        fi
        if (( details )); then
            title=$(logrotate_rule_text "$header")
            policy=$(logrotate_rule_text "$entry")
            policy=${policy:-$(message 'не распознаны' 'not recognized')}
            hint_ru="Редактор стандартных блоков: $(menu_path logrotate-editor) (поддержка проверяется перед записью); инструкция: $(menu_path logrotate-guide); ротация: $(menu_path logrotate)"
            hint_en="Standard-block editor: $(menu_path logrotate-editor) (support checked before writing); guide: $(menu_path logrotate-guide); rotation: $(menu_path logrotate)"
            if [[ " $header " == *' /var/log/syslog '* && -f $rsyslog_rule && ! -L $rsyslog_rule ]] &&
                (rsyslog_custom=1; rsyslog_policy "$rsyslog_rule" >/dev/null); then
                hint_ru="Через скрипт: $(menu_path rsyslog-policy), размер и число архивов штатного rsyslog; проверить через $(menu_path logrotate)"
                hint_en="Via script: $(menu_path rsyslog-policy), size and archive count for standard rsyslog; validate via $(menu_path logrotate)"
            fi
            separator='; '
            if [[ $format == txt ]]; then separator=$'\n         '; fi
            description="$(message "Правило $number: $title" "Rule $number: $title")"
            description+="$separator$(message 'Условия: ' 'Conditions: ')$policy"
            description+="$separator$(message 'Размер: ' 'Size: ')$note"
            description+="$separator$(message 'Настройка: ' 'Configuration: ')$(message "$hint_ru" "$hint_en")"
            record logrotate INFO "$description" "$description"
        fi
    done < <(logrotate_rule_blocks "$result")
    status=INFO
    if (( time_only )); then status=WARN; fi
    record logrotate "$status" \
        "Ограничения объёма обычных логов: правил с порогом размера $threshold, из них с распознанным конечным числом архивов $bounded; без обнаруженного порога $time_only; нераспознанных $unrecognized." \
        "Regular log capacity: size_threshold_rules=$threshold finite_retention_rules=$bounded no_size_threshold_rules=$time_only unrecognized_rules=$unrecognized." \
        "План ротации: $(menu_path logrotate). Настройка rsyslog: $(menu_path rsyslog-policy); редактор других правил: $(menu_path logrotate-editor); инструкция: $(menu_path logrotate-guide)" \
        "Rotation plan: $(menu_path logrotate). Configure rsyslog: $(menu_path rsyslog-policy); other rules editor: $(menu_path logrotate-editor); guide: $(menu_path logrotate-guide)"
    record logrotate INFO \
        'Общий предел обычных логов не подтверждён. Logrotate не задаёт общий бюджет /var/log: файлы растут между запусками, шаблоны могут охватывать несколько файлов, а часть логов может не входить в правила. Сумма порогов не является общим лимитом.' \
        'A total regular-log cap is not established. Logrotate does not enforce a shared /var/log budget: files grow between runs, patterns may cover multiple files, and some logs may be unmanaged. Thresholds cannot be summed into a total cap.'
    overview_note "Правил без обнаруженного порога размера: $time_only; общий предел не подтверждён" \
        "Rules without a detected size threshold: $time_only; total cap not established"
}

logrotate_rule_blocks() {
    awk '
        function flush() { if (header != "") { print "rule\t" header; print "policy\t" policy }; header=""; policy="" }
        /^rotating pattern:/ { flush(); sub(/^rotating pattern: */, ""); header=$0; collecting=1; next }
        collecting && /^(empty log files|only log files|log files|old logs)/ {
            policy=policy (policy == "" ? "" : "; ") $0; next
        }
        collecting && /^[[:space:]]*($|considering log|Creating|switching|error:|warning:)/ { collecting=0; next }
        collecting && policy == "" { header=header " " $0 }
        END { flush() }
    ' <<< "$1"
}

logrotate_check() {
    local result rules entry kind rule_number=0
    if ! has logrotate; then
        record logrotate SKIP 'logrotate недоступен' 'logrotate unavailable'
    elif result=$(logrotate --debug --state /dev/null "$logrotate_config" 2>&1); then
        rules=$(awk '/^rotating pattern:/ {n++} END {print n+0}' <<< "$result")
        record logrotate OK "Пробный запуск прошёл. Правил ротации: $rules. Срок хранения зависит от правила" "Dry run succeeded: rotation_rules=$rules; each rule has its own retention policy"
        overview_note "Правил ротации: $rules" "Rotation rules: $rules"
        logrotate_capacity_report "$result"
    else
        record logrotate UNKNOWN 'Пробный запуск завершился ошибкой. Проверьте конфигурацию и права доступа' 'Dry run failed; check configuration and permissions locally'
    fi
}

syslog_sources() {
    tail -n 20000 -- "$1" |
        awk '
            /^[A-Z][a-z][a-z] +[0-9]+ [0-9]+:[0-9]+:[0-9]+ / { tag=$5 }
            /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { tag=$3 }
            {
                if (tag ~ /^[a-zA-Z0-9_.@-]+(\[[0-9]+\])?:$/) {
                    sub(/(\[[0-9]+\])?:$/, "", tag)
                    count[tag]++
                }
                tag=""
            }
            END { for (tag in count) print count[tag], tag }
        ' | sort -k1,1nr -k2,2 | awk 'NR <= 5'
}

large_logs_check() {
    local result files bytes large entry path shown=0 scan_ok=0 sample= tag count
    if result=$(find /var/log -xdev \( -path /var/log/journal -prune \) -o \
        -type f -printf '%s\n' 2>/dev/null |
        awk '{n++; b+=$1; if ($1>104857600) l++} END {printf "%d %.0f %d", n,b,l}') &&
        read -r files bytes large <<< "$result"; then
        local status=OK
        if (( large )); then status=WARN; fi
        record logrotate "$status" "/var/log: файлов $files, суммарный размер $(human_bytes "$bytes"), файлов свыше 100 МиБ: $large (без journal)" "/var/log: files=$files apparent_bytes=$bytes files_over_100MiB=$large (excluding journal)" \
            "Проверить файлы и архивы: $(menu_path cleanup-plan); ротация: $(menu_path logrotate)" "Review files and archives: $(menu_path cleanup-plan); rotation: $(menu_path logrotate)"
        overview_note "Файлов свыше 100 МиБ: $large из $files" "Files over 100 MiB: $large of $files"
    else
        record logrotate UNKNOWN 'Не удалось проверить все файлы в /var/log' 'Could not inventory all files under /var/log'
    fi
    if (( details )); then
        while IFS= read -r -d '' entry; do
            if [[ $entry == OK ]]; then scan_ok=1; continue; fi
            if (( shown >= 10 )); then continue; fi
            bytes=${entry%%$'\t'*}
            path=${entry#*$'\t'}
            case $path in
                /var/log/syslog)
                    sample=/var/log/syslog
                    record logrotate INFO 'Текущий syslog: проверьте источники записей и правило rsyslog в logrotate.' \
                        'Current syslog: check message sources and the rsyslog logrotate rule.' ;;
                /var/log/syslog.[0-9]*)
                    if [[ $path == /var/log/syslog.1 && -z $sample ]]; then sample=$path; fi
                    record logrotate INFO 'Архив syslog: переносите только после проверки открытых дескрипторов.' \
                        'Rotated syslog: check for open file descriptors before moving it.' ;;
            esac
            printf -v path '%q' "$path"
            record logrotate WARN "Крупный лог: $(human_bytes "$bytes"), путь $path" "Large log: apparent_bytes=$bytes path=$path" \
                "Текущий лог: ротация $(menu_path logrotate). Поддерживаемый архив: проверка и удаление $(menu_path cleanup-plan)" \
                "Active log: rotate via $(menu_path logrotate). Supported archive: review and remove via $(menu_path cleanup-plan)"
            ((shown+=1))
        done < <(
            if find /var/log -xdev \( -path /var/log/journal -prune \) -o \
                -type f -size +104857600c -printf '%s\t%p\0' 2>/dev/null | sort -z -nr; then
                printf 'OK\0'
            fi
        )
        if (( ! scan_ok )); then record logrotate UNKNOWN 'Список крупных логов может быть неполным' 'Large log list may be incomplete'; fi
        if [[ -n $sample ]] && result=$(syslog_sources "$sample" 2>/dev/null); then
            while read -r count tag; do
                [[ -n $tag ]] || continue
                record logrotate INFO "Выборка $sample (до 20 000 строк): $tag — $count записей" \
                    "$sample sample (up to 20,000 lines): $tag — $count entries"
            done <<< "$result"
        fi
    fi
}

docker_local() (
    unset DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
    timeout 20 docker --host unix:///var/run/docker.sock "$@"
)

docker_local_write() (
    unset DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
    docker --host unix:///var/run/docker.sock "$@"
)

docker_json_log_usage() {
    local id=$1 ru=$2 en=$3 log_path directory full_id file suffix metadata blocks size
    local total_blocks=0 apparent=0 files=0 status=INFO amount
    log_path=$(docker_local inspect --type container --format '{{.LogPath}}' "$id" 2>/dev/null) || return 1
    directory=${log_path%/*}
    full_id=${directory##*/}
    [[ $log_path == /* && $full_id =~ ^[a-f0-9]{64}$ && $full_id == "$id"* &&
        ${log_path##*/} == "$full_id-json.log" && -r $directory && -x $directory && ! -L $directory &&
        -f $log_path && ! -L $log_path ]] || return 1
    for file in "$log_path" "$log_path".*; do
        if [[ $file != "$log_path" ]]; then
            suffix=${file#"$log_path".}
            [[ $suffix =~ ^[0-9]+(\.gz)?$ ]] || continue
        fi
        [[ ! -L $file ]] || return 1
        [[ -f $file ]] || continue
        metadata=$(stat -c '%b %s' -- "$file" 2>/dev/null) || return 1
        read -r blocks size <<< "$metadata"
        [[ $blocks =~ ^[0-9]+$ && $size =~ ^[0-9]+$ ]] || return 1
        total_blocks=$((total_blocks + blocks))
        apparent=$((apparent + size))
        files=$((files + 1))
    done
    (( files )) || return 1
    if (( total_blocks * 512 > journal_limit )); then status=WARN; fi
    if [[ $format == json ]]; then
        record docker "$status" "$ru: json-file, файлов $files, занято $((total_blocks * 512)) байт, размер $apparent байт" \
            "$en: json-file files=$files allocated_bytes=$((total_blocks * 512)) apparent_bytes=$apparent"
    else
        amount=$(human_kib "$((total_blocks / 2))")
        record docker "$status" "$ru: логи json-file занимают $amount, файлов: $files" \
            "$en: json-file logs use $amount, files: $files"
    fi
}

container_logging() {
    local id=$1 ru=$2 en=$3 options driver max_size max_file
    if ! options=$(docker_local inspect --type container --format \
        '{{with .HostConfig.LogConfig}}{{.Type}}|{{index .Config "max-size"}}|{{index .Config "max-file"}}{{end}}' "$id" 2>/dev/null); then
        record docker UNKNOWN "$ru: настройки логирования недоступны" "$en: log configuration unavailable"
        return
    fi
    IFS='|' read -r driver max_size max_file <<< "$options"
    case $driver in
        local|json-file)
            if [[ $driver == local ]]; then
                max_size=${max_size:-20m}
                max_file=${max_file:-5}
            else
                max_file=${max_file:-1}
            fi
            if [[ $max_file =~ ^[1-9][0-9]{0,8}$ ]] &&
                max_size=$(size_bytes "$max_size") && [[ $max_size =~ ^[1-9][0-9]*$ ]]; then
                record docker OK "$ru: ротация $driver, до $max_size байт на файл, файлов до $max_file" "$en: $driver rotation, max_size_bytes=$max_size max_files=$max_file"
            else
                record docker WARN "$ru: для $driver не удалось подтвердить лимиты размера и числа файлов" "$en: $driver has no verified size and file count limits" \
                    "Для Compose с json-file: $(menu_path compose-logging); другие случаи — вручную" "Compose with json-file: $(menu_path compose-logging); other cases require manual configuration"
            fi ;;
        journald) record docker INFO "$ru: драйвер journald. См. раздел journald" "$en: journald driver; see journald checks" ;;
        none) record docker INFO "$ru: логирование отключено" "$en: logging disabled" ;;
        *) record docker UNKNOWN "$ru: ротация зависит от драйвера или внешней системы" "$en: rotation depends on another driver or backend" ;;
    esac
    if (( details )) && [[ $driver == json-file ]] && ! docker_json_log_usage "$id" "$ru" "$en"; then
        record docker UNKNOWN "$ru: не удалось измерить место под логи json-file" \
            "$en: json-file log disk usage unavailable"
    fi
}

container_paths() {
    local id=$1 label=$2 result field path compose_dir=0
    if ! result=$(docker_local inspect --type container --format \
        '{{with index .Config.Labels "com.docker.compose.project.working_dir"}}{{printf "project\t%q\n" .}}{{end}}{{with index .Config.Labels "com.docker.compose.project.config_files"}}{{printf "files\t%q\n" .}}{{end}}{{range .Mounts}}{{if eq .Type "bind"}}{{printf "bind\t%q → %q\n" .Source .Destination}}{{end}}{{end}}' "$id" 2>/dev/null); then
        record docker UNKNOWN "Контейнер $label: сведения о путях недоступны" "Container $label: path information unavailable"
        return
    fi
    while IFS=$'\t' read -r field path; do
        case $field in
            project)
                compose_dir=1
                record docker INFO "Контейнер $label: каталог проекта Compose $path" "Container $label: Compose project directory $path" ;;
            files)
                record docker INFO "Контейнер $label: файлы конфигурации Compose $path" "Container $label: Compose configuration files $path" ;;
            bind)
                record docker INFO "Контейнер $label: путь на хосте $path" "Container $label: bind mount $path" ;;
        esac
    done <<< "$result"
    if (( ! compose_dir )); then
        record docker INFO "Контейнер $label: каталог проекта Compose не записан в метках" \
            "Container $label: Compose project directory is not recorded in labels"
    fi
}

docker_check() {
    local result type type_ru count active size reclaim id state state_ru name label rows=0
    local containers=0 running=0
    if ! has docker; then record docker SKIP 'Команда docker недоступна' 'Docker CLI unavailable'; return; fi
    if ! result=$(docker_local container ls -a --format '{{.ID}}|{{.State}}|{{.Names}}' 2>/dev/null); then
        record docker UNKNOWN 'Локальный сокет Docker недоступен или нет прав доступа' 'Local Docker socket unavailable or access denied'
        return
    fi
    if [[ -z $result ]]; then record docker INFO 'Контейнеров нет' 'No containers'; fi
    while IFS='|' read -r id state name; do
        [[ $id =~ ^[a-f0-9]{12,64}$ ]] || continue
        ((containers+=1))
        case $state in
            created) state_ru=создан ;;
            running) state_ru=запущен; ((running+=1)) ;;
            paused) state_ru=приостановлен ;;
            restarting) state_ru=перезапускается ;;
            removing) state_ru=удаляется ;;
            exited) state_ru=остановлен ;;
            dead) state_ru=неработоспособен ;;
            *) state=unknown; state_ru='состояние неизвестно' ;;
        esac
        label=$id
        if [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
            label="$name ($id)"
        fi
        if [[ $format == txt ]] && (( ! details )); then
            container_logging "$id" "Контейнер $label — $state_ru" "Container $label — $state"
        else
            record docker INFO "Контейнер $label: $state_ru" "Container $label: state=$state"
            container_logging "$id" "Контейнер $label" "Container $label"
        fi
        if (( details )); then container_paths "$id" "$label"; fi
    done <<< "$result"
    overview_note "Контейнеров: $containers · запущено: $running" \
        "Containers: $containers · running: $running"
    if result=$(docker_local image ls -q --filter dangling=true 2>/dev/null); then
        count=$(awk '/^[a-f0-9]+$/ && !seen[$0]++ {n++} END {print n+0}' <<< "$result")
        if (( count )); then record docker WARN "Образы без тегов: $count" "Dangling images: $count" \
            "Проверить перед удалением: $(menu_path docker-images)" "Review before removal: $(menu_path docker-images)"
        else record docker OK 'Образы без тегов: 0' 'Dangling images: 0'; fi
    else
        record docker UNKNOWN 'Не удалось посчитать образы без тегов' 'Could not count dangling images'
    fi
    if result=$(docker_local system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null); then
        while IFS='|' read -r type count active size reclaim; do
            case $type in
                Images) type_ru=Образы ;;
                Containers) type_ru=Контейнеры ;;
                'Local Volumes') type_ru='Локальные тома' ;;
                'Build Cache') type_ru='Кэш сборки' ;;
                *) continue ;;
            esac
            [[ $count =~ ^[0-9]+$ && $active =~ ^[0-9]+$ &&
                $size =~ ^[0-9]+([.][0-9]+)?[[:space:]]?[kKMGTPE]?B$ ]] || continue
            if ! [[ $reclaim =~ ^[0-9]+([.][0-9]+)?[[:space:]]?[kKMGTPE]?B([[:space:]]\([0-9]+%\))?$ ]]; then
                reclaim=$(message 'неизвестно' 'unknown')
            fi
            local hint_ru='' hint_en=''
            case $type in
                Images) hint_ru="Проверить образы: $(menu_path docker-images)"; hint_en="Review images: $(menu_path docker-images)" ;;
                'Build Cache') hint_ru="Очистить кэш встроенного builder: $(menu_path docker-cache)"; hint_en="Clean built-in builder cache: $(menu_path docker-cache)" ;;
                *) hint_ru='Автоматическое удаление скриптом не предусмотрено'; hint_en='Automatic removal is not provided' ;;
            esac
            record docker INFO "$type_ru: объектов $count, активных $active, объём $size, оценка освобождаемого места $reclaim" "$type: records=$count active=$active size=$size reclaimable=$reclaim" "$hint_ru" "$hint_en"
            ((rows+=1))
        done <<< "$result"
    fi
    if (( rows < 4 )); then record docker UNKNOWN 'Сводка Docker по диску недоступна или неполна' 'Docker disk usage summary unavailable or incomplete'; fi
}

kernel_check() {
    local running result status package release role count=0 found=0 inactive=0 removable=0 candidate
    local running_kernel newest_kernel fallback_kernel retention_ready=0 decision decision_ru decision_en eligible=0
    local -A removal_plan=() installed_images=()
    for candidate in "${autoremove_candidates[@]}"; do
        removal_plan[${candidate%%:*}]=1
    done
    local kernel_pattern='^[0-9]+\.[0-9]+\.[0-9]+([.+~0-9-]*)(\+deb[0-9]+)?(-(amd64|arm64|armmp|cloud-amd64|cloud-arm64|686|686-pae|rt-amd64|generic|generic-64k|lowlatency|pve|aws|azure|gcp|gke|oracle|kvm|raspi|virtual|oem|rt|liquorix-amd64))?[+]?$'
    running=$(uname -r 2>/dev/null)
    if [[ $running =~ $kernel_pattern ]]; then
        record kernel INFO "Запущенное ядро: $running" "Running kernel: $running"
        overview_note "Запущено: $running" "Running: $running"
    else
        record kernel UNKNOWN 'Версия запущенного ядра недоступна или содержит нестандартный суффикс' 'Running kernel release unavailable or redacted (custom suffix)'
    fi
    if ! result=$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' \
        'linux-image-*' 'pve-kernel-*' 'proxmox-kernel-*' 2>/dev/null) && [[ -z $result ]]; then
        record kernel UNKNOWN 'Не удалось получить список установленных версий ядра' 'Could not list installed versioned kernel packages'
        return
    fi
    if kernel_removal_inventory "$result" "$running"; then retention_ready=1; fi
    while read -r status package; do
        [[ $status == installed && $package =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || continue
        case $package in
            linux-image-unsigned-*) release=${package#linux-image-unsigned-} ;;
            linux-image-*) release=${package#linux-image-} ;;
            pve-kernel-*) release=${package#pve-kernel-} ;;
            proxmox-kernel-*) release=${package#proxmox-kernel-} ;;
            *) continue ;;
        esac
        release=${release%-signed}
        [[ $release =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9]|\+deb[0-9]) ]] || continue
        decision=unsupported
        ((count+=1))
        role=$(message 'неактивно' 'inactive')
        if [[ -z $running ]]; then
            role=$(message 'состояние неизвестно' 'state unknown')
        elif [[ $release == "$running" ]]; then
            found=1
            role=$(message 'запущено' 'running')
        else
            ((inactive+=1))
        fi
        if [[ $release =~ $kernel_pattern ]]; then
            decision=$(kernel_retention_reason "$package" "$release" "$retention_ready")
            case $decision in
                running) decision_ru='оставить: запущено'; decision_en='keep: running' ;;
                fallback-newest) decision_ru='оставить: самое новое и запасное'; decision_en='keep: newest and fallback' ;;
                fallback) decision_ru='оставить: запасное'; decision_en='keep: fallback' ;;
                newest) decision_ru='оставить: самое новое'; decision_en='keep: newest' ;;
                unverified) decision_ru='оставить: защита загрузки не подтверждена'; decision_en='keep: boot protection could not be verified' ;;
                unsupported) decision_ru='оставить: меню не обслуживает этот тип пакета'; decision_en='keep: package type is outside the removal menu scope' ;;
                *)
                    if (( ! autoremove_known )); then
                        decision_ru='оставить: план APT недоступен'; decision_en='keep: APT plan unavailable'
                    elif [[ ${removal_plan[$package]:-} == 1 ]]; then
                        decision_ru="кандидат на удаление через меню $(menu_path kernel)"
                        decision_en="removal candidate via menu $(menu_path kernel)"
                        ((eligible+=1))
                    else
                        decision_ru='оставить: APT не предлагает удаление'; decision_en='keep: not proposed for removal by APT'
                    fi ;;
            esac
            record kernel INFO "Установленное ядро: $release ($role) — $decision_ru" \
                "Installed kernel release: $release ($role) — $decision_en"
        else
            record kernel INFO 'Установленное ядро с нестандартным суффиксом' 'Installed kernel release redacted (custom suffix)'
        fi
        if [[ ${removal_plan[$package]:-} == 1 ]]; then
            if [[ -z $running || $release == "$running" ]]; then
                record kernel CRIT 'APT предлагает удалить запущенное ядро или его не удалось определить. Проверьте план вручную' \
                    'APT proposes removing the running kernel or its release is unknown. Review the plan manually'
            else
                ((removable+=1))
                if [[ $decision == eligible ]]; then
                    record kernel WARN "APT предлагает удалить пакет ядра: $package" "APT removal candidate for kernel image: $package"
                else
                    record kernel WARN "APT предлагает удалить пакет ядра: $package. Меню его не предлагает." \
                        "APT removal candidate for kernel image: $package. Excluded from the removal menu."
                fi
            fi
        fi
    done <<< "$result"
    record kernel INFO "Пакетов ядра с указанием версии: $count" "Versioned kernel packages: $count"
    if [[ -z $running ]]; then
        record kernel UNKNOWN 'Число неактивных ядер неизвестно: не удалось определить запущенную версию' \
            'Inactive kernel count is unknown because the running release could not be determined'
    elif (( autoremove_known )); then
        record kernel INFO "Неактивных пакетов ядер: $inactive. Из них в плане удаления APT: $removable" \
            "Inactive kernel packages: $inactive. Among these, in the APT removal plan: $removable"
        overview_note "Установлено: $count · кандидатов для меню удаления: $eligible" \
            "Installed: $count · candidates eligible for the removal menu: $eligible"
    else
        record kernel UNKNOWN "Неактивных пакетов ядер: $inactive. План удаления APT недоступен" \
            "Inactive kernel packages: $inactive. APT removal plan unavailable"
        overview_note "Установлено: $count · неактивных: $inactive · план APT недоступен" \
            "Installed: $count · inactive: $inactive · APT removal plan unavailable"
    fi
    if (( inactive )); then
        record kernel INFO 'Неактивные ядра могут служить запасными. Сверьтесь с планом APT и сохраните рабочее запасное ядро' 'Inactive kernels may be boot fallbacks; review the APT plan and retain a known-good fallback'
    fi
    if [[ -n $running ]] && (( ! found )); then
        record kernel INFO 'Для запущенного ядра нет соответствующего пакета. Такое бывает внутри контейнера' 'Running release has no matching installed package; common inside containers'
    fi
    if [[ -f /run/reboot-required ]]; then
        record kernel WARN 'Система сообщает, что требуется перезагрузка' 'The system signals that a reboot is required'
    fi
}

human_kib() {
    local kib=$1 unit=1 suffix sign=
    if (( kib < 0 )); then sign=-; kib=$((-kib)); fi
    if (( kib >= 1073741824 )); then
        unit=1073741824
        suffix=$(message ТиБ TiB)
    elif (( kib >= 1048576 )); then
        unit=1048576
        suffix=$(message ГиБ GiB)
    elif (( kib >= 1024 )); then
        unit=1024
        suffix=$(message МиБ MiB)
    else
        printf '%s%d %s' "$sign" "$kib" "$(message КиБ KiB)"
        return
    fi
    local fraction=$(( (kib % unit * 100 + unit / 2) / unit ))
    printf '%s%d%s%02d %s' "$sign" "$((kib / unit + fraction / 100))" "$(message , .)" "$((fraction % 100))" "$suffix"
}

memory_usage() {
    local total=$1 free=$2 ru=$3 en=$4 free_ru=$5 free_en=$6
    local used=$((total - free)) permille status used_size total_size free_size percent
    permille=$((used * 1000 / total))
    status=$(usage_status "$((permille / 10))")
    if [[ $format == json ]]; then
        record memory "$status" "$7" "$8"
        return
    fi
    used_size=$(human_kib "$used")
    total_size=$(human_kib "$total")
    free_size=$(human_kib "$free")
    printf -v percent '%d%s%d%%' "$((permille / 10))" "$(message , .)" "$((permille % 10))"
    record memory "$status" "$ru: занято $used_size из $total_size ($percent), $free_ru $free_size" \
        "$en: $used_size used of $total_size ($percent), $free_size $free_en"
    overview_note "$ru: $used_size из $total_size ($percent)" "$en: $used_size of $total_size ($percent)"
}

memory_check() {
    local total available swap_total swap_free
    if ! read -r total available swap_total swap_free < <(awk '
        /^MemTotal:/ {m=$2} /^MemAvailable:/ {a=$2}
        /^SwapTotal:/ {s=$2} /^SwapFree:/ {f=$2}
        END {print m, a, s, f}
    ' /proc/meminfo 2>/dev/null) ||
        ! [[ $total =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ &&
            $swap_total =~ ^[0-9]+$ && $swap_free =~ ^[0-9]+$ ]] ||
        (( available > total || swap_free > swap_total )); then
        record memory UNKNOWN 'Статистика памяти недоступна' 'Memory statistics unavailable'
        return
    fi
    memory_usage "$total" "$available" ОЗУ RAM доступно available \
        "ОЗУ: всего $total КиБ, доступно $available КиБ" "RAM: total_KiB=$total available_KiB=$available"
    if (( swap_total )); then
        memory_usage "$swap_total" "$swap_free" Подкачка Swap свободно free \
            "Подкачка: всего $swap_total КиБ, свободно $swap_free КиБ" "Swap: total_KiB=$swap_total free_KiB=$swap_free"
    else
        record memory INFO 'Подкачка отключена' 'Swap is disabled'
    fi
}

systemd_check() {
    local result count
    if ! has systemctl; then record systemd SKIP 'systemctl недоступен' 'systemctl unavailable'; return; fi
    if result=$(systemctl --system --failed --no-pager --no-legend --plain 2>/dev/null); then
        count=$(awk 'NF {n++} END {print n+0}' <<< "$result")
        if (( count )); then record systemd WARN "Сбойных юнитов: $count. Список покажет systemctl --failed" "Failed units: $count; inspect locally with systemctl --failed"
        else record systemd OK 'Сбойных юнитов: 0' 'Failed units: 0'; fi
    else
        record systemd UNKNOWN 'Системный менеджер systemd недоступен' 'System manager unavailable'
    fi
}

logrotate_timer_check() {
    local state
    if ! has systemctl; then return; fi
    state=$(systemctl --system is-active logrotate.timer 2>/dev/null)
    case $state in
        active) record logrotate OK 'Таймер logrotate.timer активен' 'logrotate.timer is active' ;;
        inactive|failed|unknown) record logrotate INFO 'Таймер logrotate.timer неактивен. Проверьте cron или другой планировщик' 'logrotate.timer is not active; check cron or other scheduling locally' ;;
    esac
}

zfs_check() {
    local result used health n=0
    if ! has zpool; then record zfs SKIP 'zpool недоступен' 'zpool unavailable'; return; fi
    if ! result=$(timeout 20 zpool list -Hp -o capacity,health 2>/dev/null); then
        record zfs UNKNOWN 'Список пулов ZFS недоступен' 'ZFS pool inventory unavailable'
        return
    fi
    while read -r used health; do
        used=${used%\%}
        [[ $used =~ ^[0-9]+$ ]] || continue
        ((n+=1))
        record zfs "$(usage_status "$used")" "Пул $n: заполнен на $used%" "Pool $n: capacity_used=$used%"
        case $health in
            ONLINE) record zfs OK "Пул $n: ONLINE" "Pool $n: ONLINE" ;;
            DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|SUSPENDED)
                record zfs CRIT "Пул $n: $health" "Pool $n: $health" ;;
            *) record zfs UNKNOWN "Пул $n: неизвестное состояние" "Pool $n: health unrecognized" ;;
        esac
    done <<< "$result"
    if (( n == 0 )); then record zfs INFO 'Импортированных пулов ZFS нет' 'No imported ZFS pools'; fi
}

pve_check() {
    local result total enabled node active failed last age status id name label
    if ! has pveversion; then record proxmox SKIP 'Утилиты Proxmox VE недоступны' 'Proxmox VE tools unavailable'; return; fi
    record proxmox INFO 'Обнаружен Proxmox VE' 'Proxmox VE detected'
    if has pct; then
        if result=$(timeout 20 pct list 2>/dev/null); then
            while read -r id status _ name; do
                [[ $id =~ ^[0-9]+$ ]] || continue
                case $status in running|stopped) ;; *) status=unknown ;; esac
                label=$id
                if (( details )) && [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
                    label+=" ($name)"
                fi
                record proxmox INFO "LXC $label: состояние $status" "LXC $label: state=$status"
            done <<< "$result"
        else
            record proxmox UNKNOWN 'Список локальных LXC недоступен' 'Local LXC inventory unavailable'
        fi
    fi
    if [[ -f /etc/pve/corosync.conf ]]; then
        if result=$(timeout 15 pvecm status 2>/dev/null); then
            case $(awk '/^Quorate:/ {print $2}' <<< "$result") in
                Yes) record proxmox OK 'У кластера есть кворум' 'Cluster has quorum' ;;
                No) record proxmox CRIT 'Кластер потерял кворум' 'Cluster has lost quorum' ;;
                *) record proxmox UNKNOWN 'Не удалось определить состояние кворума' 'Cluster quorum could not be parsed' ;;
            esac
        else
            record proxmox UNKNOWN 'Состояние кворума недоступно' 'Cluster quorum status unavailable'
        fi
    else
        record proxmox INFO 'Локальная конфигурация Corosync не найдена' 'No local Corosync configuration visible'
    fi
    if ! has pvesh || ! has python3; then
        record backup UNKNOWN 'Для проверки резервных копий нужны pvesh и python3' 'Backup checks require pvesh and python3'
        return
    fi
    if result=$(timeout 20 pvesh get /cluster/backup --output-format json 2>/dev/null |
        python3 -c 'import json, sys
jobs = json.load(sys.stdin)
print(len(jobs), sum(str(j.get("enabled", 1)) in ("1", "True") for j in jobs))' 2>/dev/null) &&
        read -r total enabled <<< "$result"; then
        status=OK
        if (( ! enabled )); then status=WARN; fi
        record backup "$status" "Задания резервного копирования Proxmox: всего $total, включено $enabled" "Proxmox cluster backup jobs: total=$total enabled=$enabled"
    else
        record backup UNKNOWN 'Не удалось прочитать задания резервного копирования Proxmox' 'Could not read Proxmox cluster backup jobs'
    fi
    node=$(hostname -s 2>/dev/null)
    if [[ $node =~ ^[[:alnum:]][[:alnum:].-]*$ ]] &&
        result=$(timeout 20 pvesh get "/nodes/$node/tasks" --typefilter vzdump --limit 50 --output-format json 2>/dev/null |
        python3 -c 'import json, sys, time
tasks = json.load(sys.stdin)
finished = [t for t in tasks if t.get("endtime")]
ok = [int(t["endtime"]) for t in finished if t.get("status") == "OK"]
age = max(0, int(time.time()) - max(ok)) // 3600 if ok else -1
print(len(tasks)-len(finished), sum(t.get("status") != "OK" for t in finished), age)' 2>/dev/null) &&
        read -r active failed age <<< "$result"; then
        status=OK
        if (( failed || age < 0 || age >= 168 )); then status=WARN; fi
        last=${age}h
        if (( age < 0 )); then last=not_seen; fi
        record backup "$status" "История vzdump (до 50 задач): активных $active, с ошибками $failed, с последнего успеха: $last" "Local vzdump history (up to 50): active=$active failed=$failed last_success_age=$last"
    else
        record backup UNKNOWN 'Не удалось прочитать локальную историю vzdump' 'Could not read local vzdump history'
    fi
}

audit() {
    checks=0 warnings=0 critical=0 unknown=0
    if [[ $format == json ]]; then
        printf '{"version":"%s","checks":[\n' "$VERSION"
    else
        printf "$(message 'Server Auditor v%s | аудит | %s UTC\n' 'Server Auditor v%s | audit | %s UTC\n')" "$VERSION" "$(date -u +'%F %T')"
    fi
    report_heading 'Система и память' 'System and memory'
    record system INFO "Дистрибутив: $(os_id)" "Distribution: $(os_id)"
    memory_check
    systemd_check
    report_heading 'Пакеты и очистка APT' 'Packages and APT cleanup'
    apt_check
    cleanup_check
    report_heading 'Ядра' 'Kernels'
    kernel_check
    report_heading 'Диски и файловые системы' 'Disks and filesystems'
    disk_check
    report_heading 'Журналы и ротация' 'Logs and rotation'
    journal_check
    logrotate_check
    logrotate_timer_check
    report_heading 'Крупные файлы в /var/log' 'Large files in /var/log'
    large_logs_check
    report_heading Docker Docker
    docker_check
    report_heading 'Proxmox и ZFS' 'Proxmox and ZFS'
    pve_check
    zfs_check
    if [[ $format == json ]]; then
        printf '\n  ],"summary":{"checks":%d,"warnings":%d,"critical":%d,"unknown":%d}}\n' \
            "$checks" "$warnings" "$critical" "$unknown"
    else
        printf "$(message '\nИтог: проверок %d, предупреждений %d, критических %d, неизвестных %d\n' '\nSummary: checks=%d warnings=%d critical=%d unknown=%d\n')" \
            "$checks" "$warnings" "$critical" "$unknown"
    fi
}

update() {
    local automatic=$1 answer
    if (( EUID != 0 )); then printf "$(message 'Для обновления нужны права root.\n' 'Update requires root.\n')" >&2; return 1; fi
    case $(os_id) in
        debian|ubuntu|linuxmint) ;;
        *) printf "$(message 'Обновление доступно в Debian, Ubuntu, Linux Mint и Proxmox VE на Debian.\n' 'Update requires Debian, Ubuntu, Linux Mint, or Proxmox VE on Debian.\n')" >&2; return 1 ;;
    esac
    if ! has apt-get; then printf "$(message 'APT недоступен.\n' 'APT unavailable.\n')" >&2; return 1; fi
    if (( ! automatic )); then
        if [[ ! -t 0 || ! -t 1 ]]; then
            printf "$(message 'Для интерактивного обновления нужен терминал. Для автоматизации используйте update --yes.\n' 'Interactive update requires a terminal. Use update --yes for automation.\n')" >&2
            return 2
        fi
        read -r -p "$(message 'Обновить индексы APT и показать план обновления? [д/Н] ' 'Refresh APT indexes and review the upgrade plan? [y/N] ')" answer
        case $answer in y|Y|yes|YES|д|Д|да|Да|ДА) ;; *) printf "$(message 'Отменено.\n' 'Cancelled.\n')"; return 0 ;; esac
    fi
    run_logged_maintenance update apply_update "$automatic"
}

apply_update() {
    local automatic=$1 answer
    apt-get -o APT::Update::Error-Mode=any update || return 1
    if (( automatic )); then
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l UCF_FORCE_CONFFOLD=1 \
            apt-get "${upgrade_options[@]}" -y -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold upgrade || return 1
    else
        apt-get -s "${upgrade_options[@]}" --show-upgraded upgrade || return 1
        read -r -p "$(message 'Установить обновления из плана? [д/Н] ' 'Install the planned upgrades? [y/N] ')" answer
        case $answer in y|Y|yes|YES|д|Д|да|Да|ДА) ;; *) printf "$(message 'Установка отменена.\n' 'Installation cancelled.\n')"; return 0 ;; esac
        apt-get "${upgrade_options[@]}" -o APT::Get::Assume-Yes=false \
            --show-upgraded upgrade || return 1
    fi
    if [[ -f /run/reboot-required ]]; then printf "$(message 'Требуется перезагрузка. Запланируйте её отдельно.\n' 'Reboot required. Schedule it separately.\n')"; fi
}

history_begin() {
    local timestamp
    trusted_directory "${maintenance_state%/*}" || return 1
    if [[ -L $maintenance_state ]] ||
        ! install -d -m 0700 -- "$maintenance_state" ||
        [[ $(stat -c '%u:%a' -- "$maintenance_state") != 0:700 ]]; then
        return 1
    fi
    timestamp=$(date -u +%Y%m%dT%H%M%SZ) || return 1
    mktemp -d -- "$maintenance_state/$timestamp.XXXXXXXX"
}

finish_maintenance_history() {
    local result=$1 action_status=${status:-$1}
    trap - EXIT INT TERM
    if (( result == 130 || result == 143 )); then action_status=$result; history_recording_status=interrupted; fi
    if ! printf 'recording_status=%s\nfinished=%s\nexit_status=%s\n' "$history_recording_status" "$(date -u +%FT%TZ)" "$action_status" >> "$logfile" ||
        ! sync -- "$logfile"; then
        printf '%s\n' "$(message 'Не удалось завершить запись истории.' 'Could not finalize operation history.')" >&2
        if (( result == 0 )); then result=1; fi
    fi
    exit "$result"
}

maintenance_space_paths() {
    local action=$1 docker_root
    shift
    printf '%s\0' "$maintenance_state"
    case $action in
        archive) printf '%s\0' "${2%/*}" "$3" ;;
        delete-archive) printf '%s\0' "${2%/*}" ;;
        update|clean|autoremove|kernel|orphan-kernel)
            printf '%s\0' / /usr /boot /boot/efi /opt /var/lib/dpkg /var/cache/apt /var/lib/apt ;;
        rotate|vacuum|limit)
            printf '%s\0' /var/log/journal /run/log/journal
            if [[ $action == limit ]]; then printf '%s\0' "${journal_dropin%/*}"; fi ;;
        rsyslog-policy) printf '%s\0' "${rsyslog_rule%/*}" ;;
        logrotate-edit) printf '%s\0' "${2%/*}" ;;
        restore-config) printf '%s\0' "${restore_target%/*}" ;;
        logrotate) printf '%s\0' /var/log /var/lib/logrotate ;;
        docker-image|docker-cache)
            if docker_root=$(docker_local info --format '{{.DockerRootDir}}' 2>/dev/null) &&
                [[ $docker_root == /* ]]; then printf '%s\0' "$docker_root"; fi
            printf '%s\0' /var/lib/containerd ;;
        compose-logging|compose-logging-apply)
            printf '%s\0' "$3"
            if [[ $action == compose-logging-apply ]]; then
                if docker_root=$(docker_local info --format '{{.DockerRootDir}}' 2>/dev/null) &&
                    [[ $docker_root == /* ]]; then printf '%s\0' "$docker_root"; fi
                printf '%s\0' /var/lib/containerd
            fi ;;
        *) printf '/\0' ;;
    esac
}

filesystem_available_bytes() {
    local value
    value=$(df -B1 --output=avail -- "$1" 2>/dev/null) || return 1
    value=${value##*$'\n'}
    value=${value//[[:space:]]/}
    [[ $value =~ ^-?[0-9]{1,18}$ ]] || return 1
    printf '%s' "$value"
}

human_bytes() {
    local bytes=$1
    if (( bytes > -1024 && bytes < 1024 )); then
        printf '%s %s' "$bytes" "$(message байт B)"
    else
        human_kib "$((bytes / 1024))"
    fi
}

maintenance_space_result() {
    local index path device after before change label sign
    printf '\n%s\n' "$(message 'Изменение доступного места за время операции:' 'Available space change during the operation:')"
    for index in "${!space_paths[@]}"; do
        path=${space_paths[index]}
        printf -v label '%q' "${space_mounts[index]}"
        before=${space_before[index]}
        if ! device=$(stat -c %d -- "$path" 2>/dev/null) ||
            [[ $device != "${space_devices[index]}" ]] ||
            ! after=$(filesystem_available_bytes "$path"); then
            printf 'space_after_bytes[%d]=unknown\nspace_change_bytes[%d]=unknown\n' "$index" "$index" >> "$logfile" || return 1
            printf '%s\n' "$(message "$label — итоговый замер недоступен." "$label — the final measurement is unavailable.")"
            continue
        fi
        printf 'space_after_bytes[%d]=%s\n' "$index" "$after" >> "$logfile" || return 1
        if [[ $before == unknown ]]; then
            printf 'space_change_bytes[%d]=unknown\n' "$index" >> "$logfile" || return 1
            printf '%s\n' "$(message "$label — исходный замер недоступен." "$label — the initial measurement is unavailable.")"
            continue
        fi
        change=$((after - before))
        sign=
        if (( change > 0 )); then sign=+; fi
        printf 'space_change_bytes[%d]=%s\n' "$index" "$change" >> "$logfile" || return 1
        printf '%s\n' "$(message "$label — до $(human_bytes "$before"), после $(human_bytes "$after"), изменение $sign$(human_bytes "$change")" \
            "$label — before $(human_bytes "$before"), after $(human_bytes "$after"), change $sign$(human_bytes "$change")")"
    done
    printf '%s\n' "$(message 'Измерение включает параллельную запись других служб.' 'Measurements include concurrent writes by other services.')"
}

run_logged_maintenance() (
    local action=$1
    shift
    local operation_dir logfile status= lock_fd path device before mount index measurement_error=0 history_recording_status=complete
    local -a pipeline_status
    local -a space_paths=() space_mounts=() space_before=() space_devices=()
    local -A measured_devices=()
    if ! operation_dir=$(history_begin); then
        printf '%s\n' "$(message 'Не удалось создать историю. Действие отменено.' 'Could not create operation history. Action cancelled.')" >&2
        return 1
    fi
    if [[ -L $maintenance_state/maintenance.lock ||
        ( -e $maintenance_state/maintenance.lock && ! -f $maintenance_state/maintenance.lock ) ]] ||
        ! { exec {lock_fd}>>"$maintenance_state/maintenance.lock"; } || ! flock -n "$lock_fd"; then
        printf '%s\n' "$(message 'Не удалось заблокировать обслуживание. Действие отменено.' 'Could not lock maintenance. Action cancelled.')" >&2
        return 1
    fi
    logfile=$operation_dir/history.log
    if ! (umask 077; printf 'action=%s\nstarted=%s\n' "$action" "$(date -u +%FT%TZ)" > "$logfile") ||
        ! sync -- "$logfile" "$operation_dir" "$maintenance_state"; then
        printf '%s\n' "$(message 'Не удалось записать историю. Действие отменено.' 'Could not write operation history. Action cancelled.')" >&2
        return 1
    fi
    trap 'finish_maintenance_history "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '%s\n' "$(message "История: $logfile" "History: $logfile")"
    while IFS= read -r -d '' path; do
        while [[ ! -d $path && $path != / ]]; do path=${path%/*}; path=${path:-/}; done
        if ! device=$(stat -c %d -- "$path" 2>/dev/null) || ! [[ $device =~ ^[0-9]+$ ]]; then
            measurement_error=1
            continue
        fi
        [[ -z ${measured_devices[$device]:-} ]] || continue
        measured_devices[$device]=1
        before=$(filesystem_available_bytes "$path") || before=unknown
        mount=$(df --output=target -- "$path" 2>/dev/null) && mount=${mount#*$'\n'} || mount=$path
        space_paths+=("$path")
        space_mounts+=("$mount")
        space_before+=("$before")
        space_devices+=("$device")
        index=$((${#space_paths[@]} - 1))
        printf 'space_path[%d]=%q\nspace_mount[%d]=%q\nspace_device[%d]=%s\nspace_before_bytes[%d]=%s\n' \
            "$index" "$path" "$index" "$mount" "$index" "$device" "$index" "$before" >> "$logfile" || return 1
    done < <(maintenance_space_paths "$action" "$@")
    if (( measurement_error )); then
        printf '%s\n' "$(message 'Часть файловых систем не удалось определить. Итоговый замер может быть неполным.' \
            'Some filesystems could not be identified. The final measurement may be incomplete.')" | tee -a -- "$logfile" || return 1
        measurement_error=0
    fi
    if ! sync -- "$logfile"; then return 1; fi
    if "$@" 2>&1 | tee -a -- "$logfile"; then
        pipeline_status=("${PIPESTATUS[@]}")
    else
        pipeline_status=("${PIPESTATUS[@]}")
    fi
    status=${pipeline_status[0]}
    if ! maintenance_space_result | tee -a -- "$logfile"; then measurement_error=1; history_recording_status=incomplete; fi
    if (( pipeline_status[1] != 0 )); then
        history_recording_status=incomplete
        printf '%s\n' "$(message 'Запись истории могла прерваться. Проверьте результат действия.' 'History may be incomplete. Check the action result.')" >&2
        return 1
    fi
    if (( measurement_error )); then
        printf '%s\n' "$(message 'Не удалось полностью записать итоговый замер в историю.' \
            'Could not fully record the final measurement in history.')" >&2
        return 1
    fi
    return "$status"
)

finish_config_change() {
    local result=$1 current restored=1
    trap - EXIT INT TERM
    if (( config_pending && ! config_committed )); then
        current=$(stat -c '%d:%i:%s:%y' -- "$config_target" 2>/dev/null) || current=absent
        if [[ $current == "$config_expected" ]]; then
            if [[ -f $config_backup ]]; then
                if ! cp -p -- "$config_backup" "$temporary" || ! sync -- "$temporary" ||
                    ! mv -fT -- "$temporary" "$config_target"; then result=1; restored=0; fi
            elif [[ $config_original == absent ]]; then
                if ! rm -- "$config_target"; then result=1; restored=0; fi
            else
                result=1
                restored=0
            fi
            sync -- "${config_target%/*}" || result=1
            if (( config_restart && restored )); then systemctl restart systemd-journald.service || result=1; fi
            if (( restored )); then
                printf '%s\n' "$(message "Восстановлен файл $config_target. Резервная копия: $config_backup" \
                    "Restored file $config_target. Backup: $config_backup")" >&2
            else
                printf '%s\n' "$(message "Откат файла $config_target не завершён. Резервная копия: $config_backup" \
                    "File rollback for $config_target did not complete. Backup: $config_backup")" >&2
            fi
        elif [[ $current != "$config_original" ]]; then
            printf '%s\n' "$(message "Файл $config_target изменился извне. Для восстановления используйте копию $config_backup." \
                "File $config_target changed externally. Use backup $config_backup for recovery.")" >&2
            result=1
        fi
    fi
    if [[ -n $temporary ]]; then rm -f -- "$temporary" || result=1; fi
    exit "$result"
}

file_sha256() {
    local digest
    digest=$(sha256sum < "$1") || return 1
    printf '%s' "${digest%% *}"
}

write_config_restore_metadata() {
    local kind=$1 target=$2 backup=$3 project=${4:-} before_hash=- after_hash
    if [[ -f $backup ]]; then before_hash=$(file_sha256 "$backup") || return 1; fi
    after_hash=$(file_sha256 "$target") || return 1
    [[ $(stat -c '%d:%i:%s:%y' -- "$target") == "$config_expected" ]] || return 1
    if [[ $before_hash == "$after_hash" ]]; then return 0; fi
    (umask 077; printf '%s\0' 1 "$kind" "$target" "${backup##*/}" "$before_hash" "$after_hash" "$project" > "$operation_dir/restore.info") &&
        sync -- "$operation_dir/restore.info" "$operation_dir" || return 1
    printf 'restore_metadata=%q\n' "$operation_dir/restore.info" >> "$logfile"
}

configure_journal_limit() (
    local temporary= previous=$operation_dir/journald.conf.before
    local config_target=$journal_dropin config_backup=$previous config_original config_expected=
    local config_pending=0 config_committed=0 config_restart=0
    trap 'finish_config_change "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -L $journal_dropin || ( -e $journal_dropin && ! -f $journal_dropin ) ]]; then return 1; fi
    mkdir -p -- "${journal_dropin%/*}" || return 1
    config_original=$(stat -c '%d:%i:%s:%y' -- "$journal_dropin" 2>/dev/null) || config_original=absent
    if [[ -e $journal_dropin ]]; then
        cp -p -- "$journal_dropin" "$previous" || return 1
        printf 'backup=%s\n' "$previous" >> "$logfile" || return 1
    else
        printf 'previous=absent\n' >> "$logfile" || return 1
    fi
    printf 'dropin=%s\n' "$journal_dropin" >> "$logfile" && sync -- "$logfile" "$operation_dir" || return 1
    if [[ -f $previous ]]; then sync -- "$previous" || return 1; fi
    temporary=$(mktemp -- "$journal_dropin.XXXXXXXX") || return 1
    printf '[Journal]\nSystemMaxUse=%s\nRuntimeMaxUse=%s\n' "$journal_limit" "$journal_limit" > "$temporary" &&
        chmod 0644 -- "$temporary" || return 1
    config_expected=$(stat -c '%d:%i:%s:%y' -- "$temporary") || return 1
    local current
    current=$(stat -c '%d:%i:%s:%y' -- "$journal_dropin" 2>/dev/null) || current=absent
    [[ $current == "$config_original" ]] || return 1
    config_pending=1
    mv -fT -- "$temporary" "$journal_dropin" || return 1
    if systemd-analyze --no-pager cat-config systemd/journald.conf |
        awk -F= -v limit="$journal_limit" '
            /^[[:space:]]*\[/ { section=$0; gsub(/[[:space:]]/, "", section) }
            section=="[Journal]" {
                key=$1; value=$2
                gsub(/[[:space:]]/, "", key)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (key=="SystemMaxUse") persistent_limit=value
                if (key=="RuntimeMaxUse") volatile_limit=value
            }
            END { exit !(persistent_limit==limit && volatile_limit==limit) }
        '; then
        config_restart=1
        systemctl restart systemd-journald.service || return 1
        sync -- "$journal_dropin" "${journal_dropin%/*}" || return 1
        write_config_restore_metadata journald "$journal_dropin" "$previous" || return 1
        config_committed=1
        return 0
    fi
    printf '%s\n' "$(message 'Не удалось применить лимит. Восстанавливаю прежнюю конфигурацию.' \
        'Could not apply the limit. Restoring the previous configuration.')" >&2
    return 1
)

rsyslog_policy() {
    awk -v size="$rsyslog_size_mib" -v count="$rsyslog_archive_count" -v flexible="$rsyslog_custom" '
        /^[[:space:]]*\/var\/log\/syslog[[:space:]]*$/ && !opens { syslog++ }
        /^[[:space:]]*\{[[:space:]]*$/ { opens++; block=1 }
        /^[[:space:]]*\}[[:space:]]*$/ { closes++; block=0 }
        block && /^[[:space:]]*(prerotate|postrotate|firstaction|lastaction|preremove)[[:space:]]*$/ { script=1 }
        block && !script && /^[[:space:]]*(weekly|daily)[[:space:]]*$/ {
            frequency++
            match($0, /^[[:space:]]*/)
            indent=substr($0, 1, RLENGTH)
            print indent "daily"
            print indent "maxsize " size "M"
            if (flexible) print indent "rotate " count
            next
        }
        block && !script && /^[[:space:]]*maxsize[[:space:]]+100M[[:space:]]*$/ { target++; next }
        block && !script && flexible && /^[[:space:]]*maxsize[[:space:]]+[0-9]+[kKMG]?[[:space:]]*$/ { target++; next }
        block && !script && flexible && /^[[:space:]]*rotate[[:space:]]+[0-9]+[[:space:]]*$/ { next }
        block && !script && /^[[:space:]]*(size|minsize|maxsize|hourly|monthly|yearly|minutes)([[:space:]]|$)/ { custom++ }
        { print }
        block && /^[[:space:]]*endscript[[:space:]]*$/ { script=0 }
        END { exit !(syslog==1 && opens==1 && closes==1 && frequency==1 && target<=1 && !custom && !script) }
    ' "$1"
}

configure_rsyslog_rotation() (
    local previous=$operation_dir/rsyslog.conf.before temporary= fingerprint
    local config_target=$rsyslog_rule config_backup=$previous config_original config_expected=
    local config_pending=0 config_committed=0 config_restart=0
    trap 'finish_config_change "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ -f $rsyslog_rule && ! -L $rsyslog_rule ]] || return 1
    logrotate -d "$logrotate_config" >/dev/null 2>&1 || return 1
    fingerprint=$(stat -c '%d:%i:%s:%y:%z' -- "$rsyslog_rule") || return 1
    config_original=$(stat -c '%d:%i:%s:%y' -- "$rsyslog_rule") || return 1
    temporary=$(mktemp -- "$rsyslog_rule.XXXXXXXX.disabled") || return 1
    if ! rsyslog_policy "$rsyslog_rule" > "$temporary"; then
        printf '%s\n' "$(message 'Нестандартное правило rsyslog. Изменение отменено.' 'Custom rsyslog rule. No change applied.')" >&2
        return 1
    fi
    if cmp -s -- "$rsyslog_rule" "$temporary"; then
        printf '%s\n' "$(message 'Выбранные параметры ротации уже настроены.' 'The selected rotation settings are already configured.')"
        return 0
    fi
    cp -p -- "$rsyslog_rule" "$previous" &&
        printf 'config=%s\nbackup=%s\n' "$rsyslog_rule" "$previous" >> "$logfile" &&
        sync -- "$previous" "$logfile" "$operation_dir" || return 1
    diff -u -- "$previous" "$temporary" || [[ $? == 1 ]] || return 1
    chmod --reference="$previous" -- "$temporary" && chown --reference="$previous" -- "$temporary" &&
        [[ $(stat -c '%d:%i:%s:%y:%z' -- "$rsyslog_rule") == "$fingerprint" ]] || return 1
    config_expected=$(stat -c '%d:%i:%s:%y' -- "$temporary") || return 1
    config_pending=1
    mv -fT -- "$temporary" "$rsyslog_rule" || return 1
    if logrotate -d "$logrotate_config" >/dev/null &&
        sync -- "$rsyslog_rule" "${rsyslog_rule%/*}" &&
        write_config_restore_metadata rsyslog "$rsyslog_rule" "$previous"; then config_committed=1; return 0; fi
    printf '%s\n' "$(message 'Проверка не прошла. Восстанавливаю прежнее правило.' 'Validation failed. Restoring the previous rule.')" >&2
    return 1
)

trusted_directory() {
    local directory=$1 owner mode
    while :; do
        read -r owner mode < <(stat -c '%u %a' -- "$directory") || return 1
        [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022) == 0 )) || return 1
        [[ $directory == / ]] && return 0
        directory=${directory%/*}
        directory=${directory:-/}
    done
}

proc_archive_closed() {
    local source=$1 mount fstype options result attempt
    mount=$(findmnt -n -o FSTYPE,OPTIONS --target /proc) || return 1
    read -r fstype options <<< "$mount"
    [[ $fstype == proc && -r /proc/self/fd && -x /proc/self/fd ]] || return 1
    case ,$options, in
        *,hidepid=0,*|*,hidepid=off,*) ;;
        *,hidepid=*) return 1 ;;
    esac
    for attempt in 1 2; do
        # Ignore unrelated proc trees and never descend through a descriptor.
        if result=$(timeout 15 find -P /proc -regextype posix-extended -ignore_readdir_race -maxdepth 3 \
            \( ! -regex '/proc(/[0-9]+(/fd(/[0-9]+)?)?)?' -prune \) -o \
            \( -regex '/proc/[0-9]+/fd/[0-9]+' -xtype f -exec test '{}' -ef "$source" \; -print -quit \) 2>&1); then
            if [[ -z $result ]]; then return 0; fi
            return 1
        fi
    done
    return 1
}

log_archive_path_is_allowed() {
    [[ $1 == /var/log/* && $1 != /var/log/journal/* &&
        ( $1 =~ ^/var/log/syslog\.[0-9]+$ || $1 =~ \.(gz|xz|bz2|zst)$ ) ]]
}

archive_source_ready() {
    local source=$1
    if log_archive_path_is_allowed "$source" && archive_file_closed "$source"; then return 0; fi
    printf '%s\n' "$(message 'Действие отменено: это не поддерживаемый архив логов, файл открыт или проверка дескрипторов не завершилась.' \
        'Action cancelled: this is not a supported log archive, the file is open, or the descriptor check was incomplete.')" >&2
    return 1
}

archive_file_closed() {
    local source=$1 result status
    if has fuser; then
        if result=$(fuser -- "$source" 2>&1); then status=0; else status=$?; fi
        if (( status == 1 )) && [[ -z $result ]]; then return 0; fi
    elif proc_archive_closed "$source"; then
        return 0
    fi
    return 1
}

finish_archive_deletion() {
    local result=$1
    trap - EXIT INT TERM
    if [[ -e $staged || -L $staged ]]; then
        if ln -T -- "$staged" "$source"; then
            rm -- "$staged" && sync -- "${source%/*}" || result=1
            printf '%s\n' "$(message "Удаление отменено, архив сохранён: $source" \
                "Deletion cancelled, archive kept: $source")" >&2
        else
            printf '%s\n' "$(message "Файл сохранён для ручного восстановления: $staged" \
                "File kept for manual recovery: $staged")" >&2
            result=1
        fi
    fi
    if [[ -d $quarantine && ! -e $staged && ! -L $staged ]]; then rmdir -- "$quarantine" || result=1; fi
    exit "$result"
}

delete_log_archive() (
    local source=$1 fingerprint=$2 digest metadata current moved_identity quarantine staged
    log_archive_path_is_allowed "$source" &&
        [[ -f $source && ! -L $source && $(stat -c %h -- "$source") == 1 ]] &&
        trusted_directory "${source%/*}" && archive_source_ready "$source" || return 1
    current=$(stat -c '%d:%i:%s:%y:%z' -- "$source") || return 1
    if [[ $current != "$fingerprint" ]]; then
        printf '%s\n' "$(message 'Архив изменился после предварительного просмотра. Удаление остановлено.' \
            'The archive changed after the preview. Deletion stopped.')" >&2
        return 1
    fi
    digest=$(file_sha256 "$source") || return 1
    metadata=$(stat -c $'archive_apparent_bytes=%s\narchive_allocated_blocks=%b\narchive_modified=%y' -- "$source") || return 1
    printf 'archive_source=%q\narchive_fingerprint=%q\narchive_sha256=%s\nbackup=none\n%s\narchive_delete_intent=yes\n' \
        "$source" "$fingerprint" "$digest" "$metadata" >> "$logfile" &&
        sync -- "$logfile" "$operation_dir" || return 1
    [[ -f $source && ! -L $source && $(stat -c %h -- "$source") == 1 ]] &&
        trusted_directory "${source%/*}" && archive_source_ready "$source" &&
        [[ $(stat -c '%d:%i:%s:%y:%z' -- "$source") == "$fingerprint" ]] || return 1
    moved_identity=$(stat -c '%d:%i:%s:%y' -- "$source") || return 1
    quarantine=$(mktemp -d -- "${source%/*}/.server-auditor-delete.XXXXXXXX") || return 1
    staged=$quarantine/${source##*/}
    trap 'finish_archive_deletion "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf 'archive_staged_path=%q\n' "$staged" >> "$logfile" &&
        sync -- "$logfile" "$operation_dir" &&
        [[ $(stat -c '%d:%i:%s:%y:%z' -- "$source") == "$fingerprint" ]] || return 1
    mv -T -- "$source" "$staged" || return 1
    [[ -f $staged && ! -L $staged && $(stat -c %h -- "$staged") == 1 &&
        $(stat -c '%d:%i:%s:%y' -- "$staged") == "$moved_identity" ]] &&
        archive_file_closed "$staged" && [[ $(file_sha256 "$staged") == "$digest" ]] || return 1
    rm -- "$staged" || return 1
    printf 'archive_deleted=yes\n' >> "$logfile" &&
        sync -- "${source%/*}" "$logfile" || return 1
    printf '%s\n' "$(message "Удалён архив: $source" "Archive deleted: $source")"
)

choose_archive_action() {
    local source=$1 choice label
    printf -v label '%q' "$source"
    printf '\n%s\n' "$label"
    safety_line clean "$(message '1. Перенести на другой диск с проверкой копии' '1. Move to another filesystem with a verified backup')"
    safety_line review "$(message '2. Удалить без резервной копии — история записей будет потеряна' \
        '2. Delete without a backup — the log history will be lost')"
    printf '%s\n' "$(message '0. Назад' '0. Back')"
    printf '%s' "$(message 'Ваш выбор: ' 'Your choice: ')"
    IFS= read -r choice || return 0
    case $choice in
        1) maintenance_action archive "$source" ;;
        2) maintenance_action delete-archive "$source" ;;
        0|'') return 0 ;;
        *) printf '%s\n' "$(message 'Выберите 1, 2 или 0.' 'Choose 1, 2 or 0.')"; return 2 ;;
    esac
}

archive_log() {
    local source=$1 destination=$2 fingerprint=$3 backup_dir backup destination_device
    [[ -f $source && ! -L $source && ! -L $destination && -d $destination ]] &&
        trusted_directory "${source%/*}" && trusted_directory "$destination" &&
        [[ $(stat -c %h -- "$source") == 1 ]] || return 1
    destination_device=$(stat -c %d -- "$destination") || return 1
    [[ $(stat -c '%d:%i:%s:%y:%z' -- "$source") == "$fingerprint" &&
        ${fingerprint%%:*} != "$destination_device" ]] && archive_source_ready "$source" || return 1
    backup_dir=$(mktemp -d -- "$destination/server-auditor.XXXXXXXX") || return 1
    backup=$backup_dir/${source##*/}
    printf 'source=%q\nbackup=%q\n' "$source" "$backup" >> "$logfile" || return 1
    cp -p -- "$source" "$backup" && cmp -s -- "$source" "$backup" &&
        sync -- "$backup" "$backup_dir" "$destination" &&
        [[ $(stat -c '%d:%i:%s:%y:%z' -- "$source") == "$fingerprint" ]] || return 1
    printf 'backup_verified=yes\n' >> "$logfile" && sync -- "$logfile" || return 1
    [[ -f $source && ! -L $source && $(stat -c %h -- "$source") == 1 ]] &&
        trusted_directory "${source%/*}" && trusted_directory "$destination" &&
        [[ $(stat -c %d -- "$destination") == "$destination_device" ]] &&
        archive_source_ready "$source" &&
        [[ ! -L $backup && -f $backup && $(stat -c '%d:%i:%s:%y:%z' -- "$source") == "$fingerprint" ]] &&
        cmp -s -- "$source" "$backup" || return 1
    rm -- "$source" || return 1
    sync -- "${source%/*}" || return 1
    printf '%s\n' "$(message "Проверенная копия: $backup" "Verified backup: $backup")"
}

kernel_package() {
    case $1 in
        linux-image*|linux-modules*|linux-headers*|linux-kbuild*|linux-tools*|pve-kernel*|pve-headers*|proxmox-kernel*|proxmox-headers*) return 0 ;;
        *) return 1 ;;
    esac
}

kernel_image_release() {
    local package=${1%%:*}
    if [[ $package =~ ^linux-image-(unsigned-)?([0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9]|\+deb[0-9])[a-z0-9.+-]*)$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

kernel_has_boot_files() {
    [[ -s /boot/vmlinuz-$1 && -s /boot/initrd.img-$1 ]]
}

kernel_removal_inventory() {
    local result status package release
    newest_kernel= fallback_kernel=
    installed_images=()
    if (( $# == 2 )); then
        result=$1 running_kernel=$2
    else
        running_kernel=$(uname -r) || return 1
        result=$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-*') || return 1
    fi
    has dpkg || return 1
    while read -r status package; do
        [[ $status == installed ]] || continue
        release=$(kernel_image_release "$package") || continue
        installed_images[$package]=$release
        if [[ -z $newest_kernel ]] || dpkg --compare-versions "$release" gt "$newest_kernel"; then
            newest_kernel=$release
        fi
        if [[ $release != "$running_kernel" ]] && kernel_has_boot_files "$release" &&
            { [[ -z $fallback_kernel ]] || dpkg --compare-versions "$release" gt "$fallback_kernel"; }; then
            fallback_kernel=$release
        fi
    done <<< "$result"
    [[ -n $fallback_kernel && -n $newest_kernel ]] || return 1
    for release in "${installed_images[@]}"; do
        if [[ $release == "$running_kernel" ]]; then return 0; fi
    done
    return 1
}

kernel_retention_reason() {
    local package=${1%%:*} release=$2 ready=$3
    if [[ $release == "$running_kernel" ]]; then printf running
    elif [[ -z ${installed_images[$package]:-} ]]; then printf unsupported
    elif [[ $release == "$fallback_kernel" && $release == "$newest_kernel" ]]; then printf fallback-newest
    elif [[ $release == "$fallback_kernel" ]]; then printf fallback
    elif [[ $release == "$newest_kernel" ]]; then printf newest
    elif (( ! ready )); then printf unverified
    else printf eligible
    fi
}

remove_selected_kernel() {
    local package=$1 running_kernel newest_kernel fallback_kernel release
    local -A installed_images=()
    kernel_removal_inventory || return 1
    release=${installed_images[${package%%:*}]:-}
    [[ $(kernel_retention_reason "$package" "$release" 1) == eligible ]] || return 1
    apt_remove_exact "$package"
}

validate_kernel_package_selection() {
    local package release abi protected=0 running_kernel newest_kernel fallback_kernel
    local -A installed_images=()
    for package in "$@"; do
        if kernel_package "$package"; then protected=1; break; fi
    done
    if (( ! protected )); then return 0; fi
    kernel_removal_inventory || return 1
    for package in "$@"; do
        if ! kernel_package "$package"; then continue; fi
        if release=$(kernel_image_release "$package"); then
            [[ $(kernel_retention_reason "$package" "$release" 1) == eligible ]] || return 1
        elif [[ ${package%%:*} =~ ^linux-(headers|modules(-extra)?|tools)-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)(-[a-z0-9][a-z0-9.-]*)?$ ]]; then
            abi=${BASH_REMATCH[3]}
            for release in "${installed_images[@]}"; do
                if [[ $release == "$abi" || $release == "$abi"-* ]]; then return 1; fi
            done
            if [[ -e /boot/vmlinuz-$abi ]] || compgen -G "/boot/vmlinuz-$abi-*" >/dev/null; then return 1; fi
        else
            return 1
        fi
    done
}

apt_remove_exact() {
    local plan answer package fresh_plan
    local -a options=(-o quiet=0 -o APT::Get::Assume-Yes=false -o APT::Get::Purge=false -o APT::Get::AutomaticRemove=false)
    (( $# )) || return 1
    for package in "$@"; do
        [[ $package =~ ^[a-z0-9][a-z0-9.+-]*(:[a-z0-9-]+)?$ ]] || return 1
    done
    validate_kernel_package_selection "$@" || return 1
    plan=$(apt-get -s "${options[@]}" remove "$@") || return 1
    printf '%s\n' "$plan"
    if ! awk -v packages="$*" '
        BEGIN {
            n=split(packages, names, " ")
            for (i=1; i<=n; i++) {
                name=names[i]; sub(/:.*/, "", name)
                if (name in expected) changes++
                expected[name]=names[i]
            }
        }
        /^Remv / {
            name=$2; sub(/:.*/, "", name)
            if (!expected[name] || seen[name]++ ||
                ($2 ~ /:/ && expected[name] ~ /:/ && $2 != expected[name])) changes++
            removals++
        }
        /^(Inst|Conf|Purg) / { changes++ }
        /^0 upgraded, 0 newly installed, [0-9]+ to remove and [0-9]+ not upgraded\./ { if ($6==n) summary++ }
        END { exit !(removals==n && !changes && summary==1) }
    ' <<< "$plan"; then
        printf '%s\n' "$(message 'План APT не совпадает с выбранным списком пакетов. Остановлено.' \
            'The APT plan does not match the selected package list. Stopped.')" >&2
        return 1
    fi
    printf '%s' "$(message "Удалить $*? [д/Н] " "Remove $*? [y/N] ")"
    IFS= read -r answer || answer=
    case $answer in
        y|Y|yes|YES|д|Д|да|Да|ДА) ;;
        *)
            if (( $# == 1 )); then
                printf '\n%s\n' "$(message "Отменено: $1 сохранён." "Cancelled: $1 was kept.")"
            else
                printf '\n%s\n' "$(message 'Отменено: выбранные пакеты сохранены.' 'Cancelled: the selected packages were kept.')"
            fi
            return 0 ;;
    esac
    fresh_plan=$(apt-get -s "${options[@]}" remove "$@") || return 1
    if [[ $fresh_plan != "$plan" ]] || ! validate_kernel_package_selection "$@"; then
        printf '%s\n' "$(message 'План APT или защита ядер изменились после подтверждения. Удаление остановлено.' \
            'The APT plan or kernel protection changed after confirmation. Removal stopped.')" >&2
        return 1
    fi
    apt-get "${options[@]}" remove "$@"
}

remove_unused_dependencies() {
    local autoremove_known=0 package
    local -a autoremove_candidates=()
    local format=txt details=1
    cleanup_check
    (( autoremove_known )) || return 1
    if (( ${#autoremove_candidates[@]} == 0 )); then return 0; fi
    for package in "${autoremove_candidates[@]}"; do
        if kernel_package "$package"; then
            printf '%s\n' "$(message 'Свежий план APT содержит пакет ядра. Удаление зависимостей остановлено.' \
                'The fresh APT plan contains a kernel package. Dependency removal stopped.')" >&2
            return 1
        fi
    done
    apt_remove_exact "${autoremove_candidates[@]}"
}

orphan_kernel_candidates() {
    local running_kernel newest_kernel fallback_kernel package abi release installed
    local autoremove_known=0
    local -A installed_images=()
    local -a autoremove_candidates=()
    if has pveversion; then return 1; fi
    kernel_removal_inventory || return 1
    details=0 cleanup_check >/dev/null
    (( autoremove_known )) || return 1
    for package in "${autoremove_candidates[@]}"; do
        [[ ${package%%:*} =~ ^linux-(headers|modules(-extra)?|tools)-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)(-[a-z0-9][a-z0-9.-]*)?$ ]] || continue
        abi=${BASH_REMATCH[3]}
        installed=0
        for release in "${installed_images[@]}"; do
            if [[ $release == "$abi" || $release == "$abi"-* ]]; then installed=1; break; fi
        done
        if (( installed )) || [[ -e /boot/vmlinuz-$abi ]] || compgen -G "/boot/vmlinuz-$abi-*" >/dev/null; then continue; fi
        printf '%s %s\n' "$abi" "$package"
    done
}

remove_orphan_kernel_group() {
    local selected=$1 result abi package
    local -a packages=()
    result=$(orphan_kernel_candidates) || return 1
    while read -r abi package; do
        if [[ $abi == "$selected" ]]; then packages+=("$package"); fi
    done <<< "$result"
    apt_remove_exact "${packages[@]}"
}

choose_orphan_kernel_group() {
    local result abi package selected index
    local -a groups=()
    local -A seen=()
    if ! result=$(orphan_kernel_candidates); then
        printf '%s\n' "$(message 'Не удалось подтвердить список и защиту ядер.' 'Could not verify the package list and kernel protection.')" >&2
        return 1
    fi
    if [[ -z $result ]]; then
        printf '%s\n' "$(message 'Связанных пакетов старых ядер к удалению нет.' 'No leftover packages of old kernels are eligible.')"
        return 0
    fi
    while read -r abi package; do
        if [[ -z ${seen[$abi]:-} ]]; then groups+=("$abi"); fi
        seen[$abi]+=" $package"
    done <<< "$result"
    for index in "${!groups[@]}"; do
        abi=${groups[index]}
        printf '  %d. %s —%s\n' "$((index + 1))" "$abi" "${seen[$abi]}"
    done
    printf '%s' "$(message 'Выберите номер группы (0 или Enter — отмена): ' \
        'Choose a group number (0 or Enter to cancel): ')"
    IFS= read -r selected || return 0
    [[ -n $selected && $selected != 0 ]] || return 0
    for index in "${!groups[@]}"; do
        if [[ $selected == "$((index + 1))" ]]; then
            run_logged_maintenance orphan-kernel remove_orphan_kernel_group "${groups[index]}"
            return
        fi
    done
    printf '%s\n' "$(message 'Выберите номер из списка.' 'Choose a number from the list.')" >&2
    return 1
}

choose_kernel_removal() {
    local running_kernel newest_kernel fallback_kernel package release selected index
    local autoremove_known=0
    local -a autoremove_candidates=() candidates=()
    local -A installed_images=()
    if ! kernel_removal_inventory; then
        printf '%s\n' "$(message 'Не удалось подтвердить запущенное ядро и отдельное запасное ядро с файлами загрузки.' \
            'Could not verify the running kernel and a separate fallback with boot files.')" >&2
        return 1
    fi
    details=0 cleanup_check >/dev/null
    if (( ! autoremove_known )); then
        printf '%s\n' "$(message 'План APT недоступен.' 'The APT plan is unavailable.')" >&2
        return 1
    fi
    printf '%s\n' "$(message "Остаются: запущенное $running_kernel, самое новое $newest_kernel, запасное $fallback_kernel." \
        "Kept: running $running_kernel, newest $newest_kernel, fallback $fallback_kernel.")"
    for package in "${autoremove_candidates[@]}"; do
        release=${installed_images[${package%%:*}]:-}
        [[ $(kernel_retention_reason "$package" "$release" 1) == eligible ]] || continue
        candidates+=("$package")
    done
    if (( ${#candidates[@]} == 0 )); then
        printf '%s\n' "$(message 'Подходящих старых пакетов ядер в плане APT нет.' 'No eligible old kernel packages in the APT plan.')"
        return 0
    fi
    printf '%s\n' "$(message 'Кандидаты на удаление:' 'Removal candidates:')"
    for index in "${!candidates[@]}"; do
        printf '  %d. %s\n' "$((index + 1))" "${candidates[index]}"
    done
    printf '%s' "$(message 'Выберите номер пакета для проверки плана (0 или Enter — отмена): ' \
        'Choose a package number to review the plan (0 or Enter to cancel): ')"
    IFS= read -r selected || return 0
    [[ -n $selected && $selected != 0 ]] || return 0
    for index in "${!candidates[@]}"; do
        if [[ $selected == "$((index + 1))" ]]; then
            run_logged_maintenance kernel remove_selected_kernel "${candidates[index]}"
            return
        fi
    done
    printf '%s\n' "$(message 'Выберите номер из списка.' 'Choose a number from the list.')" >&2
    return 1
}

choose_log_number() {
    local variable=$1 fallback=$2 maximum=$3 prompt=$4 value
    while :; do
        printf '%s [%s; q — %s]: ' "$prompt" "$fallback" "$(message отмена cancel)"
        IFS= read -r value || return 1
        [[ $value != q && $value != Q ]] || return 1
        value=${value:-$fallback}
        if [[ $value =~ ^[1-9][0-9]{0,6}$ ]] && ((value <= maximum)); then
            printf -v "$variable" '%s' "$value"
            return 0
        fi
        printf '%s\n' "$(message "Введите целое число от 1 до $maximum." "Enter an integer from 1 to $maximum.")"
    done
}

log_settings_interactive() { [[ -t 0 ]]; }

compose_logging_override() {
    local service
    printf 'services:\n'
    for service in "$@"; do
        printf "  '%s':\n    logging:\n      driver: json-file\n      options:\n        max-size: '%sm'\n        max-file: '%s'\n" "$service" "$docker_log_mib" "$docker_log_files"
    done
}

compose_logging_model() {
    python3 -c '
import json
import sys

size, files, mode, *services = sys.argv[1:]
before, _, after = sys.stdin.buffer.read().partition(b"\0")
model = json.loads(before)
limits = {"max-size": size + "m", "max-file": files}
pending = []
for name in services:
    service = model["services"][name]
    logging = service.get("logging")
    if logging is None:
        service["logging"] = {"driver": "json-file", "options": limits}
        pending.append(name)
    elif logging.get("driver") != "json-file":
        sys.exit(1)
    elif any(
        logging.get("options", {}).get(key) != value for key, value in limits.items()
    ):
        logging.setdefault("options", {}).update(limits)
        pending.append(name)
if mode == "pending":
    sys.stdout.buffer.write("\n".join(pending).encode())
elif mode == "verify":
    sys.exit(model != json.loads(after))
else:
    sys.exit(bool(pending))
' "$docker_log_mib" "$docker_log_files" "$@"
}

save_compose_logging() (
    local project=$1 directory=$2 base=$3 temporary= backup before after pending discovered
    shift 3
    local -a compose=(compose --project-name "$project" --project-directory "$directory")
    backup=$operation_dir/compose.before.yml
    local config_target=$base config_backup=$backup config_original config_expected=
    local config_pending=0 config_committed=0 config_restart=0
    trap 'finish_config_change "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ -f $base && ! -L $base ]] || return 1
    config_original=$(stat -c '%d:%i:%s:%y' -- "$base") || return 1
    cp -p -- "$base" "$backup" || return 1
    before=$(docker_local "${compose[@]}" -f "$base" config --format json) || return 1
    if ! pending=$(printf '%s' "$before" | compose_logging_model pending "$@"); then
        printf '%s\n' "$(message 'В основном файле уже задана другая конфигурация логирования. Проверьте её вручную.' \
            'The main file already defines different logging settings. Review it manually.')" >&2
        return 1
    fi
    if [[ -z $pending ]]; then
        discovered=$(docker_local "${compose[@]}" config --format json) && [[ $discovered == "$before" ]] || return 1
        printf '%s\n' "$(message 'Лимиты уже заданы в основном файле.' 'The limits are already in the main file.')"
        return 0
    fi
    temporary=$(mktemp -- "$directory/.server-auditor.logging.XXXXXXXX") || return 1
    if ! awk -v pending="$pending" -v size="$docker_log_mib" -v files="$docker_log_files" '
        BEGIN { n=split(pending, names, "\n"); for (i=1; i<=n; i++) wanted[names[i]]=1 }
        /^[^ #]/ { services=($0 ~ /^services:[[:space:]]*(#.*)?$/) }
        {
            if (skip && ($0 ~ /^    [^ ]/ || $0 ~ /^  [^ ]/ || $0 ~ /^[^ #]/)) skip=0
            if (skip && ($0 ~ /^      / || $0 ~ /^[[:space:]]*$/)) next
            if (services && wanted[current] && $0 ~ /^    logging:[[:space:]]*$/) { skip=1; next }
            print
            if (services && $0 ~ /^  [[:alnum:]_.-]+:[[:space:]]*(#.*)?$/) {
                name=$0; sub(/^  /, "", name); sub(/:.*/, "", name)
                current=name
                if (wanted[name]) {
                    found++
                    print "    logging:"
                    print "      driver: json-file"
                    print "      options:"
                    print "        max-size: \"" size "m\""
                    print "        max-file: \"" files "\""
                }
            }
        }
        END { exit found != n }
    ' "$backup" > "$temporary"; then
        printf '%s\n' "$(message 'Структура Compose-файла требует ручного редактирования.' \
            'This Compose file layout requires a manual edit.')" >&2
        return 1
    fi
    after=$(docker_local "${compose[@]}" -f "$temporary" config --format json) || return 1
    if ! printf '%s\0%s' "$before" "$after" | compose_logging_model verify "$@"; then
        printf '%s\n' "$(message 'Итоговая конфигурация отличается не только лимитами. Файл сохранён без изменений.' \
            'The resolved configuration differs beyond log limits. The original file was kept.')" >&2
        return 1
    fi
    diff -U0 -- "$backup" "$temporary" || [[ $? == 1 ]] || return 1
    chmod --reference="$backup" -- "$temporary" && chown --reference="$backup" -- "$temporary" &&
        printf 'compose=%q\nbackup=%q\n' "$base" "$backup" >> "$logfile" &&
        sync -- "$backup" "$temporary" "$logfile" "$operation_dir" &&
        [[ $(stat -c '%d:%i:%s:%y' -- "$base") == "$config_original" ]] &&
        cmp -s -- "$base" "$backup" || return 1
    config_expected=$(stat -c '%d:%i:%s:%y' -- "$temporary") || return 1
    config_pending=1
    mv -fT -- "$temporary" "$base" || return 1
    if discovered=$(docker_local "${compose[@]}" config --format json) && [[ $discovered == "$after" ]]; then
        sync -- "$base" "$directory" || return 1
        write_config_restore_metadata compose "$base" "$backup" "$project" || return 1
        config_committed=1
        printf '%s\n' "$(message "Лимиты сохранены в $base и видны Compose без -f." "Limits saved in $base and visible to Compose without -f.")"
        return 0
    fi
    printf '%s\n' "$(message 'Compose без -f видит другую конфигурацию. Восстанавливаю исходный файл.' \
        'Compose without -f sees a different configuration. Restoring the original file.')" >&2
    return 1
)

compose_logging_state() {
    local id=$1
    docker_local inspect --type container --format \
        '{{.State.Status}}|{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}|{{index .HostConfig.LogConfig.Config "max-file"}}' "$id"
}

apply_compose_logging() {
    local project=$1 directory=$2 base=$3 service id state model fingerprint current
    shift 3
    local -a compose=(compose --project-name "$project" --project-directory "$directory" -f "$base")
    local -a pending=()
    fingerprint=$(stat -c '%d:%i:%s:%y:%z' -- "$base") || return 1
    model=$(docker_local "${compose[@]}" config --format json) &&
        printf '%s' "$model" | compose_logging_model check "$@" || return 1
    for service in "$@"; do
        id=$(docker_local "${compose[@]}" ps --all --quiet "$service") || return 1
        if ! [[ $id =~ ^[a-f0-9]{12,64}$ ]] ||
            ! state=$(compose_logging_state "$id") || [[ $state != running\|* ]]; then
            printf '%s\n' "$(message "$service: нужен один запущенный контейнер. Применение остановлено." \
                "$service: exactly one running container is required. Application stopped.")" >&2
            return 1
        fi
        if [[ $state == "running|json-file|${docker_log_mib}m|$docker_log_files" ]]; then
            printf '%s\n' "$(message "$service: нужные лимиты уже действуют." "$service: the desired limits are already active.")"
        else
            pending+=("$service")
        fi
    done
    for service in "${pending[@]}"; do
        current=$(docker_local "${compose[@]}" config --format json) || return 1
        if [[ $current != "$model" || $(stat -c '%d:%i:%s:%y:%z' -- "$base") != "$fingerprint" ]]; then
            printf '%s\n' "$(message 'Конфигурация Compose изменилась во время проверки. Применение остановлено.' \
                'Compose configuration changed during validation. Application stopped.')" >&2
            return 1
        fi
        docker_local_write "${compose[@]}" up -d --no-deps --no-build --pull never "$service" || return 1
        id=$(docker_local "${compose[@]}" ps --all --quiet "$service") || return 1
        if ! [[ $id =~ ^[a-f0-9]{12,64}$ ]] ||
            ! state=$(compose_logging_state "$id") || [[ $state != "running|json-file|${docker_log_mib}m|$docker_log_files" ]]; then
            printf '%s\n' "$(message "$service: состояние или лимиты не подтверждены. Применение остановлено." \
                "$service: running state or log limits could not be verified. Application stopped.")" >&2
            return 1
        fi
        printf '%s\n' "$(message "$service: запущен, подтверждены json-file, $docker_log_mib МиБ × $docker_log_files." \
            "$service: running, verified json-file, $docker_log_mib MiB × $docker_log_files.")"
    done
}

prepare_compose_logging() {
    local docker_log_mib=10 docker_log_files=3
    local container metadata service project directory base driver answer available
    local listing id name state number count=0 legacy_override
    local selected_project= selected_directory= selected_base=
    local -a selection=() containers=() services=()
    local -A seen=() listed=()
    if ! has python3; then
        printf '%s\n' "$(message 'Для сравнения конфигураций Compose нужен Python 3.' \
            'Python 3 is required to compare Compose configurations.')" >&2
        return 1
    fi
    if ! listing=$(docker_local container ls -a --no-trunc --format '{{.ID}}|{{.Names}}|{{.State}}'); then
        printf '%s\n' "$(message 'Не удалось получить список локальных контейнеров.' \
            'Could not list local containers.')" >&2
        return 1
    fi
    printf '\n%s\n' "$(message 'Локальные контейнеры:' 'Local containers:')"
    while IFS='|' read -r id name state; do
        [[ $id =~ ^[a-f0-9]{64}$ && $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || continue
        case $state in
            running) state=$(message 'запущен' running) ;;
            exited) state=$(message 'остановлен' exited) ;;
            paused) state=$(message 'приостановлен' paused) ;;
            created) state=$(message 'создан' created) ;;
            restarting) state=$(message 'перезапускается' restarting) ;;
            removing) state=$(message 'удаляется' removing) ;;
            dead) state=$(message 'неработоспособен' dead) ;;
            *) state=$(message 'состояние неизвестно' unknown) ;;
        esac
        count=$((count + 1))
        listed[$count]=$id
        printf '  %d. %s (%s) — %s\n' "$count" "$name" "${id:0:12}" "$state"
    done <<< "$listing"
    if (( ! count )); then
        printf '%s\n' "$(message 'Контейнеров нет.' 'No containers found.')"
        return 0
    fi
    printf '%s' "$(message 'Введите номера контейнеров одного проекта через пробел (0 или Enter — отмена): ' \
        'Enter container numbers from one project separated by spaces (0 or Enter to cancel): ')"
    read -r -a selection || return 0
    (( ${#selection[@]} )) || return 0
    if [[ ${#selection[@]} == 1 && ${selection[0]} == 0 ]]; then return 0; fi
    for number in "${selection[@]}"; do
        if ! [[ $number =~ ^[1-9][0-9]*$ && -n ${listed[$number]:-} ]]; then
            printf '%s\n' "$(message 'Выберите номера из списка.' 'Choose numbers from the list.')" >&2
            return 1
        fi
        containers+=("${listed[$number]}")
    done
    for container in "${containers[@]}"; do
        metadata=$(docker_local inspect --type container --format \
            '{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{.HostConfig.LogConfig.Type}}' "$container") || return 1
        [[ $metadata != *$'\n'* ]] || return 1
        IFS='|' read -r service project directory base driver <<< "$metadata"
        if ! [[ $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ && $project =~ ^[a-z0-9][a-z0-9_-]*$ &&
            $directory == /* && $base == /* && $driver == json-file ]]; then
            printf '%s\n' "$(message 'Нужен контейнер json-file из проекта Compose с одним исходным файлом.' \
                'A json-file container in a Compose project with one source file is required.')" >&2
            return 1
        fi
        if [[ $base == *,* ]]; then
            legacy_override=${base#*,}
            base=${base%%,*}
            if [[ $legacy_override != "$directory/server-auditor.logging.yml" ]]; then
                printf '%s\n' "$(message 'Проект использует другие дополнительные Compose-файлы. Требуется ручное изменение.' \
                    'The project uses other additional Compose files. A manual edit is required.')" >&2
                return 1
            fi
        fi
        [[ ! -L $base ]] || return 1
        directory=$(realpath -e -- "$directory") && base=$(realpath -e -- "$base") || return 1
        [[ -f $base && ${base%/*} == "$directory" ]] && trusted_directory "$directory" || return 1
        if [[ -z $selected_project ]]; then
            selected_project=$project selected_directory=$directory selected_base=$base
        elif [[ $project != "$selected_project" || $directory != "$selected_directory" || $base != "$selected_base" ]]; then
            printf '%s\n' "$(message 'Выберите контейнеры одного проекта Compose.' 'Choose containers from one Compose project.')" >&2
            return 1
        fi
        if [[ -z ${seen[$service]:-} ]]; then
            seen[$service]=1
            services+=("$service")
        fi
    done
    available=$(docker_local compose --project-name "$selected_project" --project-directory "$selected_directory" \
        -f "$selected_base" config --services) || return 1
    for service in "${services[@]}"; do
        if ! grep -Fxq -- "$service" <<< "$available"; then
            printf '%s\n' "$(message "Сервис $service отсутствует в текущей конфигурации Compose." \
                "Service $service is missing from the current Compose configuration.")" >&2
            return 1
        fi
    done
    if log_settings_interactive; then
        choose_log_number docker_log_mib 10 1048576 "$(message 'Размер одного Docker-лога, МиБ' 'Size of one Docker log, MiB')" || return 0
        choose_log_number docker_log_files 3 1000 "$(message 'Число файлов Docker (включая текущий)' 'Docker file count (including current)')" || return 0
    fi
    printf '%s\n' "$(message "Ориентир на контейнер: $((docker_log_mib * docker_log_files)) МиБ. Общие слои и другие данные сюда не входят." \
        "Per-container guide: $((docker_log_mib * docker_log_files)) MiB. Other data is excluded.")"
    printf '\n%s\n' "$selected_base"
    compose_logging_override "${services[@]}"
    printf '%s' "$(message 'Проверить и записать лимиты в основной Compose-файл? [д/Н] ' \
        'Validate and write the limits to the main Compose file? [y/N] ')"
    IFS= read -r answer || return 0
    case $answer in y|Y|yes|YES|д|Д|да|Да|ДА) ;; *) return 0 ;; esac
    run_logged_maintenance compose-logging save_compose_logging \
        "$selected_project" "$selected_directory" "$selected_base" "${services[@]}" || return 1
    printf '%s\n' "$(message 'Сервисы для применения:' 'Services selected for application:')" "${services[@]}"
    printf '%s' "$(message 'Применить лимиты сейчас? Compose может пересоздать контейнеры, кратко прервав работу. [д/Н] ' \
        'Apply the limits now? Compose may recreate containers, briefly interrupting service. [y/N] ')"
    IFS= read -r answer || return 0
    case $answer in y|Y|yes|YES|д|Д|да|Да|ДА) ;; *) return 0 ;; esac
    run_logged_maintenance compose-logging-apply apply_compose_logging \
        "$selected_project" "$selected_directory" "$selected_base" "${services[@]}"
}

load_config_restore() {
    local entry=$1 field
    local -a fields=()
    [[ -d $entry && ! -L $entry && -f $entry/restore.info && ! -L $entry/restore.info ]] &&
        trusted_directory "$entry" || return 1
    [[ -f $entry/history.log && ! -L $entry/history.log &&
        $(tail -n 1 -- "$entry/history.log") == exit_status=0 ]] || return 1
    while IFS= read -r -d '' field; do
        fields+=("$field")
        if (( ${#fields[@]} > 7 )); then return 1; fi
    done < "$entry/restore.info"
    [[ ${#fields[@]} == 7 && ${fields[0]} == 1 ]] || return 1
    restore_kind=${fields[1]} restore_target=${fields[2]} restore_backup=$entry/${fields[3]}
    restore_before_hash=${fields[4]} restore_after_hash=${fields[5]} restore_project=${fields[6]}
    [[ $restore_after_hash =~ ^[a-f0-9]{64}$ &&
        ( $restore_before_hash == - || $restore_before_hash =~ ^[a-f0-9]{64}$ ) ]] || return 1
    case $restore_kind in
        journald) [[ $restore_target == "$journal_dropin" && ${fields[3]} == journald.conf.before ]] || return 1 ;;
        rsyslog) [[ $restore_target == "$rsyslog_rule" && ${fields[3]} == rsyslog.conf.before && $restore_before_hash != - ]] || return 1 ;;
        logrotate)
            [[ ( $restore_target == "$logrotate_config" || ${restore_target%/*} == "$logrotate_rules_directory" ) &&
                ${fields[3]} == logrotate.conf.before && $restore_before_hash != - ]] || return 1 ;;
        compose)
            case ${restore_target##*/} in compose.yml|compose.yaml|docker-compose.yml|docker-compose.yaml) ;; *) return 1 ;; esac
            [[ $restore_project =~ ^[a-z0-9][a-z0-9_-]*$ && ${fields[3]} == compose.before.yml &&
                $restore_before_hash != - ]] || return 1 ;;
        *) return 1 ;;
    esac
    [[ $restore_target == /* && -f $restore_target && ! -L $restore_target ]] &&
        trusted_directory "${restore_target%/*}" || return 1
    if [[ $restore_before_hash != - ]]; then
        [[ -f $restore_backup && ! -L $restore_backup ]] &&
            [[ $(file_sha256 "$restore_backup") == "$restore_before_hash" ]] || return 1
    else
        [[ ! -e $restore_backup && ! -L $restore_backup ]] || return 1
    fi
}

restore_config_from_history() (
    local restore_kind restore_target restore_backup restore_before_hash restore_after_hash restore_project
    load_config_restore "$1" || return 1
    if [[ $(file_sha256 "$restore_target") != "$restore_after_hash" ]]; then
        printf '%s\n' "$(message 'Текущий файл изменился после исходной операции. Автовосстановление остановлено.' \
            'The current file changed after the original operation. Automatic restoration stopped.')" >&2
        return 1
    fi
    local config_target=$restore_target config_backup=$operation_dir/restore.before config_original config_expected=
    local config_pending=0 config_committed=0 config_restart=0 temporary=
    trap 'finish_config_change "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    config_original=$(stat -c '%d:%i:%s:%y' -- "$config_target") || return 1
    cp -p -- "$config_target" "$config_backup" &&
        [[ $(file_sha256 "$config_backup") == "$restore_after_hash" ]] &&
        printf 'restored_from=%q\nconfig=%q\nbackup=%q\n' "$1" "$config_target" "$config_backup" >> "$logfile" &&
        sync -- "$config_backup" "$logfile" "$operation_dir" || return 1
    temporary=$(mktemp -- "$config_target.XXXXXXXX") || return 1
    if [[ $restore_before_hash != - ]]; then
        cp -p -- "$restore_backup" "$temporary" &&
            [[ $(file_sha256 "$temporary") == "$restore_before_hash" ]] &&
            sync -- "$temporary" || return 1
        config_expected=$(stat -c '%d:%i:%s:%y' -- "$temporary") || return 1
    else
        config_expected=absent
    fi
    [[ $(file_sha256 "$config_target") == "$restore_after_hash" &&
        $(stat -c '%d:%i:%s:%y' -- "$config_target") == "$config_original" ]] || return 1
    config_pending=1
    if [[ $restore_before_hash == - ]]; then rm -- "$config_target" || return 1
    else mv -fT -- "$temporary" "$config_target" || return 1; fi
    case $restore_kind in
        journald)
            systemd-analyze --no-pager cat-config systemd/journald.conf >/dev/null || return 1
            config_restart=1
            systemctl restart systemd-journald.service || return 1 ;;
        rsyslog|logrotate) logrotate -d "$logrotate_config" >/dev/null || return 1 ;;
        compose)
            docker_local compose --project-name "$restore_project" --project-directory "${restore_target%/*}" \
                -f "$restore_target" config --quiet || return 1 ;;
    esac
    sync -- "${config_target%/*}" || return 1
    config_committed=1
    printf '%s\n' "$(message "Восстановлена конфигурация: $config_target" "Configuration restored: $config_target")"
    if [[ $restore_kind == compose ]]; then
        printf '%s\n' "$(message 'Настройки Compose вступят в силу при следующем пересоздании сервисов.' \
            'Compose settings take effect when services are next recreated.')"
    fi
)

choose_config_restore() {
    local listing entry label choice index answer diff_source
    local restore_kind restore_target restore_backup restore_before_hash restore_after_hash restore_project
    local -a entries=() labels=()
    if [[ ! -d $maintenance_state ]]; then
        printf '%s\n' "$(message 'Операций для восстановления пока нет.' 'No operations are available for restoration.')"
        return 0
    fi
    listing=$(find "$maintenance_state" -mindepth 2 -maxdepth 2 -name restore.info -type f -print | sort -r) || return 1
    while IFS= read -r entry; do
        [[ -n $entry ]] || continue
        entry=${entry%/*}
        [[ ${entry##*/} =~ ^[0-9]{8}T[0-9]{6}Z\.[a-zA-Z0-9]+$ ]] || continue
        if load_config_restore "$entry"; then
            entries+=("$entry")
            printf -v label '%q' "$restore_target"
            labels+=("${entry##*/} · $restore_kind · $label")
        fi
        if (( ${#entries[@]} == 10 )); then break; fi
    done <<< "$listing"
    if (( ${#entries[@]} == 0 )); then
        printf '%s\n' "$(message 'Подходящих новых записей нет. Резервные копии старых операций доступны для ручного восстановления.' \
            'No eligible new entries. Backups from older operations can be restored manually.')"
        return 0
    fi
    for index in "${!entries[@]}"; do printf '  %d. %s\n' "$((index + 1))" "${labels[index]}"; done
    printf '%s' "$(message 'Выберите номер операции (0 или Enter — отмена): ' \
        'Choose an operation number (0 or Enter to cancel): ')"
    IFS= read -r choice || return 0
    [[ -n $choice && $choice != 0 ]] || return 0
    for index in "${!entries[@]}"; do
        if [[ $choice != "$((index + 1))" ]]; then continue; fi
        entry=${entries[index]}
        load_config_restore "$entry" || return 1
        [[ $(file_sha256 "$restore_target") == "$restore_after_hash" ]] || {
            printf '%s\n' "$(message 'Текущий файл изменился. Сравните его с резервной копией вручную.' \
                'The current file changed. Compare it with the backup manually.')" >&2
            return 1
        }
        diff_source=$restore_backup
        if [[ $restore_before_hash == - ]]; then diff_source=/dev/null; fi
        diff -U0 -- "$restore_target" "$diff_source" || [[ $? == 1 ]] || return 1
        if [[ $restore_kind == journald ]]; then
            printf '%s\n' "$(message 'Служба journald будет перезапущена. Прежние лимиты хранения могут привести к удалению старых записей.' \
                'Journald will be restarted. Previous retention limits may delete older entries.')"
        elif [[ $restore_kind == compose ]]; then
            printf '%s\n' "$(message 'Настройки Compose вступят в силу при следующем пересоздании сервисов.' \
                'Compose settings take effect when services are next recreated.')"
        fi
        printf '%s' "$(message 'Восстановить эту конфигурацию? [д/Н] ' 'Restore this configuration? [y/N] ')"
        IFS= read -r answer || return 0
        case $answer in y|Y|yes|YES|д|Д|да|Да|ДА) ;; *) return 0 ;; esac
        run_logged_maintenance restore-config restore_config_from_history "$entry"
        return
    done
    printf '%s\n' "$(message 'Выберите номер из списка.' 'Choose a number from the list.')" >&2
    return 1
}

show_maintenance_history() {
    local listing logfile directory action started result status choice index
    local -a entries=()
    if [[ ! -d $maintenance_state ]]; then
        printf '%s\n' "$(message 'История операций пока пуста.' 'No operations have been recorded yet.')"
        return 0
    fi
    listing=$(find "$maintenance_state" -mindepth 2 -maxdepth 2 -name history.log -type f -print | sort -r) || return 1
    while IFS= read -r logfile; do
        [[ -n $logfile ]] || continue
        directory=${logfile%/*}
        [[ ${directory##*/} =~ ^[0-9]{8}T[0-9]{6}Z\.[a-zA-Z0-9]+$ ]] || continue
        entries+=("$logfile")
        if (( ${#entries[@]} == 10 )); then break; fi
    done <<< "$listing"
    if (( ${#entries[@]} == 0 )); then
        printf '%s\n' "$(message 'История операций пока пуста.' 'No operations have been recorded yet.')"
        return 0
    fi
    printf '\n%s\n' "$(message 'Последние операции (UTC):' 'Recent operations (UTC):')"
    for index in "${!entries[@]}"; do
        logfile=${entries[index]}
        action=$(sed -n '1s/^action=\([a-z-][a-z-]*\)$/\1/p; 1q' "$logfile")
        started=$(sed -n '2s/^started=\([0-9TZ:-][0-9TZ:-]*\)$/\1/p; 2q' "$logfile")
        result=$(tail -n 1 -- "$logfile")
        if [[ $result =~ ^exit_status=([0-9]+)$ ]]; then
            status=$(message "код выхода ${BASH_REMATCH[1]}" "exit code ${BASH_REMATCH[1]}")
        else
            status=$(message 'результат ещё не записан' 'result not recorded yet')
        fi
        if tail -n 3 -- "$logfile" | grep -Eq '^recording_status=(incomplete|interrupted)$'; then
            status+=" · $(message 'история неполная или прервана' 'history incomplete or interrupted')"
        fi
        printf '  %d. %s · %s · %s\n' "$((index + 1))" "${started:-?}" "${action:-?}" "$status"
    done
    while :; do
        printf '%s' "$(message 'Номер записи (0 или Enter — назад): ' 'History entry number (0 or Enter to go back): ')"
        IFS= read -r choice || return 0
        [[ -n $choice && $choice != 0 ]] || return 0
        for index in "${!entries[@]}"; do
            if [[ $choice == "$((index + 1))" ]]; then
                logfile=${entries[index]}
                printf '\n=== %s ===\n' "$logfile"
                awk '{
                    sub(/\r$/, "")
                    sub(/^.*\r/, "")
                    gsub(/[[:cntrl:]]/, "")
                    print
                }' "$logfile" || return 1
                printf '\n'
                continue 2
            fi
        done
        printf '%s\n' "$(message 'Выберите номер из списка.' 'Choose a number from the list.')"
    done
}

docker_cleanup_inventory() {
    local images containers image_data='' container_data='' id
    local -a image_ids=() container_ids=()
    has python3 || { message 'Нужен Python 3.' 'Python 3 is required.'; return 1; }
    images=$(docker_local image ls --all --quiet --no-trunc) || return 1
    containers=$(docker_local container ls --all --quiet --no-trunc) || return 1
    while IFS= read -r id; do
        [[ -z $id ]] && continue
        [[ $id =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
        image_ids+=("$id")
    done <<< "$images"
    while IFS= read -r id; do
        [[ -z $id ]] && continue
        [[ $id =~ ^[a-f0-9]{64}$ ]] || return 1
        container_ids+=("$id")
    done <<< "$containers"
    if ((${#image_ids[@]})); then
        image_data=$(docker_local image inspect --format \
            '[{{json .Id}},{{json .Size}},{{json .RepoTags}},{{json .RepoDigests}}]' "${image_ids[@]}") || return 1
    fi
    if ((${#container_ids[@]})); then
        container_data=$(docker_local container inspect --format \
            '[{{json .Image}},{{json .Name}},{{json .State.Status}}]' "${container_ids[@]}") || return 1
    fi
    printf '%s\0%s' "$image_data" "$container_data" | python3 -c '
import json, re, sys
images, containers = sys.stdin.read().split("\0")
refs = {}
for line in containers.splitlines():
    image, name, state = json.loads(line)
    refs.setdefault(image, []).append([name.lstrip("/"), state])
rows = {}
for line in images.splitlines():
    image, size, tags, digests = json.loads(line)
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", image) or type(size) is not int or size < 0:
        raise ValueError("Invalid image metadata")
    tags, digests = sorted(tags or []), sorted(digests or [])
    if not all(isinstance(s, str) for s in tags + digests):
        raise ValueError("Invalid image references")
    used = sorted(refs.get(image, []))
    eligible = not used and len(tags) <= 1
    rows[image] = "\t".join([image, str(size), str(int(eligible)), json.dumps(tags, ensure_ascii=True), json.dumps(used, ensure_ascii=True), json.dumps(digests, ensure_ascii=True)])
for image in sorted(rows):
    print(rows[image])
'
}

remove_docker_image() {
    local expected=$1 inventory row id size eligible tags refs digests found=0
    IFS=$'\t' read -r id size eligible tags refs digests <<< "$expected"
    [[ $id =~ ^sha256:[a-f0-9]{64}$ && $eligible == 1 ]] || return 1
    inventory=$(docker_cleanup_inventory) || return 1
    while IFS= read -r row; do [[ $row == "$expected" ]] && found=1; done <<< "$inventory"
    if (( ! found )); then
        message 'Образ изменился или используется. Обновите список.' 'Image changed or is in use. Refresh the list.'
        return 1
    fi
    printf 'image_id=%s\nimage_tags=%s\nimage_digests=%s\nimage_size_bytes=%s\nbackup=none\n' "$id" "$tags" "$digests" "$size" >> "$logfile" || return 1
    sync -- "$logfile" || return 1
    docker_local_write image rm --no-prune "$id" || return 1
    inventory=$(docker_cleanup_inventory) || return 1
    while IFS=$'\t' read -r row _; do [[ $row != "$id" ]] || return 1; done <<< "$inventory"
    printf 'image_deleted=%s\n' "$id"
}

prune_docker_builder() {
    local age=$1
    [[ $age == 168h || $age == 720h ]] || return 1
    printf 'builder=local-engine\ncache_filter=until=%s\n' "$age" >> "$logfile" || return 1
    sync -- "$logfile" || return 1
    # Keep Docker native confirmation. --force is deliberately not used.
    docker_local_write builder prune --all --filter "until=$age"
}

docker_cleanup_menu() {
    local choice inventory row id size eligible tags refs digests number answer age
    local -a rows=()
    has docker || { message 'Docker CLI недоступен.' 'Docker CLI unavailable.'; return 1; }
    while :; do
        printf '\n%s\n' "$(message 'Очистка Docker — локальный сервер' 'Docker cleanup — local engine')" \
            "${menu_number[docker-images]}. $(menu_title docker-images)" \
            "${menu_number[docker-cache]}. $(menu_title docker-cache)" \
            "$(message '0. Назад' '0. Back')"
        IFS= read -r choice || return 0
        case $choice in
            0|'') return 0 ;;
            "${menu_number[docker-images]}")
                inventory=$(docker_cleanup_inventory) || return 1
                rows=(); number=0
                while IFS= read -r row; do
                    [[ -n $row ]] || continue
                    rows+=("$row"); ((number+=1))
                    IFS=$'\t' read -r id size eligible tags refs digests <<< "$row"
                    if [[ $refs != '[]' ]]; then
                        safety_line keep "$number. $tags · ${id:7:12} · $(human_bytes "$size") · $refs"
                    else
                        safety_line review "$number. $tags · ${id:7:12} · $(human_bytes "$size") · $digests"
                        [[ $eligible == 1 ]] || message '  Несколько тегов. Автоматическое удаление недоступно.' '  Multiple tags. Automatic removal unavailable.'
                    fi
                done <<< "$inventory"
                ((${#rows[@]})) || { message 'Образов нет.' 'No images.'; continue; }
                message 'Размеры включают общие слои и не равны освобождаемому месту. Неиспользуемый образ может понадобиться для отката.' \
                    'Sizes include shared layers and are not reclaim estimates. Unused images may be needed for rollback.'
                message 'Номер образа (0 или Enter — назад):' 'Image number (0 or Enter to go back):'
                IFS= read -r choice || return 0
                [[ -z $choice || $choice == 0 ]] && continue
                [[ $choice =~ ^[1-9][0-9]{0,5}$ ]] && ((choice <= ${#rows[@]})) || continue
                row=${rows[choice-1]}
                IFS=$'\t' read -r id size eligible tags refs digests <<< "$row"
                [[ $eligible == 1 ]] || { message 'Удаление заблокировано.' 'Removal blocked.'; continue; }
                printf '%s\n' "$id · $tags · $digests"
                message 'Удалить образ без резервной копии? Для восстановления потребуется загрузка или сборка. [д/Н]' \
                    'Remove without a backup? Recovery requires pulling or rebuilding. [y/N]'
                IFS= read -r answer || return 0
                case $answer in y|Y|yes|д|Д|да) run_logged_maintenance docker-image remove_docker_image "$row" || return 1 ;; esac ;;
            "${menu_number[docker-cache]}")
                docker_local system df || return 1
                message 'Кэш только встроенного builder Docker Engine. Отдельные Buildx builders здесь не очищаются. Оценка Docker может включать общие слои.' \
                    'Only the Docker Engine built-in builder cache. Separate Buildx builders are not cleaned here. Docker estimates may include shared layers.'
                message 'Удаление кэша замедлит следующие сборки. 1 — старше 7 дней, 2 — старше 30 дней, 0 — назад:' \
                    'Cache removal slows subsequent builds. 1 — older than 7 days, 2 — older than 30 days, 0 — back:'
                IFS= read -r choice || return 0
                case $choice in 1) age=168h ;; 2) age=720h ;; *) continue ;; esac
                message 'Далее Docker запросит подтверждение. Точный список удаляемого кэша заранее недоступен.' \
                    'Docker will ask for confirmation. An exact cache deletion preview is unavailable.'
                run_logged_maintenance docker-cache prune_docker_builder "$age" || return 1 ;;
        esac
    done
}

maintenance_log_status() (
    local action=$1 expected current
    local format=txt details=1 overview_group=0 checks=0 warnings=0 critical=0 unknown=0
    printf '\n=== %s ===\n' "$(message 'Текущее состояние перед действием' 'Current state before action')"
    case $action in
        rotate|vacuum|limit|journal-status)
            journal_check
            if has journalctl; then journalctl --disk-usage || true; fi
            printf '%s\n' "$(message 'Показаны настройки на диске. Они могут отличаться от загруженных службой.' \
                'These are settings on disk. Loaded service settings may differ.')"
            case $action in
                rotate) printf '%s\n' "$(message 'Ротация переводит активные файлы в архив. Постоянные лимиты не меняются.' \
                    'Rotation archives active files. Persistent limits are unchanged.')" ;;
                vacuum) printf '%s\n' "$(message 'Очистка удаляет старые архивные записи до целевого объёма. Постоянные лимиты не меняются.' \
                    'Vacuuming removes old archived entries toward the target size. Persistent limits are unchanged.')" ;;
                limit) printf '%s\n' "$(message 'Настройка предложит выбрать общий объём для каждого хранилища и перезапустит journald.' \
                    'Configuration lets you choose the total size per storage location and restarts journald.')" ;;
            esac ;;
        rsyslog-policy)
            local rsyslog_custom=1
            printf '%s\n' "$(message "Файл правила: $rsyslog_rule" "Rule file: $rsyslog_rule")"
            if [[ -f $rsyslog_rule && ! -L $rsyslog_rule ]] && current=$(cat -- "$rsyslog_rule"); then
                printf '%s\n' "$current"
                if expected=$(rsyslog_policy "$rsyslog_rule"); then
                    if [[ $current == "$expected" ]]; then
                        printf '%s\n' "$(message 'Уже настроено: daily и maxsize 100M. Ниже можно выбрать другие параметры.' \
                            'Already configured: daily and maxsize 100M. You can choose different settings below.')"
                    else
                        printf '%s\n' "$(message 'Правило существует, но профиль daily + maxsize 100M ещё не настроен.' \
                            'A rule exists, but the daily + maxsize 100M profile is not configured yet.')"
                    fi
                else
                    printf '%s\n' "$(message 'Нестандартное правило: автоматическая настройка не поддерживается.' \
                        'Custom rule: automatic configuration is unsupported.')"
                fi
            else
                printf '%s\n' "$(message 'Штатное правило rsyslog отсутствует или недоступно. Этот пункт не настраивает Nginx, UFW и другие приложения.' \
                    'The standard rsyslog rule is absent or inaccessible. This action does not configure Nginx, UFW or other applications.')"
            fi
            printf '%s\n' "$(message 'Можно выбрать порог размера и число архивов. Сжатие и служебные команды сохраняются.' \
                'You can select the size threshold and archive count. Compression and hooks are preserved.')"
            logrotate_check
            logrotate_timer_check ;;
        logrotate)
            logrotate_check
            logrotate_timer_check
            printf '%s\n' "$(message 'Этот пункт не настраивает ограничения: он показывает план и запускает существующие правила.' \
                'This action does not configure limits: it previews and runs existing rules.')"
            printf '%s\n' "$(message "Настройка: $(menu_path rsyslog-policy) для rsyslog; редактор блоков других приложений: $(menu_path logrotate-editor); ручная инструкция: $(menu_path logrotate-guide)." \
                "Configuration: $(menu_path rsyslog-policy) for rsyslog; other application block editor: $(menu_path logrotate-editor); manual guide: $(menu_path logrotate-guide).")"
            printf '%s\n' "$(message 'Пример параметров внутри существующего блока: daily, maxsize 100M, rotate 4, compress. Затем проверьте конфигурацию в этом пункте.' \
                'Example settings inside an existing block: daily, maxsize 100M, rotate 4, compress. Then validate the configuration using this action.')"
            printf '%s\n' "$(message 'maxsize проверяется только при запуске logrotate. Общий лимит /var/log этим не задаётся.' \
                'maxsize is checked only when logrotate runs. This does not set a shared /var/log cap.')" ;;
    esac
)

logrotate_rule_model() {
    python3 - "$@" <<'PY'
import json, pathlib, re, shlex, sys
mode, source, *args = sys.argv[1:]
raw = pathlib.Path(source).read_bytes()
text = raw.decode('utf-8', 'surrogateescape')
lines = text.splitlines(keepends=True)
blocks, pending, opening, directives, script = [], [], None, [], False
scripts = {'prerotate', 'postrotate', 'firstaction', 'lastaction', 'preremove'}
try:
    for n, line in enumerate(lines):
        s = line.strip()
        if opening is not None:
            if script:
                if s == 'endscript': script = False
                continue
            if s in scripts:
                script = True
                continue
            if s == '}':
                blocks.append((opening, n, header, directives))
                opening, directives = None, []
                continue
            if not s or s.startswith('#'): continue
            if '{' in s or '}' in s: raise ValueError('nested or inline braces')
            tokens = shlex.split(s, comments=True)
            if tokens and tokens[0] in scripts:
                if len(tokens) != 1: raise ValueError('ambiguous script directive')
                script = True
                continue
            if tokens and tokens[0] == 'include': raise ValueError('include inside block')
            directives.append((n, tokens))
            continue
        if not s or s.startswith('#'): continue
        if s.endswith('{'):
            head = s[:-1].strip()
            if head: pending.append(head)
            header = ' '.join(pending)
            paths = shlex.split(header, comments=True)
            if not paths or not all(p.startswith('/') for p in paths):
                raise ValueError('only absolute log paths are supported')
            opening, pending = n, []
        elif s.startswith('/') or s.startswith('"'):
            pending.append(s)
        elif pending:
            raise ValueError('ambiguous multiline header')
    if opening is not None or script or pending: raise ValueError('unfinished block')
    if mode == 'list':
        for i, (_, _, header, _) in enumerate(blocks, 1):
            print(str(i) + '\t' + json.dumps(header, ensure_ascii=True))
    else:
        selected = int(args[0])
        start, end, header, directives = blocks[selected - 1]
        if selected < 1: raise ValueError('invalid block')
        if mode == 'show':
            sys.stdout.buffer.write((header + ' {\n' + ''.join(lines[start + 1:end + 1])).encode('utf-8', 'surrogateescape'))
        elif mode == 'edit':
            size, count, period, compression = args[1:]
            if not re.fullmatch(r'[1-9][0-9]{0,6}', size) or int(size) > 1048576:
                raise ValueError('invalid size')
            if not re.fullmatch(r'[1-9][0-9]{0,3}', count) or int(count) > 1000:
                raise ValueError('invalid count')
            if period not in {'daily', 'weekly', 'monthly'} or compression not in {'keep', 'compress', 'nocompress'}:
                raise ValueError('invalid settings')
            managed = {'hourly', 'daily', 'weekly', 'monthly', 'yearly', 'minutes', 'size', 'minsize', 'maxsize', 'rotate'}
            if compression != 'keep': managed |= {'compress', 'nocompress'}
            remove = {n for n, tokens in directives if tokens and tokens[0] in managed}
            newline = '\r\n' if lines[start].endswith('\r\n') else '\n'
            settings = [period, 'maxsize ' + size + 'M', 'rotate ' + count]
            if compression != 'keep': settings.append(compression)
            output = lines[:start + 1] + ['    ' + s + newline for s in settings]
            output += [line for n, line in enumerate(lines[start + 1:end], start + 1) if n not in remove]
            output += lines[end:]
            sys.stdout.buffer.write(''.join(output).encode('utf-8', 'surrogateescape'))
        else: raise ValueError('unknown mode')
except (ValueError, IndexError) as error:
    print('Unsupported rule: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

save_logrotate_rule() (
    local target=$1 block=$2 expected_hash=$3 size=$4 count=$5 period=$6 compression=$7 approved_hash=$8
    local config_target=$target config_backup=$operation_dir/logrotate.conf.before temporary=
    local config_original config_expected= config_pending=0 config_committed=0 config_restart=0
    trap 'finish_config_change "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ -f $target && ! -L $target && $(stat -c %h -- "$target") == 1 ]] &&
        trusted_directory "${target%/*}" && [[ $(file_sha256 "$target") == "$expected_hash" ]] || return 1
    logrotate -d "$logrotate_config" >/dev/null 2>&1 || return 1
    config_original=$(stat -c '%d:%i:%s:%y' -- "$target") || return 1
    cp -p -- "$target" "$config_backup" && [[ $(file_sha256 "$config_backup") == "$expected_hash" ]] || return 1
    temporary=$(mktemp -- "$target.XXXXXXXX.disabled") || return 1
    logrotate_rule_model edit "$config_backup" "$block" "$size" "$count" "$period" "$compression" > "$temporary" &&
        [[ $(file_sha256 "$temporary") == "$approved_hash" ]] || return 1
    diff -u -- "$config_backup" "$temporary" || [[ $? == 1 ]] || return 1
    chmod --reference="$target" -- "$temporary" && chown --reference="$target" -- "$temporary" &&
        printf 'config=%q\nblock=%s\nbackup=%q\nmaxsize_MiB=%s\nrotate=%s\nperiod=%s\ncompression=%s\n' \
            "$target" "$block" "$config_backup" "$size" "$count" "$period" "$compression" >> "$logfile" &&
        sync -- "$temporary" "$config_backup" "$logfile" "$operation_dir" &&
        [[ $(file_sha256 "$target") == "$expected_hash" && $(stat -c '%d:%i:%s:%y' -- "$target") == "$config_original" ]] || return 1
    config_expected=$(stat -c '%d:%i:%s:%y' -- "$temporary") || return 1
    config_pending=1
    mv -fT -- "$temporary" "$target" || return 1
    logrotate -d "$logrotate_config" >/dev/null && sync -- "$target" "${target%/*}" &&
        write_config_restore_metadata logrotate "$target" "$config_backup" || return 1
    config_committed=1
    printf '%s\n' "$(message 'Правило сохранено и проверено. Ротация ещё не запускалась.' 'Rule saved and validated. Rotation has not run yet.')"
)

edit_logrotate_rules() (
    local path listing block label choice index=0 size=100 count=4 period=daily compression=keep answer digest preview approved native
    local -a files=() blocks=() hashes=() sources=()
    local preview_dir=
    trap 'if [[ -n $preview_dir ]]; then rm -f -- "$preview_dir/after"; rmdir -- "$preview_dir"; fi' EXIT
    has python3 && has logrotate || return 1
    native=$(logrotate -d "$logrotate_config" 2>&1) || { printf '%s\n' "$native"; return 1; }
    sources+=("$logrotate_config")
    if [[ $native == *"including $logrotate_rules_directory"$'\n'* || $native == *"including $logrotate_rules_directory" ]]; then
        while IFS= read -r -d '' path; do sources+=("$path"); done < <(find "$logrotate_rules_directory" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null | sort -z)
    fi
    printf '\n%s\n' "$(message 'Выберите блок журнала. Нестандартные файлы пропускаются с объяснением.' 'Select a log block. Unsupported files are skipped with an explanation.')"
    for path in "${sources[@]}"; do
        [[ -f $path && ! -L $path && $(stat -c %h -- "$path") == 1 ]] && trusted_directory "${path%/*}" || continue
        # Only offer files actually read by the native validation.
        [[ $native == *"reading config file $path"$'\n'* || $native == *"reading config file ${path##*/}"$'\n'* ||
            $native == *"reading config file $path" || $native == *"reading config file ${path##*/}" ]] || continue
        digest=$(file_sha256 "$path") || return 1
        printf -v label '%q' "$path"
        if ! listing=$(logrotate_rule_model list "$path" 2>&1); then printf '%s: %s\n' "$label" "$listing"; continue; fi
        [[ $(file_sha256 "$path") == "$digest" ]] || return 1
        while IFS=$'\t' read -r block preview; do
            [[ -n $block ]] || continue
            ((index+=1)); files+=("$path"); blocks+=("$block"); hashes+=("$digest")
            printf '  %d. %s — %s (%s %s)\n' "$index" "$preview" "$label" "$(message блок block)" "$block"
        done <<< "$listing"
    done
    ((index)) || { printf '%s\n' "$(message "Поддерживаемых блоков нет. Инструкция: $(menu_path logrotate-guide)." "No supported blocks. Guide: $(menu_path logrotate-guide).")"; return 0; }
    printf '%s' "$(message 'Номер (0 или Enter — назад): ' 'Number (0 or Enter to go back): ')"
    IFS= read -r choice || return 0
    [[ -z $choice || $choice == 0 ]] && return 0
    [[ $choice =~ ^[1-9][0-9]{0,5}$ ]] && ((choice <= index)) || return 1
    path=${files[choice-1]}; block=${blocks[choice-1]}; digest=${hashes[choice-1]}
    [[ $(file_sha256 "$path") == "$digest" ]] || return 1
    printf '%s\n' "$(message 'Точный локальный блок (неуказанные параметры могут наследоваться):' 'Exact local block (unspecified options may be inherited):')"
    logrotate_rule_model show "$path" "$block" || return 1
    printf '%s\n' "$(message 'Действующие условия по всей конфигурации:' 'Effective conditions from the complete configuration:')"
    local details=1
    logrotate_check
    choose_log_number size 100 1048576 "$(message 'Порог размера, МиБ' 'Size threshold, MiB')" || return 0
    choose_log_number count 4 1000 "$(message 'Архивов на файл (текущий дополнительно)' 'Archives per file (current is additional)')" || return 0
    printf '%s' "$(message 'Период: 1 ежедневно, 2 еженедельно, 3 ежемесячно [1; q отмена]: ' 'Interval: 1 daily, 2 weekly, 3 monthly [1; q cancel]: ')"
    IFS= read -r answer || return 0
    case $answer in ''|1) period=daily ;; 2) period=weekly ;; 3) period=monthly ;; q|Q) return 0 ;; *) return 1 ;; esac
    printf '%s' "$(message 'Сжатие: 1 включить, 2 отключить, 3 сохранить [3; q отмена]: ' 'Compression: 1 enable, 2 disable, 3 preserve [3; q cancel]: ')"
    IFS= read -r answer || return 0
    case $answer in 1) compression=compress ;; 2) compression=nocompress ;; ''|3) compression=keep ;; q|Q) return 0 ;; *) return 1 ;; esac
    preview_dir=$(mktemp -d) || return 1
    logrotate_rule_model edit "$path" "$block" "$size" "$count" "$period" "$compression" > "$preview_dir/after" || return 1
    [[ $(file_sha256 "$path") == "$digest" ]] || return 1
    approved=$(file_sha256 "$preview_dir/after") || return 1
    if cmp -s -- "$path" "$preview_dir/after"; then printf '%s\n' "$(message 'Изменений нет.' 'No changes.')"; return 0; fi
    diff -u -- "$path" "$preview_dir/after" || [[ $? == 1 ]] || return 1
    printf '%s\n' "$(message 'maxsize проверяется при запуске logrotate. Сохраняются команды приложения и прочие условия, включая maxage/minage. Старые архивы могут удаляться при ротации.' \
        'maxsize is checked when logrotate runs. Application hooks and other conditions, including maxage/minage, are preserved. Rotation may remove old archives.')"
    printf '%s' "$(message 'Записать показанные изменения с резервной копией? [д/Н] ' 'Write these changes with a backup? [y/N] ')"
    IFS= read -r answer || return 0
    case $answer in y|Y|yes|д|Д|да) ;; *) return 0 ;; esac
    run_logged_maintenance logrotate-edit save_logrotate_rule "$path" "$block" "$digest" "$size" "$count" "$period" "$compression" "$approved" || return 1
    printf '%s' "$(message 'Показать план и предложить обычную ротацию сейчас? [д/Н] ' 'Preview and offer normal rotation now? [y/N] ')"
    IFS= read -r answer || return 0
    case $answer in y|Y|yes|д|Д|да) maintenance_action logrotate ;; esac
)

logrotate_editing_guide() {
    local path label choice size_mib=100 archive_count=4 period=daily answer index=0
    local -a files=()
    printf '\n%s\n' "$(message 'Настройка правил logrotate — инструкция без изменения файлов' \
        'Configure logrotate rules — instructions without file changes')"
    if [[ -f $logrotate_config && ! -L $logrotate_config ]]; then files+=("$logrotate_config"); fi
    while IFS= read -r -d '' path; do
        [[ -f $path && ! -L $path ]] || continue
        files+=("$path")
    done < <(find "$logrotate_rules_directory" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null | sort -z)
    ((${#files[@]})) || { printf '%s\n' "$(message 'Файлы правил не найдены.' 'No rule files found.')"; return 1; }
    for path in "${files[@]}"; do
        ((index+=1))
        printf -v label '%q' "$path"
        printf '  %d. %s\n' "$index" "$label"
        # Show declared log paths as navigation hints; the complete file follows selection.
        awk '
            /^[[:space:]]*(postrotate|prerotate|firstaction|lastaction|preremove)[[:space:]]*$/ { script=1; next }
            /^[[:space:]]*endscript[[:space:]]*$/ { script=0; next }
            !script && !/^[[:space:]]*#/ && /^[[:space:]]*[\/"]/ { print "       " $0 }
        ' "$path"
    done
    printf '%s' "$(message 'Номер файла (0 или Enter — назад): ' 'File number (0 or Enter to go back): ')"
    IFS= read -r choice || return 0
    [[ -z $choice || $choice == 0 ]] && return 0
    [[ $choice =~ ^[1-9][0-9]{0,5}$ ]] && ((choice <= ${#files[@]})) || return 1
    path=${files[choice-1]}
    [[ -f $path && ! -L $path ]] || return 1
    printf -v label '%q' "$path"
    printf '\n%s\n' "$(message "Текущее содержимое $label:" "Current contents of $label:")"
    nl -ba -- "$path" || return 1
    choose_log_number size_mib 100 1048576 "$(message 'Желаемый порог одного файла, МиБ' 'Desired threshold per file, MiB')" || return 0
    choose_log_number archive_count 4 1000 "$(message 'Число архивов на файл (текущий дополнительно)' 'Archives per file (current file is additional)')" || return 0
    printf '%s' "$(message 'Период: 1 — ежедневно, 2 — еженедельно, 3 — ежемесячно [1; q — отмена]: ' \
        'Interval: 1 — daily, 2 — weekly, 3 — monthly [1; q — cancel]: ')"
    IFS= read -r answer || return 0
    case $answer in ''|1) period=daily ;; 2) period=weekly ;; 3) period=monthly ;; q|Q) return 0 ;; *) return 1 ;; esac
    printf '\n%s\n' "$(message '1. Сохраните резервную копию выбранного файла вне /etc/logrotate.d/.' \
        '1. Back up the selected file outside /etc/logrotate.d/.')"
    printf '%s\n' "$(message '2. Откройте существующий файл в редакторе:' '2. Open the existing file in an editor:')"
    printf '   sudoedit -- %s\n' "$label"
    printf '%s\n' "$(message '3. В нужном блоке { ... } замените параметры периода, maxsize и rotate следующими:' \
        '3. In the intended { ... } block, replace the interval, maxsize and rotate settings with:')"
    printf '       %s\n       maxsize %sM\n       rotate %s\n' "$period" "$size_mib" "$archive_count"
    printf '%s\n' "$(message 'Не добавляйте второй блок для тех же путей. Не меняйте include, postrotate, prerotate, create, su и другие служебные настройки.' \
        'Do not add a second block for the same paths. Preserve include, postrotate, prerotate, create, su and other service settings.')"
    printf '%s\n' "$(message 'Если в блоке есть size, minsize, maxage, rotate -1 или другие условия, сначала проверьте их смысл: не добавляйте противоречащие параметры. Файл может содержать несколько блоков.' \
        'If the block has size, minsize, maxage, rotate -1 or other conditions, review them first and avoid conflicting settings. A file may contain multiple blocks.')"
    printf '%s\n' "$(message 'compress включает сжатие архивов. Сохраните delaycompress, если приложение использует его; сжатие здесь автоматически не меняется.' \
        'compress enables archive compression. Preserve delaycompress when used by the application; compression is not changed automatically here.')"
    printf '%s\n' "$(message '4. Проверьте всю конфигурацию без изменения журналов:' '4. Validate the complete configuration without changing logs:')"
    printf -v label '%q' "$logrotate_config"
    printf '   sudo logrotate -d %s\n' "$label"
    printf '%s\n' "$(message "5. Если проверка успешна, откройте $(menu_path logrotate) для плана и подтверждения обычной ротации. Принудительная ротация не требуется." \
        "5. After successful validation, use $(menu_path logrotate) to preview and confirm normal rotation. Forced rotation is unnecessary.")"
    printf '%s\n' "$(message 'Порог проверяется только при запуске logrotate. Учитывайте частоту таймера. Общий объём /var/log не ограничивается.' \
        'The threshold is checked only when logrotate runs. Account for timer frequency. This does not cap total /var/log usage.')"
    printf '%s\n' "$(message 'Файлы не изменены. Ручные правки и их резервные копии не добавляются в историю аудитора автоматически.' \
        'No files were changed. Manual edits and backups are not automatically recorded in auditor history.')"
}

maintenance_action() {
    local action=$1 package prompt answer source destination fingerprint preview
    local journal_limit=$journal_limit rsyslog_size_mib=$rsyslog_size_mib rsyslog_archive_count=$rsyslog_archive_count rsyslog_custom=$rsyslog_custom
    local -a command=()
    case $action in
        rotate|vacuum|limit|rsyslog-policy|logrotate) maintenance_log_status "$action" ;;
    esac
    case $action in
        journal-status) maintenance_log_status journal-status; return ;;
        rotation-status)
            (local format=txt details=1 overview_group=0; logrotate_check; logrotate_timer_check); return ;;
        docker-log-status)
            (local format=txt details=1 overview_group=0; docker_check); return ;;
        archive-options)
            [[ -n ${2:-} ]] || return 2
            choose_archive_action "$2"; return ;;
        compose-logging) prepare_compose_logging; return ;;
        docker-cleanup) docker_cleanup_menu; return ;;
        logrotate-guide) logrotate_editing_guide; return ;;
        logrotate-editor) edit_logrotate_rules; return ;;
        kernel) choose_kernel_removal; return ;;
        orphan-kernel) choose_orphan_kernel_group; return ;;
        restore-config) choose_config_restore; return ;;
        clean)
            command=(apt-get clean)
            prompt=$(message 'Очистить скачанные архивы APT? Установленные пакеты сохранятся.' \
                'Clear downloaded APT archives? Installed packages are kept.') ;;
        autoremove)
            command=(remove_unused_dependencies)
            prompt=$(message 'Передать план APT для окончательного подтверждения?' \
                'Proceed to the final confirmation in APT?') ;;
        rotate)
            command=(journalctl --rotate)
            prompt=$(message 'Ротировать активные файлы journald?' 'Rotate active journal files?') ;;
        vacuum)
            if log_settings_interactive; then
                local selected_mib=100
                choose_log_number selected_mib 100 1048576 "$(message 'Целевой объём journald после очистки, МиБ' 'Target journald size after cleanup, MiB')" || return 0
                journal_limit=$((selected_mib * 1024 * 1024))
            fi
            command=(journalctl --rotate "--vacuum-size=$journal_limit")
            prompt=$(message "Ротировать журнал и удалить старые архивы до целевого размера $(human_bytes "$journal_limit")? Удалённые записи восстановить нельзя." \
                "Rotate and delete old archives toward $(human_bytes "$journal_limit")? Deleted entries cannot be recovered.") ;;
        limit)
            if ! has systemctl || ! has systemd-analyze; then return 1; fi
            if log_settings_interactive; then
                local selected_mib=100
                choose_log_number selected_mib 100 1048576 "$(message 'Общий лимит journald, МиБ (для каждого хранилища)' 'Total journald limit, MiB (per storage location)')" || return 0
                journal_limit=$((selected_mib * 1024 * 1024))
            fi
            command=(configure_journal_limit)
            prompt=$(message "Установить постоянный лимит journald $(human_bytes "$journal_limit") и перезапустить службу? Старые записи могут быть удалены при ротации." \
                "Set persistent journald limit $(human_bytes "$journal_limit") and restart? Older entries may be deleted during rotation.") ;;
        archive)
            source=${2:-}
            if [[ -z $source ]]; then
                printf '%s' "$(message 'Путь к архиву логов в /var/log: ' 'Path to a log archive in /var/log: ')"
                IFS= read -r source || return 0
            fi
            printf '%s' "$(message 'Каталог для копии на другом диске: ' 'Backup directory on another filesystem: ')"
            IFS= read -r destination || return 0
            if ! source=$(realpath -e -- "$source") || ! destination=$(realpath -e -- "$destination") ||
                [[ $source != /var/log/* || $source == /var/log/journal/* || ! -f $source || ! -d $destination ]] ||
                ! trusted_directory "${source%/*}" || ! trusted_directory "$destination" ||
                [[ $(stat -c %h -- "$source") != 1 || $(stat -c %d -- "$source") == "$(stat -c %d -- "$destination")" ]]; then
                printf '%s\n' "$(message 'Нужен обычный архив из /var/log и каталог на другой файловой системе. Каталоги должны быть защищены от записи обычными пользователями.' \
                    'Choose a regular archive under /var/log and a directory on another filesystem. Directories must be protected from writes by non-root users.')" >&2
                return 1
            fi
            archive_source_ready "$source" || return 1
            fingerprint=$(stat -c '%d:%i:%s:%y:%z' -- "$source") || return 1
            du -h -- "$source" || return 1
            command=(archive_log "$source" "$destination" "$fingerprint")
            prompt=$(message "Скопировать $source в $destination и убрать оригинал после проверки копии?" \
                "Copy $source to $destination and remove the original after verifying the backup?") ;;
        delete-archive)
            source=${2:-}
            [[ -n $source && ! -L $source ]] || return 1
            source=$(realpath -e -- "$source") || return 1
            log_archive_path_is_allowed "$source" &&
                [[ -f $source && $(stat -c %h -- "$source") == 1 ]] &&
                trusted_directory "${source%/*}" && archive_source_ready "$source" || return 1
            fingerprint=$(stat -c '%d:%i:%s:%y:%z' -- "$source") || return 1
            local size blocks modified label
            read -r size blocks < <(stat -c '%s %b' -- "$source") || return 1
            modified=$(stat -c %y -- "$source") || return 1
            printf -v label '%q' "$source"
            printf '%s\n' "$label" \
                "$(message "Размер: $(human_bytes "$size"), занято: $(human_bytes "$((blocks * 512))")" \
                    "Size: $(human_bytes "$size"), allocated: $(human_bytes "$((blocks * 512))")")" \
                "$(message "Последнее изменение: $modified" "Last modified: $modified")"
            command=(delete_log_archive "$source" "$fingerprint")
            prompt=$(message 'Удалить этот архив без резервной копии? Записи будут потеряны без возможности восстановления.' \
                'Delete this archive without a backup? The entries will be permanently lost.') ;;
        history)
            show_maintenance_history; return ;;
        rsyslog-policy)
            has logrotate || return 1
            if log_settings_interactive; then
                choose_log_number rsyslog_size_mib 100 1048576 "$(message 'Порог размера одного лога rsyslog, МиБ' 'Size threshold per rsyslog file, MiB')" || return 0
                choose_log_number rsyslog_archive_count 4 1000 "$(message 'Число архивов на лог (текущий файл дополнительно)' 'Archives per log (current file is additional)')" || return 0
                rsyslog_custom=1
                printf '%s\n' "$(message "Ориентир на один путь: $((rsyslog_size_mib * (rsyslog_archive_count + 1))) МиБ без учёта сжатия и роста между запусками. Это не жёсткий лимит." \
                    "Per-path guide: $((rsyslog_size_mib * (rsyslog_archive_count + 1))) MiB before compression and growth between runs. Not a hard cap.")"
            fi
            [[ -f $rsyslog_rule && ! -L $rsyslog_rule ]] &&
                rsyslog_policy "$rsyslog_rule" >/dev/null || return 1
            if [[ $(cat -- "$rsyslog_rule") == "$(rsyslog_policy "$rsyslog_rule")" ]]; then return 0; fi
            command=(configure_rsyslog_rotation)
            prompt=$(message "Настроить ежедневную ротацию rsyslog: $rsyslog_size_mib МиБ, архивов $rsyslog_archive_count, и сохранить копию правила?" \
                "Configure daily rsyslog rotation: $rsyslog_size_mib MiB, $rsyslog_archive_count archives, and back up the rule?") ;;
        logrotate)
            has logrotate || return 1
            local available
            available=$(df -B1 --output=avail /var/log | awk 'NR==2 {print $1}') || return 1
            if ! [[ $available =~ ^[1-9][0-9]*$ ]]; then
                printf '%s\n' "$(message 'Нет доступного места на файловой системе /var/log. Ротация отменена.' \
                    'No space is available on the filesystem containing /var/log. Rotation cancelled.')" >&2
                return 1
            fi
            if ! preview=$(logrotate -d "$logrotate_config" 2>&1); then
                printf '%s\n' "$preview" >&2
                return 1
            fi
            preview=$(awk '/^considering log / { path=substr($0, 17) } /^[[:space:]]*log needs rotating/ { print path }' <<< "$preview")
            if [[ -z $preview ]]; then
                printf '%s\n' "$(message 'По текущим правилам файлов к ротации нет.' 'No files are due for rotation under the current rules.')"
                return 0
            fi
            printf '%s\n%s\n' "$(message 'По пробному запуску подлежат ротации:' 'The dry run identified files due for rotation:')" "$preview"
            command=(logrotate -v "$logrotate_config")
            prompt=$(message 'Запустить ротацию по всем действующим правилам? Старые архивы могут быть удалены по настройкам хранения.' \
                'Run rotation under all active rules? Old archives may be deleted according to retention settings.') ;;
        *) return 2 ;;
    esac
    if ! has "${command[0]}"; then
        printf '%s\n' "$(message "Команда ${command[0]} недоступна." "Command ${command[0]} is unavailable.")" >&2
        return 1
    fi
    case $action in
        autoremove)
            local format=txt details=1
            cleanup_check
            if (( ! autoremove_known )); then return 1; fi
            if (( ${#autoremove_candidates[@]} == 0 )); then
                printf '%s\n' "$(message 'Пакетов к удалению нет.' 'There are no packages to remove.')"
                return 0
            fi
            for package in "${autoremove_candidates[@]}"; do
                if kernel_package "$package"; then
                    printf '%s\n' "$(message "План содержит пакет ядра $package. Удаление из меню остановлено." \
                        "The plan includes kernel package $package. Removal from the menu was stopped.")" >&2
                    return 1
                fi
            done ;;
        rotate|vacuum) journalctl --disk-usage || return 1 ;;
    esac
    printf '%s %s ' "$prompt" "$(message '[д/Н]' '[y/N]')"
    IFS= read -r answer || return 0
    case $answer in
        y|Y|yes|YES|д|Д|да|Да|ДА) ;;
        *) printf '%s\n' "$(message 'Отменено.' 'Cancelled.')"; return 0 ;;
    esac
    run_logged_maintenance "$action" "${command[@]}" || return 1
    case $action in rotate|vacuum) journalctl --disk-usage || return 1 ;; esac
}

run_maintenance_action() {
    if (( EUID == 0 )); then
        maintenance_action "$@"
    elif has sudo; then
        sudo -- bash -- "${BASH_SOURCE[0]}" maintain "$@" --lang "$language"
    else
        printf '%s\n' "$(message 'Для обслуживания нужны права root.' 'Maintenance requires root.')" >&2
        return 1
    fi
}

largest_files() {
    timeout 30 find "$1" -xdev -type f -size +10M -printf '%b\t%D:%i\t%n\t%p\0' 2>/dev/null |
        sort -z -nr
}

package_file_owner() {
    local path=$1 result line owner
    result=$(dpkg-query -S -- "$path" 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ ${line#*: } == "$path" ]] || continue
        owner=${line%%: *}
        if [[ $owner =~ ^[a-z0-9.+:-]+(,\ [a-z0-9.+:-]+)*$ ]]; then
            printf '%s' "$owner"
            return 0
        fi
    done <<< "$result"
    return 1
}

cleanup_plan() {
    local apt_cache=${1:-/var/cache/apt/archives} journal=${2:-/var/log/journal}
    local rows percent free mount highest=-1 target= available device bytes amount choice action package kernels=0
    local entry inode links path label hint owner safety swaps= count=0 scan_ok=0
    local autoremove_known=0 autoremove_estimate=0
    local -a autoremove_candidates=()
    local -A actions=() sources=() seen=()
    if ! rows=$(df -l -B1 -x overlay -x tmpfs -x devtmpfs -x squashfs --output=pcent,avail,target); then return 1; fi
    while read -r percent free mount; do
        [[ $percent =~ ^[0-9]+%$ && $free =~ ^-?[0-9]+$ && $mount == /* ]] || continue
        percent=${percent%\%}
        if (( percent > highest )); then highest=$percent; target=$mount; available=$free; fi
    done <<< "$rows"
    if [[ -z $target ]] || ! device=$(stat -c %d -- "$target"); then
        printf '%s\n' "$(message 'Не удалось определить локальный раздел.' 'Could not identify a local filesystem.')" >&2
        return 1
    fi
    amount=$(human_kib "$((available / 1024))")
    printf '\n%s\n' "$(message "План для $target: занято $highest%, доступно $amount" \
        "Plan for $target: $highest% used, $amount available")"
    safety_line keep "$(message 'Системные и используемые файлы.' 'System and active files.')"
    safety_line clean "$(message 'Штатная очистка кэша или перенос с проверенной копией.' 'Managed cache cleanup or transfer with a verified backup.')"
    safety_line review "$(message 'Нужно оценить последствия, включая потерю старых логов.' 'Review the consequences, including loss of old logs.')"
    if has swapon; then swaps=$(swapon --show=NAME --noheadings --raw 2>/dev/null) || swaps=; fi
    printf '\n%s\n' "$(message 'Крупнейшие файлы (до 10, сортировка по занятому месту):' \
        'Largest files (up to 10, sorted by allocated space):')"
    while IFS= read -r -d '' entry; do
        if [[ $entry == SCAN_OK ]]; then scan_ok=1; continue; fi
        if (( count >= 10 )); then continue; fi
        bytes=${entry%%$'\t'*}; entry=${entry#*$'\t'}
        inode=${entry%%$'\t'*}; entry=${entry#*$'\t'}
        links=${entry%%$'\t'*}; path=${entry#*$'\t'}
        [[ $bytes =~ ^[1-9][0-9]*$ && $inode =~ ^[0-9]+:[0-9]+$ && ${inode%%:*} == "$device" && $path == /* ]] || continue
        if [[ -n ${seen[$inode]:-} ]]; then continue; fi
        seen[$inode]=1
        count=$((count + 1))
        amount=$(human_kib "$((bytes / 2))")
        printf -v label '%q' "$path"
        safety=review
        if [[ -n $swaps ]] && grep -Fxq -- "$path" <<< "$swaps"; then
            safety=keep
            hint=$(message 'активный файл подкачки, не удалять' 'active swap file, keep it')
        elif [[ $path == "$apt_cache"/*.deb ]]; then
            safety=clean
            hint=$(message 'скачанный пакет, можно очистить кэш APT' 'downloaded package, APT cache cleanup is available')
            actions[$count]=clean
        elif [[ $path == /var/lib/apt/lists/* ]]; then
            safety=keep
            hint=$(message 'индекс APT, обслуживается пакетным менеджером' 'APT index, managed by the package manager')
        elif [[ $path == /var/lib/docker/* || $path == /var/lib/containerd/* ]]; then
            safety=keep
            hint=$(message 'данные Docker или containerd, проверьте отчёт по контейнерам' 'Docker or containerd data, review the container report')
        elif [[ $path == /usr/* || $path == /lib/* || $path == /lib64/* || $path == /bin/* || $path == /sbin/* ]]; then
            if owner=$(package_file_owner "$path"); then
                safety=keep
                hint=$(message "файл пакета $owner, не удалять вручную" "file owned by $owner, keep it under package management")
            else
                hint=$(message 'системный каталог, проверьте владельца файла перед изменениями' 'system directory, check file ownership before changing it')
            fi
        elif [[ $path == /var/log/journal/* ]]; then
            safety=keep
            hint=$(message 'журнал systemd, используйте обслуживание journald' 'systemd journal, use journald maintenance')
        elif log_archive_path_is_allowed "$path"; then
            if [[ $links == 1 ]]; then
                hint=$(message 'архив, доступны перенос или удаление с подтверждением' 'archive, transfer or confirmed deletion available')
                actions[$count]=archive-options
                sources[$count]=$path
            else
                hint=$(message 'архив с жёсткими ссылками, проверьте вручную' 'archive with hard links, review manually')
            fi
        elif [[ $path == /var/log/* && $path =~ \.[0-9]+$ ]]; then
            hint=$(message 'похож на архив, проверьте правило ротации' 'looks like a rotated log, check its rotation rule')
        elif [[ $path == /var/log/syslog || $path == /var/log/*.log ]]; then
            safety=keep
            hint=$(message 'похож на текущий лог, проверьте ротацию' 'looks like a current log, check rotation')
        else
            hint=$(message 'ручная проверка' 'review manually')
        fi
        safety_line "$safety" "  $count. $amount · $label · $hint"
    done < <(if largest_files "$target"; then printf 'SCAN_OK\0'; fi)
    if (( ! scan_ok )); then
        printf '%s\n' "$(message 'Список может быть неполным: не все каталоги доступны или поиск прерван.' \
            'The list may be incomplete: some directories were inaccessible or the scan was interrupted.')"
    elif (( ! count )); then
        printf '%s\n' "$(message 'Файлы свыше 10 МиБ не найдены.' 'No files over 10 MiB found.')"
    fi
    if [[ -d $apt_cache && $(stat -c %d -- "$apt_cache") == "$device" ]] &&
        bytes=$(find "$apt_cache" -maxdepth 1 -type f -name '*.deb' -printf '%b\n' |
            awk '{total+=$1} END {printf "%.0f", total}') && [[ $bytes =~ ^[0-9]+$ ]]; then
        amount=$(human_kib "$((bytes / 2))")
        printf '%s\n' "$(message "Кэш APT: $amount скачанных пакетов." "APT cache: $amount of downloaded packages.")"
        if (( bytes )); then
            count=$((count + 1))
            safety_line clean "  $count. $(message 'Очистить кэш APT. Пакеты можно скачать заново.' \
                'Clear APT cache. Packages can be downloaded again.')"
            actions[$count]=clean
        fi
    fi
    if [[ -d $journal && $(stat -c %d -- "$journal") == "$device" ]] &&
        bytes=$(du -sx -B1 -- "$journal") && read -r bytes _ <<< "$bytes" && [[ $bytes =~ ^[0-9]+$ ]]; then
        amount=$(human_kib "$((bytes / 1024))")
        printf '%s\n' "$(message "Journald на разделе: $amount, включая активные файлы." \
            "Journald on this filesystem: $amount, including active files.")"
        if (( bytes > journal_limit )); then
            count=$((count + 1))
            safety_line review "  $count. $(message 'Очистить старые архивы journald во всех его каталогах. Удалённые записи не восстановить.' \
                'Vacuum old archives in all journald directories. Deleted entries cannot be recovered.')"
            actions[$count]=vacuum
        fi
    fi
    if [[ $(stat -c %d -- /usr) == "$device" ]]; then
        details=0 cleanup_check >/dev/null
        if (( autoremove_known && ${#autoremove_candidates[@]} )); then
            amount=$(human_kib "$autoremove_estimate")
            printf '%s\n' "$(message "Кандидаты APT: $amount по метаданным пакетов, файлы могут быть на разных разделах." \
                "APT candidates: $amount in package metadata, files may span filesystems.")"
            for package in "${autoremove_candidates[@]}"; do
                if kernel_package "$package"; then kernels=$((kernels + 1)); fi
            done
            if (( kernels )); then
                printf '%s\n' "$(message "В плане есть пакеты ядра ($kernels). Автоудаление заблокировано." \
                    "The plan includes kernel packages ($kernels). Automatic removal is blocked.")"
                count=$((count + 1))
                safety_line review "  $count. $(message 'Проверить возможность удаления одного старого ядра.' \
                    'Check whether one old kernel can be removed.')"
                actions[$count]=kernel
            fi
        fi
    fi
    if (( ${#actions[@]} )); then
        printf '%s' "$(message 'Номер действия или 0 для возврата: ' 'Action number or 0 to go back: ')"
        IFS= read -r choice || return 0
        [[ $choice != 0 && -n $choice ]] || return 0
        if [[ $choice =~ ^[1-9][0-9]*$ && -n ${actions[$choice]:-} ]]; then
            action=${actions[$choice]}
            if [[ $action == archive-options ]]; then run_maintenance_action archive-options "${sources[$choice]}"
            else run_maintenance_action "$action"; fi
            return
        fi
        printf '%s\n' "$(message 'Это действие недоступно в плане.' 'That action is not available in this plan.')"
    else
        printf '%s\n' "$(message 'В известных источниках подходящей очистки не найдено. Посмотрите полный аудит.' \
            'No suitable cleanup found among the known sources. Check the full audit.')"
    fi
}

registered_menu() {
    local parent=$1 choice id selected action
    while :; do
        printf '\n=== %s ===\n' "$(menu_title "$parent")"
        for id in ${menu_items[$parent]:-}; do
            printf '%s. %s\n' "${menu_number[$id]}" "$(menu_title "$id")"
        done
        printf '0. %s\n' "$(message Назад Back)"
        printf '%s' "$(message 'Ваш выбор: ' 'Your choice: ')"
        IFS= read -r choice || return 0
        [[ $choice != 0 && -n $choice ]] || return 0
        selected=''
        for id in ${menu_items[$parent]:-}; do
            if [[ $choice == "${menu_number[$id]}" ]]; then selected=$id; break; fi
        done
        if [[ -z $selected ]]; then
            printf '%s\n' "$(message 'Выберите действие из списка.' 'Choose an action from the list.')"
            continue
        fi
        action=${menu_action[$selected]}
        if [[ $action == @* ]]; then registered_menu "${action#@}"; continue; fi
        if [[ -z $action ]]; then registered_menu "$selected"; continue; fi
        if [[ $action == cleanup-plan ]]; then
            cleanup_plan || printf '%s\n' "$(message 'Действие не завершено.' 'The action did not complete.')"
            continue
        fi
        run_maintenance_action "$action" || printf '%s\n' "$(message 'Действие не завершено.' 'The action did not complete.')"
    done
}

maintenance_menu() { registered_menu maintenance; }

interactive_overview() {
    local format=txt details=1 overview_group=1 choice section status show=1
    local -a overview_titles=() overview_notes=() overview_details=() overview_ranks=() overview_reasons=()
    printf '\n%s\n' "$(message 'Собираю данные аудита…' 'Collecting audit data…')"
    audit >/dev/null
    while :; do
        if (( show )); then
            for section in "${!overview_titles[@]}"; do
                case ${overview_ranks[section]:-0} in
                    4) status=$(message 'Критическая проблема' 'Critical issue') ;;
                    3) status=$(message 'Требуется внимание' 'Needs attention') ;;
                    2) status=$(message 'Проверка неполная' 'Check incomplete') ;;
                    1) status=$(message 'Не требует внимания' 'No attention needed') ;;
                    *) status=$(message 'Пропущено' 'Skipped') ;;
                esac
                printf '\n=== %s. %s ===\n%s\n' "$section" "${overview_titles[section]}" "$status"
                if [[ -n ${overview_notes[section]:-} ]]; then
                    printf '%s' "${overview_notes[section]}"
                elif [[ -n ${overview_reasons[section]:-} ]]; then
                    printf '%s\n' "${overview_reasons[section]}"
                fi
            done
            show=0
        fi
        printf '\n%s' "$(message 'Номер раздела — подробности, s — сводка, 0 — меню: ' \
            'Section number for details, s for overview, 0 for menu: ')"
        IFS= read -r choice || return 0
        case $choice in
            0) return 0 ;;
            s|S) show=1 ;;
            [1-9])
                if [[ -n ${overview_titles[choice]:-} ]]; then
                    printf '\n=== %s ===\n%s' "${overview_titles[choice]}" "${overview_details[choice]:-}"
                    continue
                fi
                printf '%s\n' "$(message 'Такого раздела нет.' 'No such section.')" ;;
            *) printf '%s\n' "$(message 'Введите номер раздела, s или 0.' 'Enter a section number, s or 0.')" ;;
        esac
    done
}

menu() {
    local choice
    while :; do
        printf '\n%s\n' "Server Auditor v$VERSION" \
            "${menu_number[overview]}. $(menu_title overview)" \
            "${menu_number[update]}. $(menu_title update)" \
            "${menu_number[full-audit]}. $(menu_title full-audit)" \
            "${menu_number[maintenance]}. $(menu_title maintenance)" \
            "$(message '0. Выход' '0. Exit')"
        printf '%s' "$(message 'Ваш выбор: ' 'Your choice: ')"
        IFS= read -r choice || return 0
        case $choice in
            "${menu_number[overview]}") interactive_overview ;;
            "${menu_number[full-audit]}") details=1 audit ;;
            "${menu_number[maintenance]}") maintenance_menu ;;
            "${menu_number[update]}")
                if (( EUID == 0 )); then
                    update 0 || printf '%s\n' "$(message 'Обновление завершилось ошибкой.' 'Update failed.')" >&2
                elif has sudo; then
                    sudo -- bash -- "${BASH_SOURCE[0]}" update --lang "$language" ||
                        printf '%s\n' "$(message 'Обновление завершилось ошибкой.' 'Update failed.')" >&2
                else
                    printf '%s\n' "$(message 'Для обновления запустите скрипт от root.' 'Run the script as root to update packages.')" >&2
                fi ;;
            0) return 0 ;;
            *) printf '%s\n' "$(message 'Выберите действие из списка.' 'Choose an action from the list.')" ;;
        esac
    done
}

main() {
    local -a args=()
    while (( $# )); do
        if [[ $1 == --lang ]]; then
            case ${2:-} in ru|en) language=$2 ;; *) usage >&2; return 2 ;; esac
            shift 2
        else
            args+=("$1")
            shift
        fi
    done
    set -- ${args[@]+"${args[@]}"}
    case ${1:-} in
        '')
            if [[ -t 0 && -t 1 ]]; then menu; return; fi ;;
        menu)
            if (( $# != 1 )) || [[ ! -t 0 || ! -t 1 ]]; then
                printf '%s\n' "$(message 'Для меню нужен терминал. Для скриптов используйте audit или update --yes.' 'The menu requires a terminal. For scripts use audit or update --yes.')" >&2
                return 2
            fi
            menu; return ;;
        --help|-h) usage; return ;;
        --version) printf 'Server Auditor v%s\n' "$VERSION"; return ;;
        maintain)
            if (( EUID != 0 )) || [[ ! -t 0 || ! -t 1 ]]; then
                printf '%s\n' "$(message 'Для обслуживания нужны права root и терминал.' 'Maintenance requires root and a terminal.')" >&2
                return 2
            fi
            shift
            if (( $# != 1 )) && { (( $# != 2 )) || [[ $1 != archive && $1 != archive-options && $1 != delete-archive ]]; }; then usage >&2; return 2; fi
            maintenance_action "$@"; return ;;
        update)
            shift
            case $#:${1:-} in
                0:) update 0 ;;
                1:--yes) update 1 ;;
                *) usage >&2; return 2 ;;
            esac
            return ;;
        audit) shift ;;
    esac
    while (( $# )); do
        case $1 in
            --details) details=1; shift ;;
            --format)
                case ${2:-} in txt|json) format=$2 ;; *) usage >&2; return 2 ;; esac
                shift 2 ;;
            *) usage >&2; return 2 ;;
        esac
    done
    audit
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
