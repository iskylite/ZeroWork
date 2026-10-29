# BootstrapV1 owned disposable zsh 5.9 shell. No user rc files are loaded.
[[ -o interactive && $ZSH_VERSION == 5.9 ]] || return
zmodload zsh/system zsh/net/socket zsh/zleparameter || return
# TerminalExecutionProtocol v1. Independent socket and module lifetime from the
# editing bridge. Payloads are netstrings; no received value is eval'd.
_zw_exec_stop() {
    (( _zw_exec_fd >= 0 )) && zle -F $_zw_exec_fd 2>/dev/null
    zmodload -u zw_execution 2>/dev/null
    _zw_exec_fd=-1 _zw_exec_id='' _zw_exec_stage=unavailable
    _zw_exec_rx='' _zw_exec_tx=''
}
_zw_exec_flush() {
    emulate -L zsh
    local LC_ALL=C chunk count=0
    [[ -n $_zw_exec_tx ]] || return 0
    chunk=${_zw_exec_tx[1,8192]}
    if syswrite -o $_zw_exec_fd -c count -- "$chunk"; then
        _zw_exec_tx=${_zw_exec_tx[count+1,-1]}
    elif (( count > 0 )); then
        _zw_exec_tx=${_zw_exec_tx[count+1,-1]}
    elif [[ ${errnos[$ERRNO]} != EAGAIN && ${errnos[$ERRNO]} != EWOULDBLOCK ]]; then
        _zw_exec_stop
        return 1
    fi
    return 0
}
_zw_exec_emit() {
    emulate -L zsh
    local LC_ALL=C body='' value prefix
    (( _zw_exec_fd >= 0 )) || return 1
    (( ++_zw_exec_sequence ))
    for value in 1 $_zw_session $_zw_generation $_zw_nonce $_zw_exec_sequence "$@"; do
        body+="${#value}:$value,"
    done
    (( ${#body} <= 131072 && ${#_zw_exec_tx} + ${#body} + 8 <= 262144 )) || { _zw_exec_stop; return 1; }
    printf -v prefix '%08x' ${#body}
    _zw_exec_tx+="$prefix$body"
    _zw_exec_flush
}
_zw_exec_safe() {
    (( _zw_token > 0 && CURSOR == ${#BUFFER} && REGION_ACTIVE == 0 && PENDING == 0 && KEYS_QUEUED_COUNT == 0 )) &&
        [[ $CONTEXT == start && -z $PREBUFFER && ($KEYMAP == main || $KEYMAP == emacs || $KEYMAP == viins) ]]
}
_zw_exec_boundary() {
    # syswrite issues one bounded write. This locates the observed PTY interval;
    # it does not prove background writers finished. A short write revokes it.
    local kind=$1 token=$2 frame count=0
    _zw_exec_emit boundary $_zw_exec_id $_zw_exec_fence "$kind" "$token" || return 1
    printf -v frame '\e]777;zerowork-exec-v1;%s;%s\a' "$token" "$kind"
    local LC_ALL=C
    syswrite -o 1 -c count -- "$frame" || return 1
    (( count == ${#frame} )) || { _zw_exec_emit revoked boundary_write; return 1; }
}
_zw_exec_request() {
    local kind=$1 id=$2 fence=$3 epoch=$4 token=$5 command=$6 hash=$7
    if [[ $kind == prepare ]]; then
        local scope=$6 observation=0
        if [[ $scope != session_interval ]]; then
            _zw_exec_emit rejected "$id" unsupported_scope; return 0
        fi
        if [[ $_zw_exec_stage != idle || -n $BUFFER ]] || ! _zw_exec_safe; then
            _zw_exec_emit rejected "$id" input_conflict; return 0
        fi
        # Linux FD ownership observation is not implemented. Preserve the
        # separate attribution axis instead of blocking a valid interval.
        if (( ${#jobstates} )); then observation=1; else observation=4; fi
        if [[ $scope == exact ]] && (( observation != 0 )); then
            _zw_exec_emit rejected "$id" "output_observation_$observation"; return 0
        fi
        _zw_exec_id=$id _zw_exec_fence=$fence _zw_exec_epoch=$epoch
        _zw_exec_stage=prepared _zw_exec_start=$token _zw_exec_scope=$scope
        _zw_exec_emit output_observation "$id" "$fence" "$observation"
        _zw_exec_boundary start "$token" || { _zw_exec_stop; return 0; }
        _zw_exec_emit ready "$id" "$fence" "$epoch"
    elif [[ $kind == buffer ]]; then
        if [[ $_zw_exec_stage != prepared || $id != $_zw_exec_id || $fence != $_zw_exec_fence || $epoch != $_zw_exec_epoch || -n $BUFFER ]] || ! _zw_exec_safe; then
            _zw_exec_emit rejected "$id" stale_buffer; return 0
        fi
        # Parse a complete command without running it. No continuation guessing.
        if ! zsh -f -n <<< "$command" 2>/dev/null; then
            _zw_exec_emit rejected "$id" incomplete_syntax; return 0
        fi
        BUFFER=$command CURSOR=${#command} MARK=0 REGION_ACTIVE=0
        _zw_exec_buffer=$command _zw_exec_hash=$hash _zw_exec_end=$token
        _zw_exec_stage=accepted
        _zw_exec_emit accepted "$id" "$fence" "$epoch" "$hash" "$BUFFER"
        zle -R
    elif [[ $kind == submit ]]; then
        if [[ $_zw_exec_stage != accepted || $id != $_zw_exec_id || $fence != $_zw_exec_fence || $epoch != $_zw_exec_epoch || $token != $_zw_exec_hash || $BUFFER != $_zw_exec_buffer ]] || ! _zw_exec_safe; then
            _zw_exec_emit rejected "$id" stale_submit; return 0
        fi
        _zw_exec_stage=submitting
        _zw_exec_emit submitted "$id" "$fence" "$epoch"
        # zsh 5.9's watched-FD poll does not recheck ZLE's done flag until
        # a terminal event returns. Use a private empty keymap for the single
        # host protocol wake byte; no user's key binding is changed.
        zle -K _zw_exec_wake
        zle .accept-line
    elif [[ $kind == revoke ]]; then
        # Never clear a user's line or submit an accepted buffer on revocation.
        _zw_exec_emit revoked host_revoke
        _zw_exec_stage=revoked
    else
        _zw_exec_emit revoked unsupported_request
        _zw_exec_stop
    fi
    return 0
}
_zw_exec_control() {
    local chunk='' count=0 io_status size prefix body
    if sysread -i $_zw_exec_fd -s 8192 -c count chunk; then
        _zw_exec_rx+=$chunk
    else
        io_status=$?
        if (( io_status == 5 )) && [[ ${errnos[$ERRNO]} == EAGAIN || ${errnos[$ERRNO]} == EWOULDBLOCK ]]; then
            _zw_exec_flush; return 0
        fi
        _zw_exec_stop; return 0
    fi
    while (( ${#_zw_exec_rx} >= 8 )); do
        () {
            local LC_ALL=C value field
            local -a values=()
            prefix=${_zw_exec_rx[1,8]}
            [[ ${#prefix} == 8 && $prefix != *[^0-9a-f]* ]] || return 1
            size=$((16#$prefix))
            (( size <= 131072 )) || return 1
            (( ${#_zw_exec_rx} >= size + 8 )) || return 2
            body=${_zw_exec_rx[9,size+8]}
            _zw_exec_rx=${_zw_exec_rx[size+9,-1]}
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
            (( ${#values} >= 6 && ${#values} <= 12 )) || return 1
            [[ $values[1] == 1 && $values[2] == $_zw_session && $values[3] == $_zw_generation && $values[4] == $_zw_nonce ]] || return 1
            (( values[5] > _zw_exec_received )) || return 1
            _zw_exec_received=$values[5]
            _zw_exec_message=("${values[@]:5}")
        }
        io_status=$?
        (( io_status == 2 )) && break
        (( io_status == 0 )) || { _zw_exec_stop; return 0; }
        _zw_exec_request "${_zw_exec_message[@]}"
    done
    _zw_exec_flush
    return 0
}
_zw_exec_preexec() {
    if [[ $_zw_exec_stage == submitting && $1 == $_zw_exec_buffer ]]; then
        _zw_exec_stage=running
        _zw_exec_emit started $_zw_exec_id $_zw_exec_fence
    elif [[ $_zw_exec_stage != idle && $_zw_exec_stage != unavailable ]]; then
        _zw_exec_emit revoked command_mismatch
        _zw_exec_stage=revoked
    fi
    return 0
}
_zw_exec_precmd() {
    local code=$?
    if [[ $_zw_exec_stage == running ]]; then
        local jobs=0
        if (( ${#jobstates} )); then jobs=1; else jobs=4; fi
        if [[ $_zw_exec_scope == session_interval ]] || (( jobs == 0 )); then
            _zw_exec_boundary end "$_zw_exec_end" || { _zw_exec_stop; return 0; }
        fi
        _zw_exec_emit finished $_zw_exec_id $_zw_exec_fence "$code" "$jobs"
        _zw_exec_stage=idle _zw_exec_id=''
    elif [[ $_zw_exec_stage == revoked ]]; then
        _zw_exec_stage=idle _zw_exec_id=''
    fi
    return 0
}
_zw_exec_install() {
    precmd_functions=(${precmd_functions:#_zw_exec_install})
    # A user precmd function executes before the hook array. Its return value
    # cannot be promoted to the command's exit status.
    (( $+functions[precmd] )) && return 0
    [[ -o rcs && -n $_zw_exec_socket ]] || return 0
    zsocket "$_zw_exec_socket" || return 0
    _zw_exec_fd=$REPLY
    local -a original_module_path=("${module_path[@]}")
    module_path=("$_zw_module_dir" "${module_path[@]}")
    zmodload zw_execution
    local loaded=$?
    module_path=("${original_module_path[@]}")
    if (( loaded )); then
        exec {_zw_exec_fd}<&-
        _zw_exec_fd=-1
        return 0
    fi
    bindkey -N _zw_exec_wake
    bindkey -M _zw_exec_wake '^@' .set-mark-command
    zle -N _zw_exec_control
    zle -F -w $_zw_exec_fd _zw_exec_control
    _zw_exec_stage=idle
    preexec_functions=(_zw_exec_preexec ${preexec_functions:#_zw_exec_preexec})
    precmd_functions=(_zw_exec_precmd ${precmd_functions:#_zw_exec_precmd})
    _zw_exec_emit hello "$ZSH_VERSION" ssh_cloexec_boundary_interval_v1
    # hello only identifies the integration. Readiness requires the actual
    # first ZLE line-init, and prepare still revalidates the complete barrier.
    autoload -Uz add-zle-hook-widget
    add-zle-hook-widget line-init _zw_ssh_line_init
    return 0
}
_zw_ssh_line_init() {
    if [[ $_zw_exec_stage == idle && -z $BUFFER ]] && _zw_exec_safe; then
        _zw_exec_emit idle empty_line no_pending shell_foreground
    fi
    return 0
}
typeset -gi _zw_exec_fd=-1 _zw_exec_sequence=0 _zw_exec_received=0 _zw_exec_fence=0 _zw_exec_epoch=0
typeset -g _zw_exec_tx='' _zw_exec_rx='' _zw_exec_id='' _zw_exec_stage=unavailable _zw_exec_buffer='' _zw_exec_hash='' _zw_exec_start='' _zw_exec_end='' _zw_exec_scope=exact
typeset -ga _zw_exec_message=()
precmd_functions+=(_zw_exec_install)
