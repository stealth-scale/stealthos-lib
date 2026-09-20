###############################################################################
# module: core/engine
# layer: core
# description: The shape of a run: read the configuration, take over the
#              output, run every module's init, then the start hooks forward,
#              the payload, and the end hooks back.
#
#              Reading the configuration is its own step, because the stage
#              comes out of it and the stage decides which file of a module is
#              loaded. configure runs before any module is loaded; run does
#              the rest.
#
#              The end hooks are a finally, not an on-success. They are put on
#              the trap stack before the first start hook, so a payload that
#              fails, a hook that fails and a signal all still unmount, stop
#              and release whatever the run took. The old engine ran the
#              payload through a function that exits on failure, so the whole
#              end pass was unreachable after anything went wrong.
#
#              Standard output goes to the log file and standard error to a
#              recorder file. The recorder belongs to this module, from the
#              temporary file it is kept in to the moment it is printed, so
#              nothing else can remove it first.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_CORE_ENGINE:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_CORE_ENGINE=1

stealth::util::import "util/assert" "util/log" "util/text" "util/ui"
stealth::util::import "core/state" "core/trap" "core/loader"

# =============================================================================
# CONSTANTS
# =============================================================================

# A line of a configuration file: a key, an equals sign, and the rest.
declare -gr _STEALTH_CORE_ENGINE_LINE_RE='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$'

# The settings the util layer reads as variables of its own, because util may
# not depend on core. The engine copies these out of the registry once the
# configuration is read. The variable of a setting is its key with the prefix
# in front, upper-cased, so log_level is STEALTH_LOG_LEVEL.
declare -gra _STEALTH_CORE_ENGINE_MIRROR=(log_level log_format log_color log_file ui_width ui_theme dry_run)

# Where a log file goes when the log_file setting says auto.
declare -gr _STEALTH_CORE_ENGINE_LOG_ROOT='/var/log/stealth/stealth.log'
declare -gr _STEALTH_CORE_ENGINE_LOG_USER='.local/state/stealth/stealth.log'

declare -gr _STEALTH_CORE_ENGINE_LOG_DIR_MODE='0755'

# =============================================================================
# CONFIGURATION
# =============================================================================

declare -g STEALTH_CONF_FILE="${STEALTH_CONF_FILE:-/etc/stealth/stealth.conf}"
declare -g STEALTH_CONF_DIR="${STEALTH_CONF_DIR:-/etc/stealth/conf.d}"

# =============================================================================
# STATE
# =============================================================================

declare -gi _STEALTH_CORE_ENGINE_CONFIGURED=0
declare -gi _STEALTH_CORE_ENGINE_READY=0
declare -gi _STEALTH_CORE_ENGINE_ENDED=0

# The module or payload the run is in the middle of, for the trap stack to
# name when one of them fails, and when it started. Empty between them.
declare -g _STEALTH_CORE_ENGINE_RUNNING=''
declare -gi _STEALTH_CORE_ENGINE_STARTED=0

# The descriptors this run started with, kept so the end of the run can put
# them back.
declare -g _STEALTH_CORE_ENGINE_FD_OUT=''
declare -g _STEALTH_CORE_ENGINE_FD_ERR=''

# The file standard error is collected in, and printed from when a run fails.
declare -g _STEALTH_CORE_ENGINE_RECORDER=''

# The settings that were already in the environment when the run was
# configured. Those came from the command line or from the shell, and a
# configuration file does not overrule them.
declare -gA _STEALTH_CORE_ENGINE_GIVEN=()

# =============================================================================
# INTERNAL: CONFIGURATION
# =============================================================================

#######################################
# Turns the name of a variable or a setting into a registry key: the prefix
# dropped and the rest in lower case. STEALTH_LOG_LEVEL and log_level are the
# same setting.
#
# Usage:
#   stealth::core::engine::_to_key key 'STEALTH_LOG_LEVEL'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The name
# Returns:
#   0 - Converted
#######################################
stealth::core::engine::_to_key() {
    local -n _engine_key_out="${1}"

    stealth::util::text::to_lower _engine_key_out "${2}"
    stealth::util::text::remove_prefix _engine_key_out "${_engine_key_out}" 'stealth_'
    return 0
}

#######################################
# Records which settings the caller chose, so a configuration file cannot
# overrule them.
#
# Only an exported variable counts. A caller that means a setting exports it,
# from the command line or from the shell the run started in. A library
# declares its own default with declare -g and does not export it, so
# util/log setting STEALTH_LOG_LEVEL to 3 as it loads is not a choice anyone
# made and a file is still free to set it.
#
# Usage:
#   stealth::core::engine::_take_given
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_ENGINE_GIVEN (Write)
# Returns:
#   0 - Recorded
#######################################
stealth::core::engine::_take_given() {
    local _engine_given_name _engine_given_key

    _STEALTH_CORE_ENGINE_GIVEN=()
    while IFS= read -r _engine_given_name; do
        stealth::core::engine::_to_key _engine_given_key "${_engine_given_name}"
        _STEALTH_CORE_ENGINE_GIVEN["${_engine_given_key}"]=1
    done < <(compgen -e STEALTH_ || true)
    return 0
}

#######################################
# Reads one configuration file into the registry. A line is a key, an equals
# sign and a value, with an optional export in front and optional quotes
# around the value. A line that is not one of those is reported and skipped,
# rather than turned into a setting with a name nothing will ever read.
#
# Usage:
#   stealth::core::engine::_read_config /etc/stealth/stealth.conf
#
# Arguments:
#   $1 (String) - The file
# Globals:
#   _STEALTH_CORE_ENGINE_LINE_RE (Read)
#   _STEALTH_CORE_ENGINE_GIVEN (Read)
# Returns:
#   0 - Read, or there was no readable file there
#######################################
stealth::core::engine::_read_config() {
    if [[ ! -f "${1}" || ! -r "${1}" ]]; then
        return 0
    fi

    stealth::util::log::debug 'reading the configuration %s' "${1}"

    local -a _engine_read_lines=()
    mapfile -t _engine_read_lines < "${1}"

    local _engine_read_line _engine_read_key _engine_read_value
    local -i _engine_read_no=0
    for _engine_read_line in "${_engine_read_lines[@]}"; do
        _engine_read_no=$(( _engine_read_no + 1 ))
        stealth::util::text::trim _engine_read_line "${_engine_read_line}"

        if [[ -z "${_engine_read_line}" || "${_engine_read_line}" == '#'* ]]; then
            continue
        fi

        if [[ ! "${_engine_read_line}" =~ ${_STEALTH_CORE_ENGINE_LINE_RE} ]]; then
            stealth::util::log::warn '%s line %d is not a setting: %s' \
                "${1}" "${_engine_read_no}" "${_engine_read_line}"
            continue
        fi

        stealth::core::engine::_to_key _engine_read_key "${BASH_REMATCH[2]}"
        _engine_read_value="${BASH_REMATCH[3]}"

        if [[ "${_engine_read_value}" == \"*\" || "${_engine_read_value}" == \'*\' ]]; then
            _engine_read_value="${_engine_read_value:1:${#_engine_read_value} - 2}"
        fi

        if [[ -n "${_STEALTH_CORE_ENGINE_GIVEN[${_engine_read_key}]:-}" ]]; then
            stealth::util::log::trace 'keeping the given %s over the one in %s' \
                "${_engine_read_key}" "${1}"
            continue
        fi

        stealth::core::state::set "${_engine_read_key}" "${_engine_read_value}"
    done
    return 0
}

#######################################
# Copies the settings the util layer reads as variables out of the registry.
# util may not depend on core, so the logger and the UI read a variable and
# the engine is what puts the value there.
#
# Usage:
#   stealth::core::engine::_mirror_settings
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_ENGINE_MIRROR (Read)
# Returns:
#   0 - Copied
#######################################
stealth::core::engine::_mirror_settings() {
    local _engine_mirror_key _engine_mirror_value _engine_mirror_name

    for _engine_mirror_key in "${_STEALTH_CORE_ENGINE_MIRROR[@]}"; do
        if stealth::core::state::get _engine_mirror_value "${_engine_mirror_key}"; then
            stealth::util::text::to_const _engine_mirror_name \
                "STEALTH_${_engine_mirror_key}"
            printf -v "${_engine_mirror_name}" '%s' "${_engine_mirror_value}"
        fi
    done
    return 0
}

# =============================================================================
# INTERNAL: THE OUTPUT OF A RUN
# =============================================================================

#######################################
# Keeps the descriptors this run started with, and points the console sink of
# the logger at the standard error it was given. Everything the logger writes
# reaches the caller even once standard error has been taken over.
#
# Usage:
#   stealth::core::engine::_save_io
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_ENGINE_FD_OUT (Write)
#   _STEALTH_CORE_ENGINE_FD_ERR (Write)
#   STEALTH_LOG_FD_CONSOLE (Write)
# Returns:
#   0 - Kept
#######################################
stealth::core::engine::_save_io() {
    exec {_STEALTH_CORE_ENGINE_FD_OUT}>&1
    exec {_STEALTH_CORE_ENGINE_FD_ERR}>&2

    # shellcheck disable=SC2034  # util/log reads this, in its own file
    STEALTH_LOG_FD_CONSOLE="${_STEALTH_CORE_ENGINE_FD_ERR}"
    return 0
}

#######################################
# Opens the log file the log_file setting names, making its directory when it
# is not there. A setting of auto picks a path from the user the run is: the
# system log directory for root and the state directory of the home directory
# for anyone else.
#
# Usage:
#   stealth::core::engine::_open_log_file
#
# Arguments:
#   None
# Globals:
#   STEALTH_LOG_FILE (Read)
#   STEALTH_LOG_FD_FILE (Write)
#   HOME (Read)
# Returns:
#   0 - Opened, or no log file was asked for
#   Exits 1 when the directory or the file cannot be opened
#######################################
stealth::core::engine::_open_log_file() {
    local _engine_log_path="${STEALTH_LOG_FILE:-}"

    if [[ -z "${_engine_log_path}" ]]; then
        return 0
    fi

    if [[ "${_engine_log_path}" == 'auto' ]]; then
        if stealth::core::state::is_root; then
            _engine_log_path="${_STEALTH_CORE_ENGINE_LOG_ROOT}"
        else
            _engine_log_path="${HOME:-/tmp}/${_STEALTH_CORE_ENGINE_LOG_USER}"
        fi
    fi

    local _engine_log_dir="${_engine_log_path%/*}"
    if [[ -n "${_engine_log_dir}" && ! -d "${_engine_log_dir}" ]]; then
        # The mode is set after the directory is made. With -p it would apply
        # to the deepest directory alone, and leave the rest on the umask.
        if ! mkdir -p -- "${_engine_log_dir}"; then
            stealth::util::log::error 'no log directory could be made at %s' \
                "${_engine_log_dir}"
        fi
        if ! chmod "${_STEALTH_CORE_ENGINE_LOG_DIR_MODE}" -- "${_engine_log_dir}"; then
            stealth::util::log::warn 'the mode of %s could not be set' \
                "${_engine_log_dir}"
        fi
    fi

    if ! { exec {STEALTH_LOG_FD_FILE}>>"${_engine_log_path}"; } 2>/dev/null; then
        stealth::util::log::error 'the log file %s could not be opened' \
            "${_engine_log_path}"
    fi

    stealth::core::state::set 'log_file' "${_engine_log_path}"
    return 0
}

#######################################
# Opens the file standard error is collected in for the rest of the run.
#
# Usage:
#   stealth::core::engine::_open_recorder
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_ENGINE_RECORDER (Write)
# Returns:
#   0 - Opened
#   Exits 1 when no temporary file can be made
#######################################
stealth::core::engine::_open_recorder() {
    local _engine_rec_path

    if ! _engine_rec_path="$(mktemp -t 'stealth-recorder.XXXXXXXX')"; then
        stealth::util::log::error 'no file could be made to collect standard error in'
    fi

    _STEALTH_CORE_ENGINE_RECORDER="${_engine_rec_path}"
    return 0
}

#######################################
# Takes over the output of the run. Standard output goes to the log file, or
# nowhere when there is none, because what a build tool prints is noise until
# something fails. Standard error goes to the recorder, which is printed only
# if the run fails.
#
# Usage:
#   stealth::core::engine::_take_io
#
# Arguments:
#   None
# Globals:
#   STEALTH_LOG_FD_FILE (Read)
#   _STEALTH_CORE_ENGINE_RECORDER (Read)
# Returns:
#   0 - Taken
#######################################
stealth::core::engine::_take_io() {
    if [[ -n "${STEALTH_LOG_FD_FILE:-}" ]] &&
       { true >&"${STEALTH_LOG_FD_FILE}"; } 2>/dev/null; then
        exec 1>&"${STEALTH_LOG_FD_FILE}"
    else
        exec 1>/dev/null
    fi

    exec 2>"${_STEALTH_CORE_ENGINE_RECORDER}"
    return 0
}

#######################################
# Starts the recorder again, so what it holds when a run fails is the output
# of the step that failed rather than of everything before it. It is also what
# keeps the file from growing for the length of a long build.
#
# The file is opened again rather than emptied. Emptying it would leave
# standard error writing at the offset it had reached, and the file would then
# begin with a hole as long as what was thrown away.
#
# Usage:
#   stealth::core::engine::_rotate_recorder
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_ENGINE_RECORDER (Read)
# Returns:
#   0 - Started again, or there is no recorder
#######################################
stealth::core::engine::_rotate_recorder() {
    if [[ -z "${_STEALTH_CORE_ENGINE_RECORDER}" ]]; then
        return 0
    fi

    exec 2>"${_STEALTH_CORE_ENGINE_RECORDER}"
    return 0
}

#######################################
# The last thing a run does. It puts the descriptors back, prints what was
# collected on standard error if the run failed, and removes the recorder.
#
# core/trap runs this after every handler, so nothing a handler does can
# remove the recorder before it is read.
#
# Usage:
#   stealth::core::trap::finally stealth::core::engine::_report
#
# Arguments:
#   $1 (Integer) - The status the run is ending with
# Globals:
#   _STEALTH_CORE_ENGINE_FD_OUT (Read)
#   _STEALTH_CORE_ENGINE_FD_ERR (Read)
#   _STEALTH_CORE_ENGINE_RECORDER (Read/Write)
# Outputs:
#   What was collected on standard error, to standard error
# Returns:
#   0 - Done
#######################################
stealth::core::engine::_report() {
    if [[ -n "${_STEALTH_CORE_ENGINE_FD_OUT}" ]]; then
        exec 1>&"${_STEALTH_CORE_ENGINE_FD_OUT}"
    fi
    if [[ -n "${_STEALTH_CORE_ENGINE_FD_ERR}" ]]; then
        exec 2>&"${_STEALTH_CORE_ENGINE_FD_ERR}"
    fi

    if [[ -z "${_STEALTH_CORE_ENGINE_RECORDER}" ]]; then
        return 0
    fi

    if (( ${1:-0} != 0 )) && [[ -s "${_STEALTH_CORE_ENGINE_RECORDER}" ]]; then
        stealth::util::ui::alert 'What the run wrote to standard error' \
            'the last step before it stopped'
        cat -- "${_STEALTH_CORE_ENGINE_RECORDER}" >&2
    fi

    rm -f -- "${_STEALTH_CORE_ENGINE_RECORDER}"
    _STEALTH_CORE_ENGINE_RECORDER=''
    return 0
}

# =============================================================================
# INTERNAL: HOOKS
# =============================================================================

#######################################
# Runs one hook of one module, if that module defines it.
#
# Usage:
#   stealth::core::engine::_call_hook 'pkg/zlib' 'build::start'
#
# Arguments:
#   $1 (String) - The module path
#   $2 (String) - The rest of the function name after the namespace
# Returns:
#   0 - Ran, or the module does not define it
#   The status of the hook when it fails
#######################################
stealth::core::engine::_call_hook() {
    local _engine_hook_ns
    stealth::core::loader::to_namespace _engine_hook_ns "${1}"
    local -r _engine_hook_fn="${_engine_hook_ns}::${2}"

    if ! declare -F "${_engine_hook_fn}" >/dev/null 2>&1; then
        stealth::util::log::trace 'no %s' "${_engine_hook_fn}"
        return 0
    fi

    stealth::util::log::debug 'running %s' "${_engine_hook_fn}"
    "${_engine_hook_fn}"
}

#######################################
# Runs the init hook of every library that is loaded, then of every module, in
# the order each was loaded. The order matters, and an associative array has
# none, which is why the load order is read from the lists that keep it.
#
# Usage:
#   stealth::core::engine::_init_all
#
# Arguments:
#   None
# Returns:
#   0 - Every init ran
#######################################
stealth::core::engine::_init_all() {
    local -a _engine_init_libs=() _engine_init_mods=()
    local _engine_init_one _engine_init_ns

    stealth::util::import::loaded _engine_init_libs
    for _engine_init_one in "${_engine_init_libs[@]}"; do
        stealth::core::loader::to_namespace _engine_init_ns \
            "${_engine_init_one}" 'stealth'
        if declare -F "${_engine_init_ns}::init" >/dev/null 2>&1; then
            stealth::util::log::trace 'running %s::init' "${_engine_init_ns}"
            "${_engine_init_ns}::init"
        fi
    done

    stealth::core::state::get_module_order _engine_init_mods
    for _engine_init_one in "${_engine_init_mods[@]}"; do
        stealth::core::engine::_call_hook "${_engine_init_one}" 'init'
    done
    return 0
}

#######################################
# Runs the start hook of every module, in load order, drawing a status line
# for each. The first one that fails stops the run, because what comes after
# it was built on what it was meant to do.
#
# Usage:
#   stealth::core::engine::_start_all build
#
# Arguments:
#   $1 (String) - The stage
# Globals:
#   _STEALTH_CORE_ENGINE_RUNNING (Write)
#   _STEALTH_CORE_ENGINE_STARTED (Write)
#   SECONDS (Read)
# Outputs:
#   A status line per module, to the console sink
# Returns:
#   0 - Every start hook ran
#   The status of the first one that failed
#######################################
stealth::core::engine::_start_all() {
    local -a _engine_start_mods=()
    stealth::core::state::get_module_order _engine_start_mods

    if (( ${#_engine_start_mods[@]} == 0 )); then
        return 0
    fi

    stealth::util::ui::header "Stage: ${1}"

    local _engine_start_mod
    local -i _engine_start_at
    for _engine_start_mod in "${_engine_start_mods[@]}"; do
        stealth::core::engine::_rotate_recorder
        stealth::util::ui::begin "${_engine_start_mod}"

        _engine_start_at="${SECONDS}"
        _STEALTH_CORE_ENGINE_STARTED="${SECONDS}"
        _STEALTH_CORE_ENGINE_RUNNING="${_engine_start_mod}"

        # Called plainly, so that a hook which fails partway stops there.
        # Written as `hook || status=$?` it would not: bash turns errexit off
        # for a command in a condition, and leaves it off for everything that
        # command calls, so the rest of a failing hook runs anyway. The trap
        # stack is what reports a failure, and _running is what tells it
        # which module was in the middle of one.
        stealth::core::engine::_call_hook "${_engine_start_mod}" "${1}::start"

        _STEALTH_CORE_ENGINE_RUNNING=''
        stealth::util::ui::end "${_engine_start_mod}" 0 \
            "$(( SECONDS - _engine_start_at ))"
    done
    return 0
}

#######################################
# Draws the line for whatever the run was in the middle of when it stopped.
#
# A hook and a payload are called plainly, so a failure in one does not come
# back as a status anybody here can print. It arrives as the trap stack
# unwinding, and by then the loop that would have drawn the line is gone.
# This runs from that stack, which is the only place left that knows a module
# was halfway through.
#
# Usage:
#   stealth::core::trap::defer stealth::core::engine::_report_running
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_ENGINE_RUNNING (Read)
#   _STEALTH_CORE_ENGINE_STARTED (Read)
# Returns:
#   0 - Drawn, or there was nothing in the middle of running
#######################################
stealth::core::engine::_report_running() {
    if [[ -z "${_STEALTH_CORE_ENGINE_RUNNING}" ]]; then
        return 0
    fi

    stealth::util::ui::end "${_STEALTH_CORE_ENGINE_RUNNING}" 1 \
        "$(( SECONDS - _STEALTH_CORE_ENGINE_STARTED ))"
    stealth::util::log::warn '%s did not finish' \
        "${_STEALTH_CORE_ENGINE_RUNNING}"

    _STEALTH_CORE_ENGINE_RUNNING=''
    return 0
}

#######################################
# Runs the end hook of every module that started, in the reverse of the order
# they started in. It runs once, whether the run is finishing or unwinding,
# and a hook that fails is reported while the rest still run, because a run
# that is ending has to give back everything it took.
#
# Usage:
#   stealth::core::engine::_end_all
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_ENGINE_ENDED (Read/Write)
#   _STEALTH_CORE_STATE_STAGE (Read)
# Returns:
#   0 - Every end hook ran, or they already had
#######################################
stealth::core::engine::_end_all() {
    if (( _STEALTH_CORE_ENGINE_ENDED == 1 )); then
        return 0
    fi
    _STEALTH_CORE_ENGINE_ENDED=1

    local _engine_end_stage
    stealth::core::state::detect_stage _engine_end_stage

    local -a _engine_end_mods=()
    stealth::core::state::get_module_order _engine_end_mods

    local -i _engine_end_i
    for (( _engine_end_i = ${#_engine_end_mods[@]} - 1; _engine_end_i >= 0; _engine_end_i-- )); do
        if ! stealth::core::engine::_call_hook \
                "${_engine_end_mods[_engine_end_i]}" "${_engine_end_stage}::end"; then
            stealth::util::log::warn 'the end hook of %s failed' \
                "${_engine_end_mods[_engine_end_i]}"
        fi
    done
    return 0
}

#######################################
# Registers the cleanup of every library that has one, to run when the run
# ends. A library that has something to give back defines a cleanup function
# in its own namespace, and the engine finds it.
#
# It works this way round because a layer may not import the one above it.
# sys/io/tmp cannot ask core/trap to run its cleanup, so core asks sys instead,
# by name and without importing anything.
#
# Usage:
#   stealth::core::engine::_defer_cleanups
#
# Arguments:
#   None
# Returns:
#   0 - Registered
#######################################
stealth::core::engine::_defer_cleanups() {
    local -a _engine_clean_libs=()
    local _engine_clean_one _engine_clean_ns

    stealth::util::import::loaded _engine_clean_libs
    for _engine_clean_one in "${_engine_clean_libs[@]}"; do
        stealth::core::loader::to_namespace _engine_clean_ns \
            "${_engine_clean_one}" 'stealth'
        if declare -F "${_engine_clean_ns}::cleanup" >/dev/null 2>&1; then
            stealth::util::log::trace 'the end of the run will call %s::cleanup' \
                "${_engine_clean_ns}"
            stealth::core::trap::defer "${_engine_clean_ns}::cleanup"
        fi
    done
    return 0
}

#######################################
# Reports whether a payload can be run: a function of the run, or a command on
# the path.
#
# Usage:
#   if ! stealth::core::engine::_can_run "${payload}"; then ...
#
# Arguments:
#   $1 (String) - The payload
# Returns:
#   0 - It can be run
#   1 - It cannot
#######################################
stealth::core::engine::_can_run() {
    declare -F "${1}" >/dev/null 2>&1 || command -v "${1}" >/dev/null 2>&1
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reads the configuration into the registry: the file first, then every
# fragment of the directory in name order. A setting already in the
# environment when this runs came from the command line and is kept.
#
# This is a step of its own because the stage is one of the settings, and the
# stage decides which file of a module is loaded. Call it before loading a
# module. The old engine read the configuration after the modules were
# loaded, so a stage set in a file was ignored whenever a module was named on
# the command line.
#
# Usage:
#   stealth::core::engine::configure
#
# Arguments:
#   None
# Globals:
#   STEALTH_CONF_FILE (Read)
#   STEALTH_CONF_DIR (Read)
#   _STEALTH_CORE_ENGINE_CONFIGURED (Read/Write)
# Returns:
#   0 - Read
#######################################
stealth::core::engine::configure() {
    if (( _STEALTH_CORE_ENGINE_CONFIGURED == 1 )); then
        return 0
    fi

    stealth::core::engine::_take_given
    stealth::core::engine::_read_config "${STEALTH_CONF_FILE}"

    if [[ -d "${STEALTH_CONF_DIR}" ]]; then
        local -a _engine_conf_files=()
        local _engine_conf_file
        shopt -s nullglob
        _engine_conf_files=("${STEALTH_CONF_DIR}"/*.conf)
        shopt -u nullglob

        for _engine_conf_file in "${_engine_conf_files[@]}"; do
            if [[ "${_engine_conf_file}" != "${STEALTH_CONF_FILE}" ]]; then
                stealth::core::engine::_read_config "${_engine_conf_file}"
            fi
        done
    fi

    stealth::core::engine::_mirror_settings
    _STEALTH_CORE_ENGINE_CONFIGURED=1
    return 0
}

#######################################
# Gets the run ready: keep the descriptors, open the log file, start the
# logger, take over the traps, open the recorder, take over the output, start
# the UI, and run every init hook.
#
# The order is the contract. The logger needs the kept descriptors, the traps
# need the logger, and the init hooks run with the output already taken over
# so that what they print is collected like everything else.
#
# Usage:
#   stealth::core::engine::bootstrap
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_ENGINE_READY (Read/Write)
# Returns:
#   0 - Ready
#######################################
stealth::core::engine::bootstrap() {
    if (( _STEALTH_CORE_ENGINE_READY == 1 )); then
        return 0
    fi

    stealth::core::engine::_save_io
    stealth::core::engine::_open_log_file
    stealth::util::log::init

    stealth::core::trap::init
    stealth::core::trap::finally stealth::core::engine::_report

    stealth::core::engine::_open_recorder
    stealth::core::engine::_take_io

    stealth::util::ui::init

    _STEALTH_CORE_ENGINE_READY=1
    stealth::core::engine::_init_all
    stealth::core::engine::_defer_cleanups

    stealth::util::log::debug 'the engine is ready'
    return 0
}

#######################################
# Runs one stage from end to end: the configuration, the bootstrap, the start
# hooks forward, the payload if there is one, and the end hooks back.
#
# The end hooks are registered before the first start hook, so they run
# whatever happens next.
#
# A hook and a payload are both called plainly, with nothing catching their
# status. That is deliberate. Written as `hook || status=$?` the call would
# read better and would stop a failing hook from failing: bash turns errexit
# off for a command in a condition and leaves it off for everything that
# command goes on to call, so the rest of a hook that failed on its first
# line runs anyway. A subshell does not help, because the same suppression
# reaches into one.
#
# So a failure here is reported by the trap stack rather than by a returned
# status: it prints where the failure was and what the run had written, runs
# the end hooks through the deferred _end_all, and ends the run with the
# status of whatever failed.
#
# Usage:
#   stealth::core::engine::run
#   stealth::core::engine::run mod::pkg::zlib::rebuild --force
#
# Arguments:
#   $1 (String) - A function or a command to run between the passes. Optional
#   $@ (String) - Its arguments
# Globals:
#   _STEALTH_CORE_ENGINE_RUNNING (Write)
#   _STEALTH_CORE_ENGINE_STARTED (Write)
# Returns:
#   0 - Every hook and the payload ran
#   Exits 1 when the payload is neither a function nor a command, and with
#   the status of a hook or a payload that failed
#######################################
stealth::core::engine::run() {
    local -r _engine_run_payload="${1:-}"
    if (( $# > 0 )); then
        shift
    fi

    stealth::core::engine::configure
    stealth::core::engine::bootstrap

    local _engine_run_stage
    stealth::core::state::detect_stage _engine_run_stage

    stealth::core::trap::defer stealth::core::engine::_end_all
    stealth::core::trap::defer stealth::core::engine::_report_running

    # Both of these are called plainly. A hook or a payload that fails has to
    # stop where it failed, and it does not when the call is written as part
    # of a condition: bash turns errexit off for such a command and for
    # everything it calls. What reports a failure is the trap stack, which
    # prints where it happened and what the run had written, and then runs
    # the end hooks through the deferred _end_all above.
    stealth::core::engine::_start_all "${_engine_run_stage}"

    if [[ -n "${_engine_run_payload}" ]]; then
        if ! stealth::core::engine::_can_run "${_engine_run_payload}"; then
            stealth::util::log::error -c 127 'no function or command named %s' \
                "${_engine_run_payload}"
        fi

        stealth::core::engine::_rotate_recorder
        stealth::util::log::info 'running %s' "${_engine_run_payload}"
        _STEALTH_CORE_ENGINE_RUNNING="${_engine_run_payload}"
        _STEALTH_CORE_ENGINE_STARTED="${SECONDS}"
        "${_engine_run_payload}" "$@"
        _STEALTH_CORE_ENGINE_RUNNING=''
    fi

    stealth::core::engine::_end_all
    return 0
}
