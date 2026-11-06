/**
 * Exponential backoff: base, 2x, 4x, 8x ... minutes after attempts 1, 2, 3, 4 ... The Next Attempt time on
 * the log can be hours out; the queueable delay is capped at the platform's ten minutes and the sweeper
 * picks up whatever is due later.
 */
public with sharing class IntegrationBackoff {
    /** System.enqueueJob accepts a delay of at most ten minutes. */
    public static final Integer MAX_ENQUEUE_DELAY_MINUTES = 10;
    /** Never schedule a retry more than a day out. */
    public static final Integer MAX_DELAY_MINUTES = 1440;

    /** Minutes to wait after the given attempt number failed (1 for the first attempt). */
    public static Integer delayMinutes(Integer attemptJustFailed, Integer baseMinutes) {
        Integer base = (baseMinutes == null || baseMinutes < 1) ? 1 : baseMinutes;
        Integer attempt = (attemptJustFailed == null || attemptJustFailed < 1) ? 1 : attemptJustFailed;
        Double delay = base * Math.pow(2, attempt - 1);
        return Math.min(delay, MAX_DELAY_MINUTES).intValue();
    }

    /** The delay to hand to System.enqueueJob for a wanted delay. */
    public static Integer enqueueDelay(Integer wantedMinutes) {
        if (wantedMinutes == null || wantedMinutes < 0) {
            return 0;
        }
        return Math.min(wantedMinutes, MAX_ENQUEUE_DELAY_MINUTES);
    }
}
