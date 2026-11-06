/**
 * Sample job: posts a small JSON document to the Echo integration's endpoint. Deploy, assign the permission
 * set, and run scripts/apex/enqueue-echo.apex to see a log go Queued -> Succeeded against a real endpoint.
 * It also implements IntegrationRecordJob, so a Flow can queue it with the "Enqueue integration job" action.
 */
public with sharing class EchoJob extends IntegrationJobBase implements IntegrationRecordJob {
    public Id subjectId;
    public String message;

    /** Required: the framework re-creates jobs from JSON. */
    public EchoJob() {
        super();
    }

    public EchoJob(Id subjectId, String message) {
        this.subjectId = subjectId;
        this.message = message;
    }

    /** Called by the Flow action with the record the flow is about. */
    public void forRecord(Id recordId) {
        subjectId = recordId;
        if (message == null) {
            message = 'echo for ' + recordId;
        }
    }

    public override String integrationName() {
        return 'Echo';
    }

    public override String operation() {
        return 'echo';
    }

    /** One active echo per subject at a time. */
    public override String dedupKey() {
        return subjectId == null ? null : 'echo:' + subjectId;
    }

    public override Id recordId() {
        return subjectId;
    }

    public override HttpRequest buildRequest(IntegrationSettings.Setting setting) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(setting.endpoint);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setBody(JSON.serialize(new Map<String, Object>{
            'subjectId' => subjectId,
            'message' => message,
            'sentAt' => System.now()
        }));
        return request;
    }
}
