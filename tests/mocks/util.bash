#!/usr/bin/env bash
# The default mocks of the util layer. A test of a module that depends on util
# registers them in setup(), so it asserts on the calls its subject makes
# rather than on what a sink received:
#
#   setup() {
#       common_setup
#       load_lib util/assert
#       load_mock util
#       mock::stealth::util::log
#   }
#
# A test of util/log itself does not load these, because the sinks are its
# subject.

#######################################
# Mocks the five level functions of util/log.
#
# ERROR ends the process in the library, so the mock ends it too. A function
# that asserts has no status to return: it either continues or it is gone, and
# a mock that returned would let a caller carry on with a value it refused.
#
# Usage:
#   mock::stealth::util::log
#   stealth::util::assert::not_empty '' 'a name is required'
#   assert_called_with_args stealth::util::log::error \
#       --frame 2 'assertion failed: %s' 'a name is required'
#
# Arguments:
#   None
# Returns:
#   0 - Registered
#######################################
mock::stealth::util::log() {
    # The real function takes -c CODE. No test needs another status yet. Add a
    # rule for '-c *' when one does; the last rule registered is matched first.
    mock stealth::util::log::error '*' 'exit 1'

    mock stealth::util::log::warn '*' 'return 0'
    mock stealth::util::log::info '*' 'return 0'
    mock stealth::util::log::debug '*' 'return 0'
    mock stealth::util::log::trace '*' 'return 0'
}

#######################################
# Fails unless the subject under `run` refused its arguments with this reason.
# It reads the call rather than a sink, so it needs the mocks above.
#
# Usage:
#   run stealth::util::text::trim ''
#   assert_refused 'an output variable is required'
#
# Arguments:
#   $1 (String) - The reason the assertion gave
# Returns:
#   0 - The subject exited 1 with that reason
#   1 - Otherwise, after the report
#######################################
assert_refused() {
    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' "${1}"
}
