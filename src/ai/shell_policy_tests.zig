const std = @import("std");
const permission = @import("permission.zig");
const Verdict = permission.Verdict;

pub const cluster_query =
    \\hostname; whoami; echo "=== VERSION"; clusconf -v 2>&1 | head -2; clusbench -v 2>&1 | head -2; echo "=== CLUS_ROOT"; CLUS_ROOT=$(dirname "$(dirname "$(readlink -f "$(command -v clusbench)")")"); echo "CLUS_ROOT=$CLUS_ROOT"; echo "=== BENCHS"; clusbench --benchs 2>&1 | grep -E "dcu_(dgemm|sgemm|tf32gemm|hgemm|bf16gemm|fp8gemm|int8gemm)|dcu_hsl_mp|rccl_" | head -30
;
pub const heredoc_pipeline = "cat <<'EOF' | grep hello\nhello\nEOF";
pub const heredoc_shell_pipeline = "cat <<'EOF' | sh\nprintf safe\nEOF";
pub const heredoc_python_pipeline = "cat <<'PY' | python3 -\nprint('safe')\nPY";
pub const heredoc_shell_multiple = "sh <<'FIRST' <<'SECOND'\nprintf first\nFIRST\nprintf second\nSECOND";
pub const herestring_shell_pipeline = "cat <<< 'printf safe' | sh";
pub const case_pattern_data = "case x in\n shutdown) printf wrong;;\n x) printf safe;;\nesac";

fn expectAuto(command: []const u8, expected: Verdict) !void {
    try expectRoutes(command, expected, expected);
}

fn expectRoutes(command: []const u8, expected_batch: Verdict, expected_terminal: Verdict) !void {
    const engine: permission.Engine = .{ .mode = .auto };
    for ([_]bool{ false, true }) |grouped| {
        const batch = permission.classify(engine, command, grouped);
        const terminal = permission.classifyTerminal(engine, command, grouped);
        if (batch != expected_batch or terminal != expected_terminal) {
            std.debug.print("\ncommand: {s}\nbatch: expected {s}, found {s}; terminal: expected {s}, found {s}\n", .{ command, @tagName(expected_batch), @tagName(batch), @tagName(expected_terminal), @tagName(terminal) });
        }
        try std.testing.expectEqual(expected_batch, batch);
        try std.testing.expectEqual(expected_terminal, terminal);
    }
}

test "shell policy auto allows the complete cluster query in batch mode" {
    try expectRoutes(cluster_query, .allow_auto, .need_confirm);
    try std.testing.expectEqual(Verdict.need_confirm, permission.classify(.{}, cluster_query, false));
    try std.testing.expectEqual(Verdict.need_confirm, permission.classifyTerminal(.{}, cluster_query, true));
}

test "shell policy distinguishes Bash parameter expansion evaluation" {
    for ([_][]const u8{
        "value=hello; printf '%s' \"${value}\"",
        "value=hello; printf '%s' \"${value:-fallback}\"",
        "value=hello; printf '%s' \"${value:+present}\"",
        "value=hello; printf '%s' \"${value@Q} ${value@E} ${value@U} ${value@L} ${value@a} ${value@A}\"",
        "value=abcdef; printf '%s' \"${value:1:2}\" \"${value: -2}\"",
        "values=(a b); printf '%s' \"${values[0]}\" \"${values[@]}\" \"${#values[@]}\"",
        "values=(a b); printf '%s' \"${#values[0]}\"",
        "values=(a b); printf '%s' \"${!values[@]}\" \"${!values[*]}\"",
        "ZW_SAFE_ONE=1; printf '%s' \"${!ZW_SAFE_*}\" \"${!ZW_SAFE_@}\"",
    }) |command| try expectRoutes(command, .allow_auto, .need_confirm);

    for ([_][]const u8{
        "value=hello; printf '%s' \"${value@P}\"",
        "value=hello; printf '%s' \"${value@P}\"\n",
        "a=one value='hello world'; printf '%s' \"${value@P}\"",
        "value='$(printf safe)'; printf '%s' \"${value@P}\"",
        "value=hello; value='$(shutdown now)' printf '%s' \"${value@P}\"",
        "values=('$(shutdown now)' safe); printf '%s' \"${values[@]@P}\"",
        "value='$(shutdown now)'; cat <<EOF\n${value@P}\nEOF",
        "value=hello\nprintf '%s' \"${value@P}\"",
        "value='$(shutdown now)'\nprintf '%s' \"${value@P}\"",
        "unset other; value='$(shutdown now)'; printf '%s' \"${other:-${value@P}}\"",
        "shopt -u promptvars; value='$(shutdown now)'; printf '%s' \"${value@P}\"",
        "printf '%s' \"${value@P}\"",
        "value=hello; value=\"$RUNTIME\"; printf '%s' \"${value@P}\"",
        "value='$(shutdown now)'; false && value=safe; printf '%s' \"${value@P}\"",
        "value='$(shutdown now)'; value=safe & wait; printf '%s' \"${value@P}\"",
        "value='$(shutdown now)'; (value=safe); printf '%s' \"${value@P}\"",
        "value=hello | cat; printf '%s' \"${value@P}\"",
        "if false; then value=hello; fi; printf '%s' \"${value@P}\"",
        "value=hello; other=\"$RUNTIME\"; printf '%s' \"${value@P}\"",
        "value=hello; printf safe; printf '%s' \"${value@P}\"",
        "value='\\$(shutdown now)'; printf '%s' \"${value@P}\"",
        "value=~; printf '%s' \"${value@P}\"",
        "value=abcdef; values=(1); n='values[$(shutdown now)]'; printf '%s' \"${value:n:1}\"",
        "value=abcdef; values=(1); n='values[$(shutdown now)]'; printf '%s' \"${value:1:n}\"",
        "values=(x); n='values[$(shutdown now)]'; printf '%s' \"${#values[n]}\"",
        "values=(x); declare -n ref='values[$(shutdown now)]'; printf '%s' \"$ref\"",
        "declare -n ref=value; value=hello; printf '%s' \"$ref\"",
        "printf '%s' \"${ printf safe; }\"",
        "printf '%s' \"${| REPLY=safe; }\"",
        "cat <<EOF | grep safe\n${ printf safe; }\nEOF",
    }) |command| try expectAuto(command, .need_confirm);

    for ([_][]const u8{
        "value='$(shutdown now)'; printf '%s' \"${value@P}\"",
        "value='`shutdown now`'; printf '%s' \"${value@P}\"",
        "value='\"$(shutdown now)\"'; printf '%s' \"${value@P}\"",
        "value='$(shutdown now)'; value=hello printf '%s' \"${value@P}\"",
        "printf '%s' \"${ shutdown now; }\"",
        "printf '%s' \"${| shutdown now; }\"",
        "printf '%s' \"${\nshutdown now;\n}\"",
        "printf '%s' \"${ printf safe | shutdown now; }\"",
        "printf '%s' \"${ printf '}'; shutdown now; }\"",
        "printf '%s' \"${ { shutdown now; }; }\"",
        "printf '%s' \"${ printf '%s' \"$(shutdown now)\"; }\"",
        "printf '%s' \"${ printf '%s' \"${HOME}\"; shutdown now; }\"",
        "cat <<EOF | grep safe\n${ shutdown now; }\nEOF",
        "cat <<EOF | grep safe\n${| shutdown now; }\nEOF",
    }) |command| try expectAuto(command, .deny_exec_copy_only);
}

test "shell policy recognizes common shell structure without command allowlists" {
    for ([_][]const u8{
        "command -v clusbench",
        "command -V shutdown",
        "command -pv shutdown",
        "builtin command -v shutdown",
        "printf '%s\\n' alpha | grep -E 'alpha|beta'",
        "(printf a; printf b) | cat",
        "{ printf a; printf b; }",
        "if [ -d /tmp ]; then printf yes; else printf no; fi",
        "cat <(printf '%s\\n' sample)",
        "cat <<'EOF'\n$(shutdown now)\nEOF",
        "printf done 2>&1 | head -2",
        "cat 0<>/tmp/shell-policy-fixture",
        "printf '%s\\n' {alpha,beta}",
        "bash -c 'printf safe'",
        "trap 'printf done' EXIT",
        "trap -- 'printf done' EXIT",
        "trap - EXIT",
        "trap -p EXIT",
        "eval -- 'printf done'",
        "\"coproc\" shutdown now",
        "printf '%s' 'a[$(shutdown now)]'",
        "unset -f 'a[$(shutdown now)]'",
        "let '1 + 2'",
        "printf '%s' \"$((1+2*3))\"",
        "((1+2))",
        "if ((1)); then printf safe; fi",
        "for ((;;)); do break; done",
        "printf '%s' \"$[1+2]\"",
        "cat <<EOF\n$[1+2]\nEOF",
        "printf '%s' '${!ref}'",
        "noglob printf safe",
        "nocorrect printf safe",
        "repeat 2 printf safe",
        "rm -- -rf /tmp/shell-policy-fixture",
    }) |command| try expectAuto(command, .allow_auto);
}

test "shell policy recognizes here documents across commands and pipelines" {
    for ([_][]const u8{
        "grep hello <<EOF\nhello\nEOF",
        "cat <<EOF | grep hello\nhello\nEOF",
        heredoc_pipeline,
        "cat <<EOF | (grep hello; cat)\nhello\nEOF",
        "cat <<EOF | xargs -n 1 grep hello\nfile\nEOF",
        "cat <<EOF | xargs -n1 grep hello\nfile\nEOF",
        "cat <<EOF | xargs -0rn1 grep hello\nfile\nEOF",
        "cat <<EOF | xargs --max-args=1 grep hello\nfile\nEOF",
        "cat <<EOF | xargs -I '{}' printf '%s' '{}'\nhello\nEOF",
        "cat <<EOF | xargs -I {} printf '%s' {}\nhello\nEOF",
        "grep hello <<END-1\nhello\nEND-1",
        "grep hello <<'END MARK'\nhello\nEND MARK",
        "cat <<''\nhello\n\n",
        "grep hello <<E\"O\"F\nhello\nEOF",
        "grep hello <<\\EOF\n$HOME\nEOF",
        "grep hello <<$MARKER\nhello\n$MARKER",
        "cat <<FIRST <<SECOND\nfirst\nFIRST\nsecond\nSECOND",
        "cat <<'FIRST' <<'SECOND' | cat\nshutdown now\nFIRST\nprintf done\nSECOND",
        "cat <<FIRST | grep second <<SECOND\nfirst\nFIRST\nsecond\nSECOND",
        "cat <<EOF && printf done\nhello\nEOF",
        "cat <<EOF; printf done\nhello\nEOF",
        "cat <<EOF\ntwo backslashes \\\\\nEOF",
        "cat <<EOF\nhello\\\n world\nEOF",
        "cat <<EOF\nhello\nE\\\nOF",
        "cat <<-EOF\nE\\\n\tOF\nhello\nEOF",
        "sh <<'EOF'\nprintf done\nEOF",
        "cat <<'EOF' | bash\nprintf done\nEOF",
        "cat <<'EOF' | cat - | sh -s\nprintf done\nEOF",
        "printf '%s' PATH=/tmp; cat <<'EOF' | sh\nprintf done\nEOF",
        "bash 0<<'EOF' | cat\nprintf done\nEOF",
        "sh <<'FIRST' <<'SECOND'\nprintf first\nFIRST\nprintf done\nSECOND",
        "sh 3<<'FIRST' 0<<'SECOND'\nshutdown now\nFIRST\nprintf done\nSECOND",
        "cat <<'FIRST' | sh <<'SECOND'\nprintf first\nFIRST\nprintf done\nSECOND",
        "cat <<'EOF' |\nprintf done\nEOF\nsh",
        "cat <<'FIRST' |\nprintf first\nFIRST\ncat <<'SECOND' |\nprintf done\nSECOND\nsh",
        "sh <<- 'EOF'\n\tprintf done\n\tEOF",
        "sh <<< 'printf done'",
        "cat <<< 'printf done' | sh",
        "cat <<< 'printf first' | sh <<< 'printf second'",
        "sh <<< ''",
        "python3 <<'PY'\nprint('hello')\nPY",
        "python3.11 - <<'PY'\nname = 'world'\nprint('hello', name)\nPY",
        "python3 <<'PY'\nvalue = 1 + 2\nprint(\n    'shutdown now',\n    value * 2,\n)\nPY",
        "python3 <<'PY'\n# -*- coding: utf-8 -*-\nprint('hello')\nPY",
        "cat <<'PY' | python3 -u\nprint('hello')\nPY",
        "python3 <<'PY'\nimport os\nos.system('printf safe')\nPY",
        "python3 <<'PY'\nimport os as operating_system\noperating_system.system('printf safe')\nPY",
        "python3 <<'PY'\nfrom subprocess import run as execute\nexecute(['printf', 'safe'])\nPY",
        "cat <<'PY' | python3\nimport subprocess\nsubprocess.run(['printf', 'safe'], check=True)\nPY",
        "sh <<'EOF'\npython3 -c \"print('hello')\"\nEOF",
        "python3 -V <<EOF\nignored\nEOF",
    }) |command| try expectAuto(command, .allow_auto);
}

test "live shell variable accesses require exact approval while batch retains its policy" {
    for ([_][]const u8{
        "value=hello",
        "value=hello printf '%s' literal",
        "if true; then value=hello; fi",
        "(value=hello)",
        "printf '%s' \"$(value=hello; printf yes)\"",
        "cat <(value=hello; printf yes)",
        "eval -- 'value=hello'",
        "bash --noprofile --norc -c 'value=hello; printf \"%s\" \"$value\"'",
        "sh <<'EOF'\nvalue=hello\nEOF",
        "trap 'value=hello' EXIT",
        "command -v \"$PROGRAM\"",
        "PATH=/usr/bin command -v clusbench",
        "hostname; whoami; printf '%s\\n' \"$HOME\"",
        "VALUE=$(printf '%s' sample); printf '%s\\n' \"$VALUE\"",
        "for file in /tmp/*; do printf '%s\\n' \"$file\"; done",
        "printf '%s' \"${array[0]}\"",
        "printf '%s' \"${value:-@P}\"",
        "printf '%s' \"${value:=fallback}\"",
        "printf '%s' literal > \"$value\"",
        "export X='a[$(shutdown now)]'",
        "getopts 'a[$(shutdown now)]' result",
        "declare -i count=1; count=2",
        "builtin printf -v value '%s' literal",
        "printf -- '%3n' value",
        "read -r value <<< literal",
        "read <<< literal",
        "mapfile items",
        "unset value",
        "[[ -v value ]]",
        "[[ value -eq 1 ]]",
        "grep hello <<EOF\n$HOME ${USER:-guest}\nEOF",
        "PATH=/tmp; /bin/cat <<'EOF' | sh\nprintf done\nEOF",
        "OUT=$(cat <<'EOF'\nhello (world)\nEOF\n); printf '%s' \"$OUT\"",
        "OUT=$(cat <<EOF | grep hello\n$HOME hello\nEOF\n); printf '%s' \"$OUT\"",
    }) |command| try expectRoutes(command, .allow_auto, .need_confirm);

    const engine: permission.Engine = .{ .mode = .auto };
    for ([_][]const u8{ "value+=hello", "value[0]=hello", "val\\\nue=hello", "printf '%s' \"$\\\nvalue\"" }) |command| {
        try std.testing.expectEqual(Verdict.need_confirm, permission.classifyTerminal(engine, command, false));
    }

    for ([_][]const u8{
        "df -h; hostname; whoami",
        "printf '%s\\n' alpha | grep -E 'alpha|beta' | head -1",
        "printf '%s' 'value=hello ${value@P}'",
        "printf '%s' \"\\$value\" \"$?\" \"$1\"",
        "printf '%%n'",
        "declare -pn value",
        "env ZW_LABEL=hello printf '%s' safe",
        "/bin/bash --noprofile --norc -c 'value=hello; printf \"%s\" \"$value\"'",
    }) |command| try expectAuto(command, .allow_auto);

    for ([_][]const u8{ "value=hello; shutdown now", "value+=hello shutdown now", "printf '%s' \"$value\" | shutdown now" }) |command| {
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, permission.classifyTerminal(engine, command, false));
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, permission.classifyTerminal(.{}, command, false));
    }
}

test "shell policy checks executable here document expansions and consumers" {
    for ([_][]const u8{
        "grep hello <<EOF\n$(shutdown now)\nEOF",
        "cat <<EOF | grep hello\n`shutdown now`\nEOF",
        "cat <<FIRST | grep second <<SECOND\n$(shutdown now)\nFIRST\nsecond\nSECOND",
        "cat <<FIRST | grep second <<SECOND\nfirst\nFIRST\n$(shutdown now)\nSECOND",
        "grep hello <<EOF\n${VALUE:-$(shutdown now)}\nEOF",
        "cat <<'EOF' | shutdown now\nhello\nEOF",
        "cat <<'EOF' | bash -c 'shutdown now'\nhello\nEOF",
        "cat <<'EOF' | xargs -n 1 shutdown now\nhello\nEOF",
        "cat <<'EOF' | xargs -n1 shutdown now\nhello\nEOF",
        "cat <<'EOF' | xargs -0rn1 shutdown now\nhello\nEOF",
        "cat <<'EOF' | xargs --max-args=1 shutdown now\nhello\nEOF",
        "cat <<'EOF' | xargs --replace shutdown now\nhello\nEOF",
        "cat <<'EOF' | xargs -I '{}' sh -c 'shutdown now'\nhello\nEOF",
        "cat <<'EOF' | xargs -I '{}' shutdown '{}'\nhello\nEOF",
        "cat <<'EOF' | xargs -I{} shutdown {}\nhello\nEOF",
        "sh <<'EOF'\nshutdown now\nEOF",
        "cat <<'EOF' | bash\nrm -rf /tmp/shell-policy-fixture\nEOF",
        "cat <<'EOF' |\nshutdown now\nEOF\nsh",
        "cat <<'FIRST' |\nprintf done\nFIRST\ncat <<'SECOND' |\nshutdown now\nSECOND\nsh",
        "sh <<EOF\necho \\$(shutdown now)\nEOF",
        "sh <<'FIRST' <<'SECOND'\nprintf done\nFIRST\nshutdown now\nSECOND",
        "sh <<'FIRST' <<'SECOND'\nshutdown now\nFIRST\nprintf done\nSECOND",
        "sh <<'FIRST' <<'SECOND'\nshut\\\nFIRST\ndown now\nSECOND",
        "cat <<'FIRST' | sh <<'SECOND'\nshutdown now\nFIRST\nprintf done\nSECOND",
        "cat /tmp/shell-policy-script | sh <<'EOF'\nshutdown now\nEOF",
        "cat <<'FIRST' |\nshutdown now\nFIRST\ncat <<'SECOND' |\nprintf done\nSECOND\nsh",
        "sh <<< 'shutdown now'",
        "cat <<< 'shutdown now' | sh",
        "cat <<< 'shutdown now' | sh <<< 'printf safe'",
        "cat <<< 'shut\\' | sh <<< 'down now'",
        "sh 3<<'FIRST' 0<<'SECOND'\nprintf done\nFIRST\nshutdown now\nSECOND",
        "python3 <<'PY'\nimport os\nos.system('shutdown now')\nPY",
        "python3 <<'PY'\nimport os\nos.system('shut\\x64own now')\nPY",
        "python3 <<'PY'\nimport os\nos.system('\\163hutdown\\u0020now')\nPY",
        "python3 <<'PY'\nimport os\nos.system('printf safe\\nshutdown now')\nPY",
        "cat <<'PY' | python3 -\nimport subprocess\nsubprocess.run(['rm', '-rf', '/tmp/shell-policy-fixture'])\nPY",
        "python3 <<'PY'\nimport subprocess\nsubprocess.run('shutdown now', shell=True)\nPY",
        "python3 <<'PY'\nfrom subprocess import run as execute\nexecute(['shutdown', 'now'])\nPY",
        "python3 <<'PY'\nfrom subprocess import run as print\nprint(['shutdown', 'now'])\nPY",
        "python3 <<'PY'\nfrom subprocess import run as execute\nexecute(['shutdown', 'now'])\nimport os as execute\nPY",
        "python3 <<'PY'\nimport subprocess\nsubprocess.run(['env', 'PATH=/usr/bin', 'shutdown', 'now'])\nPY",
        "python3 <<'PY'\nimport subprocess\nsubprocess.run(['sh', '-c', 'shutdown now'])\nPY",
        "python3 <<'PY'\nimport subprocess\nsubprocess.run(['python3', '-c', \"import os; os.system('shutdown now')\"])\nPY",
        "sh <<'EOF'\npython3 -c \"import os; os.system('shutdown now')\"\nEOF",
        "python3 <<'PY'\nunknown()\nos.system('shutdown now')\nPY",
        "sh <<'EOF'\nalias danger='shutdown now'\ndanger\nEOF",
        "trap 'shutdown now' EXIT",
        "trap -- 'shutdown now' EXIT",
        "(trap 'shutdown now' EXIT; printf done)",
        "sh <<'EOF'\ntrap 'shutdown now' EXIT\nEOF",
        "cat <<'EOF' | sh\ntrap 'shutdown now' EXIT\nEOF",
        "trap 'printf \"%s\" \"$(shutdown now)\"' EXIT",
        "eval -- 'shutdown now'",
        "coproc shutdown now",
        "coproc shutdown now | cat",
        "noglob shutdown now",
        "nocorrect shutdown now",
        "repeat 1 shutdown now",
        "repeat \"$COUNT\" shutdown now",
        "a=(x); unset 'a[$(shutdown now)]'",
        "a=(x); read -r 'a[$(shutdown now)]' <<<'x'",
        "a=(x); printf -v 'a[$(shutdown now)]' '%s' x",
        "declare 'a[$(shutdown now)]=x'",
        "typeset 'a[$(shutdown now)]=x'",
        "a=(x); set -- -a; getopts a 'a[$(shutdown now)]'",
        "let 'a[$(shutdown now)]=1'",
        "printf '%s' \"$(( $(shutdown now) + 1 ))\"",
        "(( $(shutdown now) ))",
        "for ((i=$(shutdown now); i<1; i++)); do :; done",
        "printf '%s' \"$[ $(shutdown now) ]\"",
        "cat <<EOF\n$[ $(shutdown now) ]\nEOF",
        "printf '%s' \"${array[$(shutdown now)]}\"",
        "a=(x); declare -i x='a[$(shutdown now)]'",
        "a=(x); typeset -i x='a[$(shutdown now)]'",
        "a=(x); integer x='a[$(shutdown now)]'",
        "a=(x); float x='a[$(shutdown now)]'",
        "a=(x); declare -i x; x='a[$(shutdown now)]'",
        "a=(x); typeset -i x\nx='a[$(shutdown now)]'",
        "printf '%s' \"$(grep hello <<EOF\n$(shutdown now)\nEOF\n)\"",
        "grep hello <<EOF\n$\\\n(shutdown now)\nEOF",
        "grep hello <<EOF\n`shut\\\ndown now`\nEOF",
        "cat <<-EOF\nE\\\n\tOF\n'$(shutdown now)'\nEOF",
    }) |command| try expectAuto(command, .deny_exec_copy_only);
    for ([_][]const u8{
        "cat <<'EOF' | xargs -0 sh\nprintf done\nEOF",
        "cat <<'EOF' | xargs sh -c\nshutdown now\nEOF",
        "cat <<'EOF' | xargs rm -rf\n/\nEOF",
        "cat <<'EOF' | xargs env\nshutdown\nEOF",
        "cat <<'EOF' | xargs -I '{}' '{}'\nshutdown\nEOF",
        "cat <<'EOF' | xargs -I '{}' sh -c '{}'\nshutdown now\nEOF",
        "cat <<'EOF' | xargs -I{} sh -c {}\nshutdown now\nEOF",
        "cat <<'EOF' | xargs -I '{}' python3 -c '{}'\nprint('hello')\nEOF",
        "cat <<'EOF' | xargs -I '{}' rm -rf '{}'\n/\nEOF",
        "cat <<'EOF' | xargs --replace sh -c '{}'\nshutdown now\nEOF",
        "cat <<'EOF' | xargs --replace='{}' sh -c '{}'\nshutdown now\nEOF",
        "cat <<'EOF' | xargs command -v clusbench\nhello\nEOF",
        "sh 3<<'EOF'\nshutdown now\nEOF",
        "sh <<'EOF' </dev/null\nshutdown now\nEOF",
        "cat <<'EOF' > /tmp/shell-policy-fixture | sh\nshutdown now\nEOF",
        "cat <<'EOF' | grep . | sh\nshutdown now\nEOF",
        "cat /tmp/shell-policy-script | sh <<'EOF'\nprintf safe\nEOF",
        "sh </tmp/shell-policy-script <<'EOF'\nprintf safe\nEOF",
        "cat -- -- <<'EOF' | sh\nprintf safe\nEOF",
        "cat() { printf 'shutdown now\\n'; }; cat <<'EOF' | sh\nprintf safe\nEOF",
        "alias cat='printf shutdown'; cat <<'EOF' | sh\nprintf safe\nEOF",
        "PATH=/tmp; cat <<'EOF' | sh\nprintf safe\nEOF",
        "export PATH=/tmp; cat <<'EOF' | sh\nprintf safe\nEOF",
        "cat <<'EOF' |& sh\nshutdown now\nEOF",
        "cat <<'EOF' |\nsh\nprintf done\nEOF",
        "sh <<EOF\n$SCRIPT\nEOF",
        "sh <<< \"$SCRIPT\"",
        "sh <<< ~",
        "trap \"$ACTION\" EXIT",
        "let x",
        "a=(x); n='a[$(shutdown now)]'; printf '%s' \"$((n))\"",
        "a=(x); n='a[$(shutdown now)]'; ((n))",
        "a=(x); n='a[$(shutdown now)]'; for ((i=0; i<n; i++)); do :; done",
        "a=(x); n='a[$(shutdown now)]'; printf '%s' \"$[n]\"",
        "a=(x); ref='a[$(shutdown now)]'; printf '%s' \"${!ref}\"",
        "printf '%s' \"${value@P}\"",
        "printf '%s' \"${array[index]}\"",
        "cat <<EOF\n$((n+1))\nEOF",
        "unset 'a[index]'",
        "declare -i count; count=\"$VALUE\"",
        "read -r \"$NAME\" <<< value",
        "repeat \"$COUNT\" printf safe",
        "python3 <<'PY'\nexec(input())\nPY",
        "python3 <<'PY'\nimport os\nos.system(command)\nPY",
        "python3 <<'PY'\nfrom subprocess import run as print\nprint(command)\nPY",
        "python3 <<'PY'\nimport os\nos.system('shut\\N{LATIN SMALL LETTER D}own now')\nPY",
        "python3 <<PY\nprint('$VALUE')\nPY",
        "python3 <<'PY'\n# coding marker; coding: utf-7\nprint('SAFE+ACcAKQA7-')\nPY",
        "node <<'JS'\nconsole.log('hello')\nJS",
        "sh <<'EOF'\nnode -e 'some_code()'\nEOF",
        "grep hello <<EOF\n${VALUE@P}\nEOF",
        "grep hello <<EOF\n${(e)VALUE}\nEOF",
        "cat <<FIRST <<SECOND\nfirst\nFIRST\nmissing second",
        "OUT=$(cat <<EOF\nmissing delimiter\n)",
        "OUT=$(cat <<'EOF'\nhello ) world\nEOF\n)",
        "OUT=$(cat <<'EOF'\ndon't panic\nEOF\n)",
    }) |command| try expectAuto(command, .need_confirm);
}

test "shell policy checks executable commands across nested syntax" {
    for ([_][]const u8{
        "rm -rf /",
        "printf safe; rm --recursive --force /tmp/shell-policy-fixture",
        "command -- shutdown now",
        "command -p shutdown now",
        "env PATH=/usr/bin command shutdown now",
        "echo \"$(shutdown now)\"",
        "command -v \"$(shutdown now)\"",
        "cat <(sudo -u root /sbin/shutdown now)",
        "bash -lc 'printf safe; rm -rf /tmp/shell-policy-fixture'",
        "bash -c 'shutdown now' <(printf done)",
        "sh -c 'shutdown now' <<'EOF'\ntext\nEOF",
        "cat <<EOF\n$(shutdown now)\nEOF",
        "cat <<EOF\n`shutdown now`\nEOF",
        "rm -r 2>&1 -f /tmp/shell-policy-fixture",
        "printf safe | env -- shutdown now",
        "r\\\nm --recursive --force /tmp/shell-policy-fixture",
        "rm -rf /tmp/shell-policy-fixture/*",
    }) |command| {
        try expectAuto(command, .deny_exec_copy_only);
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, permission.classify(.{}, command, false));
    }
}

test "shell policy distinguishes case patterns from executable commands" {
    for ([_][]const u8{
        case_pattern_data,
        "case x in\n x|shutdown) printf safe;;\nesac",
        "case x in ('esac') printf wrong;; (x) printf safe;; esac",
        "case x in\n x) printf safe\nesac",
        "case x in esac | printf safe",
        "case x in esac|x) printf safe;; esac",
        "case x\nin x) printf safe;; esac",
        "if case x in x) printf safe;; esac; then printf done; fi",
        "case x in x) case y in shutdown) printf wrong;; y) printf safe;; esac;; esac",
        "\"case\" shutdown now",
    }) |command| try expectAuto(command, .allow_auto);
    for ([_][]const u8{
        "case x in x) shutdown now;; esac",
        "case x in esac | shutdown now",
        "case x in\n x|shutdown) shutdown now;;\nesac",
        "case x in x) printf safe ;& shutdown) shutdown now;; esac",
        "case x in x) case y in y) shutdown now;; esac;; esac",
        "case x in x) eval -- 'shutdown now';; esac",
        "case x in x) sh <<'EOF'\nshutdown now\nEOF\n;; esac",
    }) |command| try expectAuto(command, .deny_exec_copy_only);
    try expectAuto("case x in x) printf safe", .need_confirm);
}

test "shell policy handles comments across interactive and nested shells" {
    for ([_][]const u8{
        "printf safe # ordinary comment",
        "printf '%s' \"$(printf foo#bar)\"",
        "sh -c '# explanation; shutdown now'",
        "sh -i -c 'printf safe # ; shutdown now'",
        "trap 'printf safe # ; shutdown now' EXIT",
        "sh <<'EOF'\n# explanation; shutdown now\nprintf safe\nEOF",
        "sh <<'EOF'\nprintf '%s' \"$(printf x # )\nprintf safe\n)\"\nEOF",
    }) |command| try expectAuto(command, .allow_auto);
    try expectRoutes("eval 'printf safe # ; shutdown now'", .allow_auto, .deny_exec_copy_only);
    for ([_][]const u8{
        "printf safe # ; shutdown now",
        "printf safe # $(shutdown now)",
        "# $(shutdown now)",
        "printf '%s' \"$(printf x # )\nshutdown now\n)\"",
        "printf '%s' \"$(printf x # comment\nshutdown now\n)\"",
        "zsh -i <<'EOF'\nprintf safe # ; shutdown now\nEOF",
        "eval 'printf safe # comment\nshutdown now'",
        "trap 'printf safe # comment\nshutdown now' EXIT",
    }) |command| try expectAuto(command, .deny_exec_copy_only);
}

test "shell policy asks only when the executable or nested script cannot be inspected" {
    for ([_][]const u8{
        "\"$COMMAND\" --version",
        "r${EMPTY}m -rf /tmp/shell-policy-fixture",
        "r{m,} -rf /tmp/shell-policy-fixture",
        "r? -rf /tmp/shell-policy-fixture",
        "eval \"$SCRIPT\"",
        "sh -c \"$SCRIPT\"",
        "python3 -c \"$SCRIPT\"",
        "sh /tmp/shell-policy-script",
        "source /tmp/shell-policy-script",
        "printf '%s' ${(e)value}",
        "sudo --host remote rm -rf /tmp/shell-policy-fixture",
        "sudo command -v clusbench",
        "env command -v clusbench",
        "/tmp/command -v clusbench",
        "sh < <(printf done)",
        "cat <<<",
        "cat <<EOF\nmissing end",
    }) |command| try expectAuto(command, .need_confirm);
}

test "shell policy bounds malformed and oversized commands" {
    try expectAuto("printf 'unterminated", .need_confirm);
    try expectAuto("printf a\x00shutdown now", .need_confirm);
    var oversized: [65535]u8 = @splat('a');
    try expectAuto(&oversized, .need_confirm);
}

test "shell policy bounds nested case structure" {
    const allocator = std.testing.allocator;
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);
    for (0..17) |_| try command.appendSlice(allocator, "case x in x) ");
    try command.appendSlice(allocator, "printf safe");
    for (0..17) |_| try command.appendSlice(allocator, ";; esac");
    try expectAuto(command.items, .need_confirm);
}

test "shell policy bounds here document count and delimiter size" {
    const allocator = std.testing.allocator;
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);
    try command.appendSlice(allocator, "cat");
    for (0..33) |_| try command.appendSlice(allocator, " <<END");
    try command.appendSlice(allocator, "\n");
    for (0..33) |_| try command.appendSlice(allocator, "END\n");
    try expectAuto(command.items, .need_confirm);

    command.clearRetainingCapacity();
    try command.appendSlice(allocator, "cat <<");
    for (0..257) |_| try command.append(allocator, 'E');
    try command.appendSlice(allocator, "\n");
    for (0..257) |_| try command.append(allocator, 'E');
    try expectAuto(command.items, .need_confirm);

    command.clearRetainingCapacity();
    try command.appendSlice(allocator, "sh");
    for (0..33) |_| try command.appendSlice(allocator, " <<< 'printf safe'");
    try expectAuto(command.items, .need_confirm);
}

test "shell policy bounds interpreter script analysis" {
    const allocator = std.testing.allocator;
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);
    try command.appendSlice(allocator, "python3 <<'PY'\n");
    for (0..2100) |_| try command.appendSlice(allocator, "pass\n");
    try command.appendSlice(allocator, "PY\n");
    try expectAuto(command.items, .need_confirm);

    command.clearRetainingCapacity();
    try command.appendSlice(allocator, "python3 <<'PY'\nprint(");
    for (0..18) |_| try command.append(allocator, '[');
    try command.append(allocator, '1');
    for (0..18) |_| try command.append(allocator, ']');
    try command.appendSlice(allocator, ")\nPY\n");
    try expectAuto(command.items, .need_confirm);
}

test "shell policy dispatch preserves the complete command and target checks" {
    const scope_mod = @import("tool_scope.zig");
    const Fake = struct {
        count: usize = 0,
        expected_command: []const u8 = cluster_query,
        fn invoke(raw: *anyopaque, tool: scope_mod.Tool, target: u64, command: []const u8, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(scope_mod.Tool.run_command, tool);
            try std.testing.expectEqual(@as(u64, 101 + self.count % 2), target);
            try std.testing.expectEqualStrings(self.expected_command, command);
            self.count += 1;
        }
    };
    var fake: Fake = .{};
    const scope: scope_mod.Scope = .{ .owner = .{ .group = 7 }, .members = .{ .ids = .{ 101, 102 } ++ @as([14]u64, @splat(0)), .len = 2 } };
    var call: scope_mod.Call = .{ .tool = .run_command, .command = cluster_query, .targets = try scope.validate(&.{ 101, 102 }) };
    const dispatcher: scope_mod.Dispatcher = .{ .ctx = &fake, .invoke = Fake.invoke };

    try std.testing.expectError(error.ToolApprovalRequired, dispatcher.dispatch(scope, scope, call, .{}, false));
    try std.testing.expectEqual(@as(usize, 0), fake.count);
    try dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, false);
    try std.testing.expectEqual(@as(usize, 2), fake.count);
    fake.expected_command = heredoc_pipeline;
    call.command = heredoc_pipeline;
    try dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, false);
    try std.testing.expectEqual(@as(usize, 4), fake.count);
    fake.expected_command = heredoc_shell_pipeline;
    call.command = heredoc_shell_pipeline;
    try dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, false);
    try std.testing.expectEqual(@as(usize, 6), fake.count);
    fake.expected_command = heredoc_python_pipeline;
    call.command = heredoc_python_pipeline;
    try dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, false);
    try std.testing.expectEqual(@as(usize, 8), fake.count);
    fake.expected_command = heredoc_shell_multiple;
    call.command = heredoc_shell_multiple;
    try dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, false);
    try std.testing.expectEqual(@as(usize, 10), fake.count);
    fake.expected_command = herestring_shell_pipeline;
    call.command = herestring_shell_pipeline;
    try dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, false);
    try std.testing.expectEqual(@as(usize, 12), fake.count);
    fake.expected_command = case_pattern_data;
    call.command = case_pattern_data;
    try dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, false);
    try std.testing.expectEqual(@as(usize, 14), fake.count);

    var stale = scope;
    stale.members.len = 1;
    try std.testing.expectError(error.TargetOutsideAssistant, dispatcher.dispatch(stale, scope, call, .{ .mode = .auto }, false));
    call.command = "command -- shutdown now";
    try std.testing.expectError(error.ToolExecutionDenied, dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, true));
    call.command = "cat <<'EOF' | sh\nshutdown now\nEOF";
    try std.testing.expectError(error.ToolExecutionDenied, dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, true));
    call.command = "sh <<'FIRST' <<'SECOND'\nshutdown now\nFIRST\nprintf safe\nSECOND";
    try std.testing.expectError(error.ToolExecutionDenied, dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, true));
    call.command = "cat <<< 'shutdown now' | sh";
    try std.testing.expectError(error.ToolExecutionDenied, dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, true));
    call.command = "trap 'shutdown now' EXIT";
    try std.testing.expectError(error.ToolExecutionDenied, dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, true));
    call.command = "printf safe # ; shutdown now";
    try std.testing.expectError(error.ToolExecutionDenied, dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, true));
    call.command = "printf '%s' \"$(printf x # )\nshutdown now\n)\"";
    try std.testing.expectError(error.ToolExecutionDenied, dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, true));
    call.command = "python3 <<'PY'\nimport os\nos.system('shutdown now')\nPY";
    try std.testing.expectError(error.ToolExecutionDenied, dispatcher.dispatch(scope, scope, call, .{ .mode = .auto }, true));
    try std.testing.expectEqual(@as(usize, 14), fake.count);
}
