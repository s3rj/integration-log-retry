/**
 * Entry point: log the work first, then queue it. The log is the source of truth, so if the queue is lost the
 * sweeper can still find and finish the work.
 */
public without sharing class IntegrationDispatcher {
    public class DispatchException extends Exception {
    }

    @TestVisible
    private static List<Id> lastQueued = new List<Id>();

    /** Logs and queues one job. Returns its Integration Log Id, or the active log that already holds its dedup key. */
    public static Id enqueue(IntegrationJob job) {
        return enqueueAll(new List<IntegrationJob>{ job })[0];
    }

    /** Logs and queues many jobs in one transaction (for triggers). Result Ids line up with the input list. */
    public static List<Id> enqueueAll(List<IntegrationJob> jobs) {
        Map<String, Id> activeByKey = findActiveLogs(dedupKeys(jobs));
        Map<String, Integration_Log__c> freshByKey = new Map<String, Integration_Log__c>();
        List<Integration_Log__c> fresh = new List<Integration_Log__c>();
        List<Object> slots = new List<Object>(); // per job: an existing log Id, or the fresh log that will carry it
        for (IntegrationJob job : jobs) {
            IntegrationSettings.Setting setting = IntegrationSettings.get(job.integrationName());
            if (!setting.active) {
                throw new DispatchException('Integration "' + job.integrationName() + '" is inactive; not queueing ' + job.operation() + '.');
            }
            String key = job.dedupKey();
            if (key != null && activeByKey.containsKey(key)) {
                slots.add(activeByKey.get(key));
                continue;
            }
            if (key != null && freshByKey.containsKey(key)) {
                slots.add(freshByKey.get(key));
                continue;
            }
            Integration_Log__c log = IntegrationLogs.newLog(job, setting);
            fresh.add(log);
            slots.add(log);
            if (key != null) {
                freshByKey.put(key, log);
            }
        }
        if (!fresh.isEmpty()) {
            insert fresh;
            List<Id> freshIds = new List<Id>(new Map<Id, Integration_Log__c>(fresh).keySet());
            lastQueued = freshIds;
            System.enqueueJob(new IntegrationQueueable(freshIds));
        }
        List<Id> result = new List<Id>();
        for (Object slot : slots) {
            result.add(slot instanceof Id ? (Id) slot : ((Integration_Log__c) slot).Id);
        }
        return result;
    }

    private static Set<String> dedupKeys(List<IntegrationJob> jobs) {
        Set<String> keys = new Set<String>();
        for (IntegrationJob job : jobs) {
            if (job.dedupKey() != null) {
                keys.add(job.dedupKey());
            }
        }
        return keys;
    }

    /** The oldest active log per dedup key. */
    private static Map<String, Id> findActiveLogs(Set<String> keys) {
        Map<String, Id> byKey = new Map<String, Id>();
        if (keys.isEmpty()) {
            return byKey;
        }
        for (Integration_Log__c log : [
            SELECT Id, Dedup_Key__c
            FROM Integration_Log__c
            WHERE Dedup_Key__c IN :keys AND Status__c IN :IntegrationLogs.ACTIVE_STATUSES
            ORDER BY CreatedDate
        ]) {
            if (!byKey.containsKey(log.Dedup_Key__c)) {
                byKey.put(log.Dedup_Key__c, log.Id);
            }
        }
        return byKey;
    }
}
