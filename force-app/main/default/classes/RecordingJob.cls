/**
 * Test job: records what the framework does to it and can be told to misbehave.
 */
@IsTest
public class RecordingJob extends IntegrationJobBase {
    public static Integer successes = 0;
    public static Integer failures = 0;
    public static Id lastSuccessLogId;
    public static Id lastFailureLogId;

    public String key;
    public String integration = 'Test';
    public Boolean throwInHandler = false;
    public Boolean breakRequest = false;
    /** null = use the integration's retry policy. */
    public Boolean retryOverride;

    public RecordingJob() {
        super();
    }

    public RecordingJob(String key) {
        this.key = key;
    }

    public override String integrationName() {
        return integration;
    }

    public override String operation() {
        return 'record';
    }

    public override String dedupKey() {
        return key;
    }

    public override HttpRequest buildRequest(IntegrationSettings.Setting setting) {
        if (breakRequest) {
            throw new IntegrationDispatcher.DispatchException('cannot build request');
        }
        HttpRequest request = new HttpRequest();
        request.setEndpoint(setting.endpoint == null ? 'https://example.invalid/record' : setting.endpoint);
        request.setMethod('POST');
        request.setBody('{"key":"' + key + '"}');
        return request;
    }

    public override Boolean isRetryable(HttpResponse response) {
        return retryOverride;
    }

    public override void onSuccess(HttpResponse response, Integration_Log__c log) {
        successes++;
        lastSuccessLogId = log.Id;
        if (throwInHandler) {
            throw new IntegrationDispatcher.DispatchException('handler exploded');
        }
    }

    public override void onFailure(Integration_Log__c log) {
        failures++;
        lastFailureLogId = log.Id;
    }
}
