/**
 * A unit of outbound integration work that can be stored, retried, and audited.
 *
 * Implementations must be JSON-serializable (public fields, a no-argument constructor): the framework stores
 * the job on its Integration Log and re-creates it from that payload for every attempt, so a retry survives
 * the end of the transaction, the queue, and even an org restart. Extend IntegrationJobBase for defaults.
 */
public interface IntegrationJob {
    /** Developer name of the Integration_Setting__mdt record that holds this job's retry policy and endpoint. */
    String integrationName();

    /** Short name of the operation, for the log. */
    String operation();

    /**
     * Idempotency key. While a log with this key is Queued or Retrying, enqueueing the same key again returns
     * that log instead of creating a second one. Return null to disable deduplication.
     */
    String dedupKey();

    /** The record this work is about, for the log. May be null. */
    Id recordId();

    /** Builds the request for one attempt. Called fresh on every attempt, so tokens and timestamps stay current. */
    HttpRequest buildRequest(IntegrationSettings.Setting setting);

    /** True or false to override the integration's retry policy for this response; null to use the policy. */
    Boolean isRetryable(HttpResponse response);

    /** Runs after a successful attempt, once all callouts in the batch are done, so DML is allowed. */
    void onSuccess(HttpResponse response, Integration_Log__c log);

    /** Runs when the work stops for good: retries exhausted, non-retryable response, or a broken job. DML is allowed. */
    void onFailure(Integration_Log__c log);
}
