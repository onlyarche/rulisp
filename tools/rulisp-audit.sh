#!/bin/sh
# rulisp-audit.sh ARTIFACT [CRATE_DIR]
#
# BOUNDARY.md §7 as an executable check, for any glue crate:
#   1. the built artifact imports no signal-disposition symbol — a
#      dependency that installs a signal handler destabilises SBCL's
#      signal-driven GC in ways that surface days later; on Windows the
#      analogues are ucrt's signal/raise, SetConsoleCtrlHandler (the
#      console's Ctrl-C ownership) and the unhandled-exception filter and
#      vectored-handler installers;
#   2. with CRATE_DIR: tokio's "signal"/"process" features are off (the
#      latter pulls the SIGCHLD driver), and no `block_on` in the glue
#      sources — every wait must be capped in Rust and looped in Lisp.
# The artifact's FORMAT decides the reader, not the host: ELF via nm,
# Mach-O via Apple's nm or rustup's llvm-nm, PE via rustup's llvm-readobj
# (`rustup component add llvm-tools`) — so a release job on Linux audits
# all twelve assets it attaches. Exit 1 on any finding, and on a format
# it cannot read: the gate never passes by being unable to look.
# Self-test: tools/rulisp-audit-selftest.sh builds a fixture that
# deliberately imports signal() and checks this script rejects it — so
# the gate cannot quietly go inert again (an anchored regex once did
# exactly that: glibc imports read `sigaction@GLIBC_2.2.5`).
set -e
SYMS='sigaction|signal|bsd_signal|sigprocmask|pthread_sigmask'
# `(@|$)` and not `$` alone: versioned glibc imports. `_?` right after the
# start or the separating space: Mach-O's leading underscore — and ONLY a
# leading one. The earlier `(^|[ _])` also matched an inner underscore, so
# `_dispatch_semaphore_signal` (imported by every macOS artifact) read as
# `_signal` and failed every macOS release build.
PATTERN="(^| )_?($SYMS)(@|\$)"
# PE imports as `llvm-readobj --coff-imports` lists them, one per line:
# `  Symbol: SetConsoleCtrlHandler (123)` — the name, then its hint in
# parentheses, so `RaiseException (` cannot match a longer name.
PESYMS='signal|raise|SetConsoleCtrlHandler|SetUnhandledExceptionFilter|AddVectoredExceptionHandler|AddVectoredContinueHandler|RtlAddVectoredExceptionHandler|RaiseException'
PEPATTERN="^ *Symbol: ($PESYMS) \\("
# selftest hooks: symbol lines on stdin, exit 0 iff one is a signal import
[ "$1" = "--match" ] && { grep -Eq "$PATTERN"; exit $?; }
[ "$1" = "--match-pe" ] && { grep -Eq "$PEPATTERN"; exit $?; }

ARTIFACT=$1
CRATE_DIR=$2
[ -n "$ARTIFACT" ] || { echo "usage: rulisp-audit.sh ARTIFACT [CRATE_DIR]"; exit 2; }
[ -f "$ARTIFACT" ] || { echo "FAIL: no such artifact: $ARTIFACT"; exit 1; }

# rustup's llvm-tools component: the one toolset that reads every format
# from every host. llvm_tool NAME prints its path, or nothing.
llvm_tool() {
    lt_sysroot=$( { command -v rustc >/dev/null 2>&1 && rustc --print sysroot; } \
                  || "$HOME/.cargo/bin/rustc" --print sysroot 2>/dev/null || true)
    if [ -n "$lt_sysroot" ] && command -v cygpath >/dev/null 2>&1; then
        lt_sysroot=$(cygpath -u "$lt_sysroot")
    fi
    for lt_t in "$lt_sysroot"/lib/rustlib/*/bin/"$1" "$lt_sysroot"/lib/rustlib/*/bin/"$1".exe; do
        [ -x "$lt_t" ] && { echo "$lt_t"; return 0; }
    done
    command -v "$1" 2>/dev/null || true
}

MAGIC=$(head -c 4 "$ARTIFACT" | od -An -tx1 | tr -d ' \n')
case "$MAGIC" in
    7f454c46) FORMAT=elf ;;
    4d5a*)    FORMAT=pe ;;
    cffaedfe|cefaedfe|feedface|feedfacf|cafebabe|bebafeca) FORMAT=macho ;;
    *) echo "FAIL: $ARTIFACT is not an object file this audit knows (magic $MAGIC)"; exit 1 ;;
esac
case "$FORMAT" in
    elf)
        LIST="nm -D --undefined-only"; PAT=$PATTERN ;;
    macho)
        if [ "$(uname -s)" = Darwin ]; then
            LIST="nm -u"
        else
            LLVMNM=$(llvm_tool llvm-nm)
            [ -n "$LLVMNM" ] || { echo "FAIL: no llvm-nm to read a Mach-O artifact (rustup component add llvm-tools)"; exit 1; }
            LIST="$LLVMNM -u"
        fi
        PAT=$PATTERN ;;
    pe)
        READOBJ=$(llvm_tool llvm-readobj)
        [ -n "$READOBJ" ] || { echo "FAIL: no llvm-readobj to read a PE artifact (rustup component add llvm-tools)"; exit 1; }
        LIST="$READOBJ --coff-imports"; PAT=$PEPATTERN ;;
esac
if $LIST "$ARTIFACT" | grep -Eq "$PAT"; then
    echo "FAIL: $ARTIFACT imports a signal-disposition symbol:"
    $LIST "$ARTIFACT" | grep -E "$PAT"
    exit 1
fi

if [ -n "$CRATE_DIR" ]; then
    CARGO=${CARGO:-cargo}
    command -v "$CARGO" >/dev/null 2>&1 || CARGO="$HOME/.cargo/bin/cargo"
    if "$CARGO" tree --manifest-path "$CRATE_DIR/Cargo.toml" -e features 2>/dev/null \
         | grep -Eq 'tokio feature "(signal|process)"'; then
        echo "FAIL: $CRATE_DIR enables tokio signal/process (pulls the SIGCHLD driver)"; exit 1
    fi
    if ls "$CRATE_DIR"/src/*.rs >/dev/null 2>&1 \
         && grep -v '^[[:space:]]*//' "$CRATE_DIR"/src/*.rs | grep -q 'block_on'; then
        echo "FAIL: block_on in $CRATE_DIR/src — cap the wait in Rust, loop in Lisp"; exit 1
    fi
fi
echo "audit ok: $ARTIFACT ($FORMAT)"
