/**
 * Sensible defaults for IntegrationJob: no deduplication, no related record, the integration's retry policy,
 * and no post-processing. Jobs override what they need.
 */
public abstract class IntegrationJobBase implements IntegrationJob {
    public abstract String integrationName();

    public abstract String operation();

    public abstract HttpRequest buildRequest(IntegrationSettings.Setting setting);

    public virtual String dedupKey() {
        return null;
    }

    public virtual Id recordId() {
        return null;
    }

    public virtual Boolean isRetryable(HttpResponse response) {
        return null;
    }

    public virtual void onSuccess(HttpResponse response, Integration_Log__c log) {
        return; // nothing to do by default
    }

    public virtual void onFailure(Integration_Log__c log) {
        return; // nothing to do by default
    }
}
