/**
 * Lets a record-triggered or scheduled Flow queue an integration job without new Apex: name the job class, pass
 * the record, done. The job implements IntegrationRecordJob so the framework can hand it the record Id; any extra
 * inputs arrive as a JSON object and land on the job's public fields.
 */
public with sharing class IntegrationEnqueueAction {
    public class Request {
        @InvocableVariable(label='Job class' description='Apex class implementing IntegrationRecordJob, for example SendOrderJob.' required=true)
        public String jobClass;
        @InvocableVariable(label='Record Id' description='The record the job is about; handed to the job through forRecord().')
        public Id recordId;
        @InvocableVariable(label='Parameters (JSON)' description='Optional JSON object whose keys are public fields of the job, for example {"reason":"closed won"}.')
        public String parametersJson;
    }

    @InvocableMethod(
        label='Enqueue integration job'
        description='Logs and queues one integration job per request, in one transaction, with the framework\'s retries, backoff, and deduplication. Returns the Integration Log Ids.'
        category='Integration Logs'
    )
    public static List<Id> enqueue(List<Request> requests) {
        List<IntegrationJob> jobs = new List<IntegrationJob>();
        for (Request request : requests) {
            jobs.add(build(request));
        }
        return IntegrationDispatcher.enqueueAll(jobs);
    }

    @TestVisible
    private static IntegrationJob build(Request request) {
        Type jobType = String.isBlank(request.jobClass) ? null : Type.forName(request.jobClass);
        if (jobType == null) {
            throw new IntegrationDispatcher.DispatchException('Job class not found: ' + request.jobClass);
        }
        Object instance;
        try {
            instance = JSON.deserialize(String.isBlank(request.parametersJson) ? '{}' : request.parametersJson, jobType);
        } catch (JSONException e) {
            throw new IntegrationDispatcher.DispatchException('Parameters for ' + request.jobClass + ' are not a valid JSON object: ' + e.getMessage());
        }
        if (!(instance instanceof IntegrationJob)) {
            throw new IntegrationDispatcher.DispatchException(request.jobClass + ' does not implement IntegrationJob.');
        }
        if (request.recordId != null) {
            if (!(instance instanceof IntegrationRecordJob)) {
                throw new IntegrationDispatcher.DispatchException(request.jobClass + ' does not implement IntegrationRecordJob, so it cannot take a record Id.');
            }
            ((IntegrationRecordJob) instance).forRecord(request.recordId);
        }
        return (IntegrationJob) instance;
    }
}
