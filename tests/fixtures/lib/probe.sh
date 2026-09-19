# A module for the tests of the helper, in the shape of a ported module: a header, a
# sourcing guard, and functions namespaced by the path.
if [[ -n "${_STEALTH_LIB_PROBE:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_PROBE=1

#######################################
# Greets a name.
#
# Arguments:
#   $1 (String) - The name. Default: stranger
# Outputs:
#   The greeting
#######################################
stealth::probe::greet() {
    printf 'hello, %s\n' "${1:-stranger}"
}
