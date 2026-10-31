# Initialization-only receiver. The client recognizes its exact startup echo;
# payload is read with echo disabled instead of readline/ZLE command editing.
# Restore the exact terminal and INT handler before evaluating the hooks.
_zwR() {
    _zwT=$(command stty -g)||return;
    _zwI=$(builtin trap);
    if test -n "${ZSH_VERSION-}";then builtin setopt localoptions localtraps;fi;
    builtin trap '_zwO=0' INT;
    command stty -echo||{ builtin trap - INT;builtin eval "$_zwI";return;};
    while test "${_zwD-}" != 1;do
        builtin printf %s "$_zwA";
        _zwL=;_zwO=1;
        while :;do
            IFS= builtin read -r "$1" 1 -t 4 _zwC||{ _zwO=0;break;};
            test -z "$_zwC"||test "$_zwC" = $'\n'&&break;
            test "$_zwC" = $'\003'&&{ _zwO=0;break;};
            _zwL+=$_zwC;
        done;
        test "$_zwO" = 1||break;
        builtin eval "$_zwL";
    done;
    _zwO=1;
    command stty "$_zwT"||_zwO=0;
    builtin trap - INT||_zwO=0;
    builtin eval "$_zwI"||_zwO=0;
    test "$_zwO" = 1&&builtin printf '\e]133;P;zw_restored=%s\a' "$2"||_zwO=0;
};
