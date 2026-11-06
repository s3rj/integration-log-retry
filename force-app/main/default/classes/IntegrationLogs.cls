/**
 * Status constants and helpers for Integration_Log__c.
 */
public without sharing class IntegrationLogs {
    public static final String STATUS_QUEUED = 'Queued';
    public static final String STATUS_SUCCEEDED = 'Succeeded';
    public static final String STATUS_RETRYING = 'Retrying';
    public static final String STATUS_FAILED = 'Failed';
    public static final String STATUS_HANDLER_FAILED = 'Handler Failed';
    public static final Set<String> ACTIVE_STATUSES = new Set<String>{ STATUS_QUEUED, STATUS_RETRYING };
    public static final Set<String> FINISHED_STATUSES = new Set<String>{ STATUS_SUCCEEDED, STATUS_FAILED, STATUS_HANDLER_FAILED };

    public static final Integer BODY_MAX = 131072;
    public static final Integer ERROR_MAX = 32768;
    public static final Integer TEXT_MAX = 255;

    /** A new Queued log for a job, with the job stored as JSON so every attempt can re-create it. */
    public static Integration_Log__c newLog(IntegrationJob job, IntegrationSettings.Setting setting) {
        return new Integration_Log__c(
            Integration__c = clip(job.integrationName(), 80),
            Operation__c = clip(job.operation(), 80),
            Direction__c = 'Outbound',
            Status__c = STATUS_QUEUED,
            Attempt__c = 0,
            Max_Attempts__c = setting.maxAttempts,
            Record_Id__c = job.recordId(),
            Dedup_Key__c = clip(job.dedupKey(), TEXT_MAX),
            Job_Class__c = className(job),
            Job_Payload__c = clip(JSON.serialize(job), BODY_MAX)
        );
    }

    /** Records which queueable holds the logs, so the sweeper can tell a long queue from a lost job. */
    public static void recordJob(List<Id> logIds, Id jobId) {
        if (jobId == null || logIds == null || logIds.isEmpty()) {
            return;
        }
        List<Integration_Log__c> logs = new List<Integration_Log__c>();
        for (Id logId : logIds) {
            logs.add(new Integration_Log__c(Id = logId, Async_Job_Id__c = jobId));
        }
        update logs;
    }

    /** The Apex class name of an object instance, as Type.forName() expects it. */
    public static String className(Object instance) {
        String typeName = String.valueOf(instance);
        return typeName.substring(0, typeName.indexOf(':'));
    }

    public static String clip(String value, Integer max) {
        return value == null ? null : value.abbreviate(max);
    }
}
