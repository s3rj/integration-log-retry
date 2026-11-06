/**
 * Scheduled safety net. Every ten minutes it re-queues Retrying logs whose Next Attempt time has passed:
 * retries that were due later than a queueable can be delayed, and work whose chain was lost to a limit,
 * a failed deploy, or a flex-queue purge.
 */
public without sharing class IntegrationRetrySweeper implements Schedulable, Database.Batchable<SObject> {
    public static final String JOB_NAME = 'Integration retry sweeper';
    /** Apex cron takes a single minute value, so "every ten minutes" is six hourly jobs. */
    public static final List<Integer> MINUTES = new List<Integer>{ 0, 10, 20, 30, 40, 50 };

    /** Schedules the six hourly jobs. Run once per org. Returns the CronTrigger Ids. */
    @SuppressWarnings('PMD.OperationWithLimitsInLoop') // six bounded System.schedule calls, run once per org
    public static List<Id> schedule() {
        List<Id> cronIds = new List<Id>();
        for (Integer minute : MINUTES) {
            cronIds.add(System.schedule(jobName(minute), cronExpression(minute), new IntegrationRetrySweeper()));
        }
        return cronIds;
    }

    public static String jobName(Integer minute) {
        return JOB_NAME + ' :' + (minute < 10 ? '0' : '') + minute;
    }

    public static String cronExpression(Integer minute) {
        return '0 ' + minute + ' * * * ?';
    }

    public void execute(SchedulableContext context) {
        Database.executeBatch(this, IntegrationQueueable.CHUNK_SIZE);
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id
            FROM Integration_Log__c
            WHERE Status__c = :IntegrationLogs.STATUS_RETRYING AND Next_Attempt_At__c <= :System.now()
            ORDER BY Next_Attempt_At__c
        ]);
    }

    /** One queueable per batch execution, which is all a batch may enqueue. */
    public void execute(Database.BatchableContext context, List<Integration_Log__c> scope) {
        IntegrationQueueable.chain(new List<Id>(new Map<Id, Integration_Log__c>(scope).keySet()), 0);
    }

    public void finish(Database.BatchableContext context) {
        return; // nothing to summarize; each log carries its own outcome
    }
}
