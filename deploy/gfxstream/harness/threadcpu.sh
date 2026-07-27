#!/system/bin/sh
# Per-thread CPU of the crosvm process. The host decoder is one thread per guest context, so a
# thread near 100% means the proxy is thread-bound whatever the GPU is doing.
#
# Two things this gets wrong if written the obvious way:
#   - /proc/<tid>/stat starts "pid (comm) state ...", and comm can contain spaces. Minecraft's
#     decoder thread is called "Render thread", so splitting on whitespace shifts every field by
#     one and utime/stime are read from the wrong columns -- that thread was reported at ~45% when
#     top -H said 84%. Cut everything up to the last ')' first.
#   - the sample interval is not the requested one. sleep can return early, and the two passes over
#     /proc themselves take time; dividing by the requested duration then scales every number by
#     whatever the difference was, which is how a single thread came out at 128%. Read the real
#     elapsed time from /proc/uptime.
P=${1:-}
# pidof, not pgrep: toybox pgrep -x matches the whole command line rather than comm, so
# `pgrep -x crosvm` never matches a running VM.
[ -z "$P" ] || [ ! -d /proc/$P ] && P=$(pidof crosvm | cut -d' ' -f1)
N=$(pidof crosvm | wc -w)
[ "${N:-0}" -gt 1 ] && echo "WARNING: $N crosvm processes -- numbers from either are meaningless"
[ -d /proc/$P ] || { echo "no crosvm process"; exit 1; }
DUR=${2:-10}

now() { cut -d' ' -f1 /proc/uptime; }
# One read per thread, and the name comes out of stat itself -- a second `cat` per thread doubled
# the time a pass takes, which is time the interval has to account for.
snap() {
  for t in /proc/$P/task/*; do
    s=$(cat $t/stat 2>/dev/null) || continue
    [ -z "$s" ] && continue
    # Escape the parens: mksh parses an unbalanced ( inside ${...#...} as the start of a
    # subshell and dies with "no closing quote".
    n=${s#*\(}; n=${n%%\)*}
    u=$(echo "${s##*\) }" | awk '{print $12+$13}')     # after comm: state is $1, so utime/stime are $12/$13
    [ -n "$u" ] && printf "%s\t%s\t%s\n" "$(basename $t)" "$n" "$u"
  done
}
# Time each pass from its start, not from start-of-A to end-of-B: both passes walk /proc in the
# same order, so a given thread is sampled the same distance into each one, and the interval that
# applies to it is start-to-start. Measuring to the end of B adds a whole pass to the denominator
# and scaled every number down by ~25%.
T0=$(now); snap > /data/local/tmp/tc_a.txt
sleep $DUR
T1=$(now); snap > /data/local/tmp/tc_b.txt
EL=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.2f", b-a}')
echo "(sampled over ${EL}s)"
awk -F'\t' -v dur="$EL" 'NR==FNR{a[$1]=$3; next} ($1 in a){d=$3-a[$1]; p=d/dur; if(p>0.3) printf "%6.1f%%  %-20s tid=%s\n", p, $2, $1}' \
  /data/local/tmp/tc_a.txt /data/local/tmp/tc_b.txt | sort -rn
