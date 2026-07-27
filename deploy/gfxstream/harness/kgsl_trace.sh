#!/system/bin/sh
# Capture the KGSL timestamp-wait path from the kernel's own tracepoints.
#
# All runtime state: nothing here survives a reboot, and tracing is turned back off at the end.
T=/sys/kernel/tracing
DUR=${1:-3}
echo 0 > $T/tracing_on
echo > $T/trace
echo 8192 > $T/buffer_size_kb
for e in kgsl/kgsl_waittimestamp_entry kgsl/kgsl_waittimestamp_exit \
         kgsl/adreno_drawctxt_wait_start kgsl/adreno_drawctxt_wait_done \
         kgsl/kgsl_active_count kgsl/kgsl_pwr_set_state; do
    echo 1 > $T/events/$e/enable 2>/dev/null
done
echo 1 > $T/tracing_on
sleep $DUR
echo 0 > $T/tracing_on
cp $T/trace /data/local/tmp/kgsl_trace.txt
for e in kgsl/kgsl_waittimestamp_entry kgsl/kgsl_waittimestamp_exit \
         kgsl/adreno_drawctxt_wait_start kgsl/adreno_drawctxt_wait_done \
         kgsl/kgsl_active_count kgsl/kgsl_pwr_set_state; do
    echo 0 > $T/events/$e/enable 2>/dev/null
done
echo "captured $(wc -l < /data/local/tmp/kgsl_trace.txt) lines over ${DUR}s"
