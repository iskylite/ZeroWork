# Installed through the silent receiver, never through readline/ZLE. Only
# selected when Bash line reads or the Zsh sysread builtin are available.
_zwG() {
    if test -n "${BASH_VERSION-}";then
        IFS= builtin read -r -u 0 -t 4 _zwL||return 1;
    else
        while test "${_zwB#*$'\n'}" = "$_zwB";do
            builtin sysread -i 0 -s 4096 -t 4 _zwC||return 1;
            _zwB+=$_zwC;
            case $_zwB in *$'\003'*) return 1;;esac;
            test "${#_zwB}" -le 4608||return 1;
        done;
        _zwL=${_zwB%%$'\n'*};_zwB=${_zwB#*$'\n'};
    fi;
    test "${#_zwL}" -lt 512||return 1;
    case $_zwL in *$'\003'*) return 1;;esac;
};
