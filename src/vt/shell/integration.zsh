# Evaluated once in the existing interactive zsh. Only session hooks and prompt
# markup change; no startup files, keymaps, modules or processes are installed.
__zw_osc_hello() {
    [[ -n ${__zw_attach_id-} && -n ${__zw_context_id-} ]] || return 0
    builtin local "zw_host=${HOSTNAME:-${HOST:-unknown}}" "zw_user=${USER:-unknown}"
    builtin printf '\e]133;P;zw_hello=%s;zw_ctx=%s;zw_shell=zsh;zw_host=%s;zw_user=%s\a' "$__zw_attach_id" "$__zw_context_id" "${zw_host//[^a-zA-Z0-9_.@-]/}" "${zw_user//[^a-zA-Z0-9_.@-]/}"
}
__zw_osc_install() {
    builtin emulate -L zsh -o no_aliases
    [[ -o interactive ]] || return 0
    if [[ ${__zw_osc_version-} == 2 && ${__zw_osc_pid-} == $$ ]]; then
        __zw_osc_hello
        return 0
    fi
    [[ $PS1$PS2$RPS1$RPS2 == *'133;'* || $PS1$PS2$RPS1$RPS2 == *'633;'* ]] && return 0
    builtin local hook
    for hook in ${(k)functions}; do
        [[ $hook == __zw_osc_* ]] && continue
        [[ ${functions[$hook]} == *'133;'* || ${functions[$hook]} == *'633;'* ]] && return 0
    done
    [[ ${parameters[PS1]} != *readonly* && ${parameters[precmd_functions]} != *readonly* && ${parameters[preexec_functions]} != *readonly* ]] || return 0
    builtin typeset +x PS1 PS2 RPS1 RPS2
    builtin typeset -g __zw_osc_version=2 __zw_osc_running=0 __zw_osc_pid=$$
    builtin typeset -g __zw_context_id=${__zw_attach_id-} __zw_osc_tag=
    [[ -z $__zw_context_id ]] || __zw_osc_tag=";zw_ctx=$__zw_context_id"
    __zw_osc_preexec() {
        __zw_osc_running=1
        builtin printf '\e]133;C%s\a' "$__zw_osc_tag"
        return 0
    }
    __zw_osc_precmd() {
        builtin local code=$?
        builtin emulate -L zsh
        if (( __zw_osc_running )); then
            builtin printf '\e]133;D;%d%s\a' "$code" "$__zw_osc_tag"
            __zw_osc_running=0
        fi
        builtin local LC_ALL=C value=$PWD encoded='' character hex
        builtin local -i index
        for (( index=1; index<=${#value}; ++index )); do
            character=${value[index]}
            case $character in
                [a-zA-Z0-9/._~-]) encoded+=$character ;;
                *) builtin printf -v hex '%%%02X' "'$character"; encoded+=$hex ;;
            esac
        done
        builtin printf '\e]7;file://%s%s\a' "${HOST//[^a-zA-Z0-9.-]/}" "$encoded"
        if [[ $PS1 != *'133;'* ]]; then
            PS1=$'%{\e]133;A;zw_shell=zsh;zw_start=preexec'"$__zw_osc_tag"$'\a%}'"$PS1"$'%{\e]133;B'"$__zw_osc_tag"$'\a%}'
        fi
        return 0
    }
    precmd_functions=(__zw_osc_precmd ${precmd_functions:#__zw_osc_precmd})
    preexec_functions=(__zw_osc_preexec ${preexec_functions:#__zw_osc_preexec})
    __zw_osc_hello
}
__zw_osc_install
builtin unfunction __zw_osc_install
