# Evaluated once in the existing interactive zsh. Only session hooks and prompt
# markup change; no startup files, keymaps, modules or processes are installed.
__zw_osc_install() {
    builtin emulate -L zsh -o no_aliases
    [[ -o interactive && ${__zw_osc_version-} != 1 ]] || return 0
    [[ $PS1$PS2$RPS1$RPS2 == *'133;'* || $PS1$PS2$RPS1$RPS2 == *'633;'* ]] && return 0
    builtin local hook
    for hook in ${(k)functions}; do
        [[ $hook == __zw_osc_* ]] && continue
        [[ ${functions[$hook]} == *'133;'* || ${functions[$hook]} == *'633;'* ]] && return 0
    done
    [[ ${parameters[PS1]} != *readonly* && ${parameters[precmd_functions]} != *readonly* && ${parameters[preexec_functions]} != *readonly* ]] || return 0
    builtin typeset -g __zw_osc_version=1 __zw_osc_running=0
    __zw_osc_preexec() {
        __zw_osc_running=1
        builtin printf '\e]133;C\a'
        return 0
    }
    __zw_osc_precmd() {
        builtin local code=$?
        builtin emulate -L zsh
        if (( __zw_osc_running )); then
            builtin printf '\e]133;D;%d\a' "$code"
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
            PS1=$'%{\e]133;A;zw_shell=zsh;zw_start=preexec\a%}'"$PS1"$'%{\e]133;B\a%}'
        fi
        return 0
    }
    precmd_functions=(__zw_osc_precmd ${precmd_functions:#__zw_osc_precmd})
    preexec_functions=(__zw_osc_preexec ${preexec_functions:#__zw_osc_preexec})
}
__zw_osc_install
builtin unfunction __zw_osc_install
