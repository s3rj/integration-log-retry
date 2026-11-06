/**
 * An IntegrationJob a Flow can queue for a record through the "Enqueue integration job" action: the framework
 * hands the job the record Id, and the job decides what that means (which record to query, which key to dedupe on).
 */
public interface IntegrationRecordJob extends IntegrationJob {
    void forRecord(Id recordId);
}
