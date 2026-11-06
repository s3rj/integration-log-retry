@IsTest
private class IntegrationEnqueueActionTest {
    private static IntegrationEnqueueAction.Request request(String jobClass, Id recordId, String parametersJson) {
        IntegrationEnqueueAction.Request request = new IntegrationEnqueueAction.Request();
        request.jobClass = jobClass;
        request.recordId = recordId;
        request.parametersJson = parametersJson;
        return request;
    }

    private static String failure(IntegrationEnqueueAction.Request request) {
        try {
            IntegrationEnqueueAction.build(request);
            return null;
        } catch (IntegrationDispatcher.DispatchException e) {
            return e.getMessage();
        }
    }

    @IsTest
    static void buildsTheJobFromClassNameRecordAndParameters() {
        EchoJob job = (EchoJob) IntegrationEnqueueAction.build(request('EchoJob', UserInfo.getUserId(), '{"message":"from flow"}'));

        Assert.areEqual(UserInfo.getUserId(), job.subjectId, 'record handed to the job');
        Assert.areEqual('from flow', job.message, 'parameter landed on the public field');
        Assert.areEqual('echo:' + UserInfo.getUserId(), job.dedupKey(), 'job behaves as if built in Apex');

        EchoJob bare = (EchoJob) IntegrationEnqueueAction.build(request('echojob', null, null));
        Assert.isNull(bare.subjectId, 'no record is fine');
        Assert.isNull(bare.message, 'no parameters is fine');
    }

    @IsTest
    static void enqueuesOneLogPerRequestInOneTransaction() {
        IntegrationSettings.overrides = new Map<String, IntegrationSettings.Setting>{ 'echo' => new IntegrationSettings.Setting('Echo') };

        List<Id> ids = IntegrationEnqueueAction.enqueue(new List<IntegrationEnqueueAction.Request>{
            request('EchoJob', UserInfo.getUserId(), null),
            request('EchoJob', UserInfo.getOrganizationId(), '{"message":"org"}')
        });

        Assert.areEqual(2, ids.size(), 'one log id per request');
        Map<Id, Integration_Log__c> logs = new Map<Id, Integration_Log__c>([SELECT Status__c, Job_Class__c, Record_Id__c, Job_Payload__c, Async_Job_Id__c FROM Integration_Log__c WHERE Id IN :ids]);
        Assert.areEqual('Queued', logs.get(ids[0]).Status__c, 'queued');
        Assert.areEqual('EchoJob', logs.get(ids[0]).Job_Class__c, 'class recorded');
        Assert.areEqual(UserInfo.getUserId(), logs.get(ids[0]).Record_Id__c, 'record recorded');
        Assert.isTrue(logs.get(ids[1]).Job_Payload__c.contains('"message":"org"'), 'parameters serialized with the job');
        Assert.isNotNull(logs.get(ids[0]).Async_Job_Id__c, 'queueable recorded on the log');
        Assert.areEqual(2, IntegrationDispatcher.lastQueued.size(), 'both handed to one queueable');
    }

    @IsTest
    static void badRequestsFailWithAReason() {
        Assert.isTrue(failure(request('NoSuchJobClass', null, null)).contains('not found'), 'unknown class');
        Assert.isTrue(failure(request('', null, null)).contains('not found'), 'blank class');
        Assert.isTrue(failure(request('IntegrationBackoff', null, null)).contains('does not implement IntegrationJob'), 'not a job');
        Assert.isTrue(failure(request('EchoJob', null, '{nope')).contains('not a valid JSON object'), 'bad JSON');
        Assert.isTrue(failure(request('RecordingJob', UserInfo.getUserId(), null)).contains('cannot take a record Id'), 'job without forRecord');
        Assert.isNull(failure(request('RecordingJob', null, '{"key":"k"}')), 'a plain job is fine without a record');
    }
}
