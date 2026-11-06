/**
 * Works through a list of logs ten at a time. Leftovers chain immediately; retries chain with the backoff
 * delay (capped at the platform's ten minutes). Anything the chain cannot carry is picked up by
 * IntegrationRetrySweeper, so a lost queueable never loses work.
 *
 * A Finalizer covers the one failure a try/catch cannot: if this job dies from an uncatchable limit exception,
 * the transaction rolls back and the finalizer records the failure on the logs and schedules the retry.
 */
public without sharing class IntegrationQueueable implements Queueable, Database.AllowsCallouts {
    /** Callouts per execution: well under the 100-callout and 120-second limits even with slow endpoints. */
    public static final Integer CHUNK_SIZE = 10;

    @TestVisible
    private static List<Id> lastChained;
    @TestVisible
    private static Integer lastChainDelay;

    private final List<Id> logIds;

    public IntegrationQueueable(List<Id> logIds) {
        this.logIds = logIds;
    }

    public void execute(QueueableContext context) {
        List<Id> now = new List<Id>();
        List<Id> later = new List<Id>();
        for (Integer i = 0; i < logIds.size(); i++) {
            if (i < CHUNK_SIZE) {
                now.add(logIds[i]);
            } else {
                later.add(logIds[i]);
            }
        }
        System.attachFinalizer(new Recovery(now));
        IntegrationRunner.Outcome outcome = IntegrationRunner.run(now);
        if (!later.isEmpty()) {
            chain(later, 0); // one child job per execution; retries from this chunk are the sweeper's
        } else if (!outcome.retryIds.isEmpty()) {
            chain(outcome.retryIds, outcome.retryDelayMinutes);
        }
    }

    /** Queues the next job. In a test context only the intent is recorded, because tests cannot chain queueables. */
    public static Id chain(List<Id> ids, Integer delayMinutes) {
        lastChained = ids;
        lastChainDelay = delayMinutes;
        if (Test.isRunningTest()) {
            return null;
        }
        Id jobId = System.enqueueJob(new IntegrationQueueable(ids), IntegrationBackoff.enqueueDelay(delayMinutes));
        IntegrationLogs.recordJob(ids, jobId);
        return jobId;
    }

    /** Runs after the queueable, even when it died from a limit exception; counts the attempt and queues the retry. */
    public class Recovery implements Finalizer {
        private final List<Id> logIds;

        public Recovery(List<Id> logIds) {
            this.logIds = logIds;
        }

        public void execute(FinalizerContext context) {
            if (context.getResult() == ParentJobResult.SUCCESS) {
                return;
            }
            String message = IntegrationLogs.clip('Job aborted: ' + context.getException().getMessage(), IntegrationLogs.ERROR_MAX);
            List<Integration_Log__c> logs = [
                SELECT Id, Attempt__c, Max_Attempts__c, Integration__c
                FROM Integration_Log__c
                WHERE Id IN :logIds AND Status__c IN :IntegrationLogs.ACTIVE_STATUSES
            ];
            for (Integration_Log__c log : logs) {
                log.Attempt__c = (log.Attempt__c == null ? 0 : log.Attempt__c) + 1;
                log.Error_Message__c = message;
                if (log.Max_Attempts__c != null && log.Attempt__c < log.Max_Attempts__c) {
                    Integer delay = IntegrationBackoff.delayMinutes(log.Attempt__c.intValue(), IntegrationSettings.get(log.Integration__c).baseDelayMinutes);
                    log.Status__c = IntegrationLogs.STATUS_RETRYING;
                    log.Next_Attempt_At__c = System.now().addMinutes(delay);
                } else {
                    log.Status__c = IntegrationLogs.STATUS_FAILED;
                    log.Completed_At__c = System.now();
                    log.Next_Attempt_At__c = null;
                }
            }
            update logs;
        }
    }
}
