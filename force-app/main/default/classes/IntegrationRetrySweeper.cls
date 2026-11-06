/**
 * Scheduled safety net, every ten minutes:
 *   - re-queues Retrying logs whose Next Attempt time has passed: retries due later than a queueable can be
 *     delayed, and work whose chain was lost to a limit, a failed deploy, or a flex-queue purge;
 *   - re-queues Queued logs whose queueable is gone without having run them (aborted from Setup, purged from
 *     the flex queue, failed after a deploy changed the class), so a lost job is never lost work.
 */
public without sharing class IntegrationRetrySweeper implements Schedulable, Database.Batchable<SObject> {
    public static final String JOB_NAME = 'Integration retry sweeper';
    /** Apex cron takes a single minute value, so "every ten minutes" is six hourly jobs. */
    public static final List<Integer> MINUTES = new List<Integer>{ 0, 10, 20, 30, 40, 50 };
    /** A Queued log older than this whose queueable is not waiting or running any more is stranded. */
    public static final Integer STRANDED_AFTER_MINUTES = 15;
    public static final Integer STRANDED_PER_SWEEP = 200;
    private static final Set<String> PENDING_JOB_STATUSES = new Set<String>{ 'Holding', 'Queued', 'Preparing', 'Processing' };

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
        requeueStranded();
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

    /**
     * Re-queues Queued logs older than STRANDED_AFTER_MINUTES whose queueable is not waiting or running. A log
     * whose job is still in the queue is left alone, however long the queue is. Returns the re-queued Ids.
     */
    public static List<Id> requeueStranded() {
        Datetime cutoff = System.now().addMinutes(-STRANDED_AFTER_MINUTES);
        List<Integration_Log__c> waiting = [
            SELECT Id, Async_Job_Id__c
            FROM Integration_Log__c
            WHERE Status__c = :IntegrationLogs.STATUS_QUEUED AND CreatedDate < :cutoff
            ORDER BY CreatedDate
            LIMIT :STRANDED_PER_SWEEP
        ];
        Set<Id> jobIds = new Set<Id>();
        for (Integration_Log__c log : waiting) {
            Id jobId = asId(log.Async_Job_Id__c);
            if (jobId != null) {
                jobIds.add(jobId);
            }
        }
        Map<Id, AsyncApexJob> jobs = new Map<Id, AsyncApexJob>([SELECT Id, Status FROM AsyncApexJob WHERE Id IN :jobIds]);
        List<Integration_Log__c> stranded = new List<Integration_Log__c>();
        for (Integration_Log__c log : waiting) {
            AsyncApexJob job = jobs.get(asId(log.Async_Job_Id__c));
            if (job != null && PENDING_JOB_STATUSES.contains(job.Status)) {
                continue;
            }
            log.Error_Message__c = IntegrationLogs.clip(
                'Re-queued by the sweeper: the queueable holding this log ' + (job == null ? 'was not found' : 'ended as ' + job.Status) + ' without running it.',
                IntegrationLogs.ERROR_MAX
            );
            stranded.add(log);
        }
        if (stranded.isEmpty()) {
            return new List<Id>();
        }
        update stranded;
        List<Id> ids = new List<Id>(new Map<Id, Integration_Log__c>(stranded).keySet());
        IntegrationQueueable.chain(ids, 0);
        return ids;
    }

    private static Id asId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (StringException e) {
            return null; // not an Id; treat the job as unknown
        }
    }
}
