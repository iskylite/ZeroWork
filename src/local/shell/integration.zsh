# Sourced once from the temporary .zshenv wrapper; no key bindings are changed.
# All protocol strings are data, never eval'd or parsed as shell commands.
[[ -o interactive && $ZSH_VERSION == 5.9 ]] || return
zmodload zsh/system zsh/net/socket zsh/zleparameter || return

# OSC 133 describes commands independently of the private editing channel.
# Install after .zshrc so an existing shell integration can retain ownership.
_zw_semantic_preexec() {
    emulate -L zsh
    local LC_ALL=C command=$1 encoded='' character hex
    local -i index
    # Bound the semantic metadata, never the command the user executes. Encode
    # control bytes and separators so command text cannot inject terminal OSCs.
    for (( index = 1; index <= ${#command} && index <= 4096; ++index )); do
        character=${command[index]}
        if [[ $character == [a-zA-Z0-9._~-] ]]; then
            encoded+=$character
        else
            printf -v hex '%%%02X' "'$character"
            encoded+=$hex
        fi
    done
    _zw_semantic_running=1
    printf '\e]133;C;cmdline_url=%s\a' "$encoded"
    return 0
}
_zw_semantic_precmd() {
    local code=$?
    if (( _zw_semantic_running )); then
        printf '\e]133;D;%d\a' "$code"
        _zw_semantic_running=0
    fi
    printf '\e]133;A\a'
    return 0
}
_zw_semantic_input() {
    printf '\e]133;B\a'
    return 0
}
_zw_semantic_install() {
    emulate -L zsh
    local hook
    # Common OSC 133 integrations put their markers in the prompt or in a
    # hook/helper. Inspect loaded definitions, without executing user code.
    [[ "$PS1$PS2$RPS1$RPS2" == *'133;'* ]] && return 0
    for hook in ${(k)functions}; do
        [[ $hook == _zw_* ]] && continue
        [[ ${functions[$hook]} == *'133;'* ]] && return 0
    done
    typeset -gi _zw_semantic_running=0
    precmd_functions=(_zw_semantic_precmd ${precmd_functions:#_zw_semantic_precmd})
    preexec_functions=(_zw_semantic_preexec ${preexec_functions:#_zw_semantic_preexec})
    add-zle-hook-widget line-init _zw_semantic_input
    _zw_semantic_precmd
}

_zw_edit_stop() {
    if (( ${_zw_fd:--1} >= 0 )); then
        zle -F $_zw_fd 2>/dev/null
        zmodload -u zw_ipc 2>/dev/null
    fi
    _zw_fd=-1 _zw_token=0 _zw_lease=0 _zw_tx='' _zw_rx=''
}
_zw_edit_flush() {
    emulate -L zsh
    local LC_ALL=C chunk count=0
    [[ -n $_zw_tx ]] || return 0
    chunk=${_zw_tx[1,8192]}
    if syswrite -o $_zw_fd -c count -- "$chunk"; then
        _zw_tx=${_zw_tx[count+1,-1]}
    elif (( count > 0 )); then
        _zw_tx=${_zw_tx[count+1,-1]}
    elif [[ ${errnos[$ERRNO]} != EAGAIN && ${errnos[$ERRNO]} != EWOULDBLOCK ]]; then
        _zw_edit_stop
        return 1
    fi
}
_zw_edit_emit() {
    emulate -L zsh
    local LC_ALL=C body='' value prefix
    (( _zw_fd >= 0 )) || return 1
    (( ++_zw_sequence ))
    for value in 1 $_zw_session $_zw_generation $_zw_nonce $_zw_sequence "$@"; do
        body+="${#value}:$value,"
    done
    (( ${#body} <= 131072 && ${#_zw_tx} + ${#body} + 8 <= 262144 )) || { _zw_edit_stop; return 1; }
    printf -v prefix '%08x' ${#body}
    _zw_tx+="$prefix$body"
    _zw_edit_flush
}
_zw_edit_observe() {
    # Keep the caller's MULTIBYTE setting and character-based ZLE indexes.
    local signature="$BUFFER"$'\0'"$CURSOR/$MARK/$REGION_ACTIVE/$KEYMAP/$CONTEXT/$PREBUFFER"
    [[ $signature == $_zw_signature && $_zw_need_snapshot == 0 ]] && return 0
    (( PENDING == 0 && KEYS_QUEUED_COUNT == 0 )) || return 0
    local changed=0
    [[ $signature != $_zw_signature ]] && changed=1
    _zw_need_snapshot=0
    _zw_signature=$signature
    (( changed )) && (( ++_zw_revision ))
    (( _zw_lease && ${#BUFFER} )) && _zw_lease=0
    _zw_edit_emit snapshot $_zw_token $_zw_revision "$BUFFER" $CURSOR $MARK $REGION_ACTIVE "$KEYMAP" "$CONTEXT" "$PREBUFFER" $_zw_lease $_zw_observation
}
_zw_edit_init() {
    (( _zw_fd >= 0 )) || return 0
    (( ++_zw_prompt_counter ))
    _zw_token=$_zw_prompt_counter _zw_revision=0 _zw_signature='' _zw_lease=0
    _zw_edit_observe
    return 0
}
_zw_edit_finish() {
    (( _zw_fd >= 0 )) && _zw_edit_emit revoked $_zw_token
    _zw_token=0 _zw_lease=0
    return 0
}
_zw_edit_safe() {
    (( _zw_token > 0 && CURSOR == ${#BUFFER} && REGION_ACTIVE == 0 && PENDING == 0 && KEYS_QUEUED_COUNT == 0 )) &&
        [[ $CONTEXT == start && -z $PREBUFFER && ($KEYMAP == main || $KEYMAP == emacs || $KEYMAP == viins) ]]
}
_zw_edit_request() {
    local kind=$1 operation=$2 token=$3 revision=$4 expected=$5 cursor=$6 replacement=$7
    if [[ $kind == observe ]]; then
        _zw_observation=$operation _zw_need_snapshot=1
        _zw_edit_observe
        return 0
    fi
    _zw_edit_observe
    local reason=''
    if [[ $kind == credit ]]; then _zw_edit_flush; return 0; fi
    if (( token != _zw_token || _zw_token == 0 )); then reason=stale_prompt
    elif (( revision != _zw_revision )) || [[ $expected != $BUFFER || $cursor != $CURSOR ]]; then reason=revision_changed
    elif (( PENDING || KEYS_QUEUED_COUNT )); then reason=busy_input
    elif ! _zw_edit_safe; then reason=mode_changed
    elif [[ $kind == begin && -n $BUFFER ]]; then reason=revision_changed
    elif [[ $kind == end && $7 != $_zw_lease ]]; then reason=stale_lease
    elif [[ $kind != replace && $kind != begin && $kind != end ]]; then reason=unsupported
    fi
    if [[ -n $reason ]]; then
        _zw_edit_emit rejected "$operation" "$reason"
        return 0
    fi
    if [[ $kind == replace ]]; then
        BUFFER=$replacement CURSOR=${#replacement} MARK=0 REGION_ACTIVE=0 _zw_lease=0
        _zw_signature=''
    elif [[ $kind == begin ]]; then _zw_lease=$operation
    else _zw_lease=0
    fi
    _zw_signature=''
    _zw_edit_observe
    _zw_edit_emit applied "$operation" "$revision" $_zw_revision "$BUFFER" $CURSOR $_zw_lease
    zle -R
}
_zw_edit_parse() {
    emulate -L zsh
    local LC_ALL=C body=$1 size field
    local -a values=()
    while [[ -n $body ]]; do
        [[ $body == <->:* ]] || return 1
        size=${body%%:*}
        (( size <= 131072 )) || return 1
        body=${body#*:}
        (( ${#body} >= size + 1 )) || return 1
        [[ ${body[size+1]} == , ]] || return 1
        field=${body[1,size]}
        (( size == 0 )) && field=''
        values+=("$field")
        body=${body[size+2,-1]}
    done
    (( ${#values} >= 6 )) || return 1
    [[ $values[1] == 1 && $values[2] == $_zw_session && $values[3] == $_zw_generation && $values[4] == $_zw_nonce ]] || return 1
    (( values[5] > _zw_received )) || return 1
    _zw_received=$values[5]
    # Invoke the widget helper after restoring the user's character locale.
    _zw_message=("${values[@]:5}")
}
_zw_edit_control() {
    local chunk='' count=0 io_status size prefix body
    if sysread -i $_zw_fd -s 8192 -c count chunk; then
        _zw_rx+=$chunk
    else
        io_status=$?
        if (( io_status == 5 )) && [[ ${errnos[$ERRNO]} == EAGAIN || ${errnos[$ERRNO]} == EWOULDBLOCK ]]; then
            _zw_edit_flush; return 0
        fi
        _zw_edit_stop; return 0
    fi
    while (( ${#_zw_rx} >= 8 )); do
        # Decode and slice frames in a local byte locale only.
        () {
            local LC_ALL=C
            prefix=${_zw_rx[1,8]}
            [[ ${#prefix} == 8 && $prefix != *[^0-9a-f]* ]] || return 1
            size=$((16#$prefix))
            (( size <= 131072 )) || return 1
            (( ${#_zw_rx} >= size + 8 )) || return 2
            body=${_zw_rx[9,size+8]}
            _zw_rx=${_zw_rx[size+9,-1]}
        }
        io_status=$?
        (( io_status == 2 )) && break
        (( io_status == 0 )) || { _zw_edit_stop; return 0; }
        _zw_edit_parse "$body" || { _zw_edit_stop; return 0; }
        _zw_edit_request "${_zw_message[@]}"
    done
    _zw_edit_flush
    return 0
}
_zw_edit_precmd() {
    _zw_edit_stop
    zsocket "$_zw_socket" || return 0
    _zw_fd=$REPLY
    local -a original_module_path=("${module_path[@]}")
    module_path=("$_zw_module_dir" "${module_path[@]}")
    zmodload zw_ipc
    local loaded=$?
    module_path=("${original_module_path[@]}")
    if (( loaded )); then
        exec {_zw_fd}<&-
        _zw_fd=-1
        return 0
    fi
    _zw_sequence=0 _zw_received=0 _zw_tx='' _zw_rx=''
    zle -F -w $_zw_fd _zw_edit_control
    _zw_edit_emit hello "$ZSH_VERSION" nonblocking_cloexec
    return 0
}
_zw_edit_install() {
    [[ -o rcs ]] || return 0
    autoload -Uz add-zle-hook-widget
    _zw_semantic_install
    add-zle-hook-widget line-init _zw_edit_init
    add-zle-hook-widget line-pre-redraw _zw_edit_observe
    add-zle-hook-widget history-line-set _zw_edit_observe
    add-zle-hook-widget keymap-select _zw_edit_observe
    add-zle-hook-widget line-finish _zw_edit_finish
    zle -N _zw_edit_control
    precmd_functions=(${precmd_functions:#_zw_edit_install} _zw_edit_precmd)
    preexec_functions+=(_zw_edit_stop)
    _zw_edit_precmd
    return 0
}
typeset -gi _zw_fd=-1 _zw_prompt_counter=0 _zw_token=0 _zw_revision=0 _zw_sequence=0 _zw_received=0 _zw_lease=0 _zw_observation=0 _zw_need_snapshot=0
typeset -g _zw_signature='' _zw_tx='' _zw_rx=''
typeset -ga _zw_message=()
precmd_functions+=(_zw_edit_install)
