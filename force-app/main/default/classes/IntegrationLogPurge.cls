/**
 * Housekeeping: deletes finished logs once they are older than their integration's retention, so the object stays
 * small, list views stay fast, and storage is not spent on last year's successful syncs. Succeeded logs go after
 * Retention Days (default 30); Failed and Handler Failed logs after Failed Retention Days (default 90), so nobody
 * loses the evidence of a problem before looking at it. Active logs are never touched.
 */
public without sharing class IntegrationLogPurge implements Schedulable, Database.Batchable<SObject> {
    public static final String JOB_NAME = 'Integration log purge';
    /** 02:00 every day, org time. */
    public static final String CRON_DAILY = '0 0 2 * * ?';
    public static final Integer BATCH_SIZE = 2000;

    /** Schedules the daily run. Run once per org. */
    public static Id schedule() {
        return System.schedule(JOB_NAME, CRON_DAILY, new IntegrationLogPurge());
    }

    public void execute(SchedulableContext context) {
        Database.executeBatch(this, BATCH_SIZE);
    }

    /** Everything finished before the shortest retention; execute() applies each log's own. */
    public Database.QueryLocator start(Database.BatchableContext context) {
        Datetime horizon = System.now().addDays(-IntegrationSettings.shortestRetentionDays());
        return Database.getQueryLocator([
            SELECT Id, Integration__c, Status__c, Completed_At__c
            FROM Integration_Log__c
            WHERE Status__c IN :IntegrationLogs.FINISHED_STATUSES AND Completed_At__c < :horizon
        ]);
    }

    public void execute(Database.BatchableContext context, List<Integration_Log__c> scope) {
        List<Integration_Log__c> expired = new List<Integration_Log__c>();
        Datetime now = System.now();
        for (Integration_Log__c log : scope) {
            if (isExpired(log, now)) {
                expired.add(log);
            }
        }
        Database.delete(expired, false); // a log someone has locked should not stop the rest
    }

    public void finish(Database.BatchableContext context) {
        return; // nothing to summarize
    }

    public static Boolean isExpired(Integration_Log__c log, Datetime now) {
        if (log.Completed_At__c == null) {
            return false;
        }
        IntegrationSettings.Setting setting = IntegrationSettings.get(log.Integration__c);
        Integer days = log.Status__c == IntegrationLogs.STATUS_SUCCEEDED ? setting.retentionDays : setting.failedRetentionDays;
        return log.Completed_At__c < now.addDays(-days);
    }
}
