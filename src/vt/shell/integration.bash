# Evaluated once in the existing shell. No file deployment or shell replacement.
# Bash < 4.4 has no PS0: DEBUG cannot observe every compound command (notably
# a pure subshell). The host must not manufacture a start when C is absent.
__zw_osc_prior_debug=$(builtin trap -p DEBUG)
__zw_osc_definitions=$(builtin declare -f)
__zw_osc_install() {
[[ $- == *i* && ${BASH_VERSINFO[0]} -ge 3 ]] || return 0
[[ ${__zw_osc_version-} == 1 ]] && return 0
[[ ${PS1-}${PS0-}${PROMPT_COMMAND[*]-} == *'133;'* || ${PS1-}${PS0-}${PROMPT_COMMAND[*]-} == *'633;'* ]] && return 0
if [[ $__zw_osc_definitions == *'133;'* || $__zw_osc_definitions == *'633;'* ]]; then
    builtin unset __zw_osc_definitions
    return 0
fi
builtin unset __zw_osc_definitions
# A DEBUG owner or tracing changes the legacy preexec semantics. Leave it alone.
[[ -z $__zw_osc_prior_debug && $- != *T* ]] || return 0
builtin shopt -q extdebug && return 0
# Readonly prompt variables cannot be safely extended.
builtin local variable attributes
for variable in PROMPT_COMMAND PS1 PS0; do
    attributes=$(builtin declare -p "$variable" 2>/dev/null) || attributes=''
    attributes=${attributes#declare -}
    attributes=${attributes%% *}
    [[ $attributes != *r* ]] || return 0
done
__zw_osc_version=1
__zw_osc_armed=0
__zw_osc_status=0
__zw_osc_mode=debug
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
    __zw_osc_mode=ps0
    PS0=$'\e]133;C\a'${PS0-}
fi
__zw_osc_cwd() {
    builtin local LC_ALL=C value=$PWD encoded='' host=${HOSTNAME-} character hex index
    for (( index=0; index<${#value}; ++index )); do
        character=${value:index:1}
        case $character in
            [a-zA-Z0-9/._~-]) encoded+=$character ;;
            *) builtin printf -v hex '%%%02X' "'$character"; encoded+=$hex ;;
        esac
    done
    builtin printf '\e]7;file://%s%s\a' "${host//[^a-zA-Z0-9.-]/}" "$encoded"
}
__zw_osc_precmd() {
    __zw_osc_status=$? __zw_osc_armed=0
    # D without a preceding C can be a blank line, syntax error or a construct
    # not observed by old Bash. The host distinguishes it from a complete pair.
    builtin printf '\e]133;D;%d\a' "$__zw_osc_status"
    __zw_osc_cwd
    return "$__zw_osc_status"
}
__zw_osc_arm() {
    # Prompt frameworks may replace PS1. Extend their current value once.
    if [[ ${PS1-} != *'133;'* ]]; then
        PS1='\[\e]133;A;zw_shell=bash;zw_start='"$__zw_osc_mode"'\a\]'"${PS1-}"'\[\e]133;B\a\]'
    fi
    __zw_osc_armed=1
    return "$__zw_osc_status"
}
__zw_osc_debug() {
    [[ $__zw_osc_armed == 1 && $BASH_COMMAND != __zw_osc_precmd && $BASH_COMMAND != __zw_osc_arm ]] || return 0
    [[ ${BASH_SUBSHELL:-0} == 0 && -z ${COMP_POINT-}${READLINE_POINT-} ]] || return 0
    __zw_osc_armed=0
    builtin printf '\e]133;C\a'
    return 0
}
if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]] &&
   (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
    PROMPT_COMMAND=(__zw_osc_precmd "${PROMPT_COMMAND[@]}" __zw_osc_arm)
else
    PROMPT_COMMAND=$'__zw_osc_precmd\n'${PROMPT_COMMAND-}$'\n__zw_osc_arm'
fi
[[ $__zw_osc_mode == ps0 ]] || builtin trap '__zw_osc_debug' DEBUG
}
__zw_osc_install
builtin unset -f __zw_osc_install
builtin unset __zw_osc_prior_debug __zw_osc_definitions
