_zwG() {
while :;do
IFS= builtin read -r -u 0 "$1" 1 -t 4 _zwC||return 1;
case $_zwC in ''|$'\n') return;;$'\003') return 1;;esac;
_zwL+=$_zwC;
done;
};
# Initialization-only receiver. The client recognizes its exact startup echo;
# payload is read with echo disabled instead of readline/ZLE command editing.
# Restore the exact terminal and INT handler before evaluating the hooks.
_zwR() {
    _zwD=0;
    _zwT=$(command stty -g)||return;
    _zwI=$(builtin trap);
    [[ ! ${ZSH_VERSION-} ]]||builtin emulate -L zsh;
    builtin trap '_zwD=-1;_zwA=' INT;
    # Noncanonical input applies PTY backpressure to batches instead of
    # discarding unread canonical lines when the terminal input queue fills.
    command stty -echo -icanon min 1 time 0||{ builtin trap - INT;builtin eval "$_zwI";return;};
    while ((_zwD<1));do
        ((_zwD<0))||builtin printf %s "$_zwA";
        _zwL=;
        _zwG "$1"||{ _zwD=-1;_zwA=;};
        if ((_zwD<0));then
            [[ $_zwL = "$2" ]]&&break;
        else
            builtin eval "$_zwL";
        fi;
    done;
    command stty "$_zwT"||_zwD=0;
    builtin trap - INT||_zwD=0;
    builtin eval "$_zwI"||_zwD=0;
    (( _zwD ))&&builtin printf '\e]133;P;zw_restored=%s\a' "$2"||_zwD=0;
};
