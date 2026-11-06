@IsTest
private class EchoJobTest {
    private static void echoSetting() {
        IntegrationSettings.overrides = new Map<String, IntegrationSettings.Setting>{
            'echo' => new IntegrationSettings.Setting('Echo').withMaxAttempts(3).withEndpoint('https://example.invalid/post')
        };
    }

    @IsTest
    static void buildsAPostToTheConfiguredEndpoint() {
        echoSetting();
        EchoJob job = new EchoJob(UserInfo.getUserId(), 'hi');

        HttpRequest request = job.buildRequest(IntegrationSettings.get('Echo'));

        Assert.areEqual('https://example.invalid/post', request.getEndpoint(), 'endpoint from the setting');
        Assert.areEqual('POST', request.getMethod(), 'method');
        Assert.areEqual('application/json', request.getHeader('Content-Type'), 'content type');
        Assert.isTrue(request.getBody().contains('"message":"hi"'), 'body carries the message');
        Assert.areEqual('echo:' + UserInfo.getUserId(), job.dedupKey(), 'one active echo per subject');
        Assert.areEqual(UserInfo.getUserId(), job.recordId(), 'record id');
        Assert.isNull(new EchoJob().dedupKey(), 'no subject, no key');
        Assert.isNull(job.isRetryable(null), 'defers to the integration policy');

        EchoJob fromFlow = new EchoJob();
        fromFlow.forRecord(UserInfo.getUserId());
        Assert.areEqual(UserInfo.getUserId(), fromFlow.subjectId, 'the Flow action hands over the record');
        Assert.isTrue(fromFlow.message.contains(UserInfo.getUserId()), 'default message names the record');
    }

    @IsTest
    static void roundTripsThroughTheFramework() {
        echoSetting();
        Integration_Log__c log = IntegrationLogs.newLog(new EchoJob(UserInfo.getUserId(), 'hi'), IntegrationSettings.get('Echo'));
        insert log;
        Test.setMock(HttpCalloutMock.class, SequenceCalloutMock.always(200));

        Test.startTest();
        IntegrationRunner.run(new List<Id>{ log.Id });
        Test.stopTest();

        Integration_Log__c after = [SELECT Status__c, Job_Class__c, Response_Body__c FROM Integration_Log__c WHERE Id = :log.Id];
        Assert.areEqual('Succeeded', after.Status__c, 'succeeded');
        Assert.areEqual('EchoJob', after.Job_Class__c, 'class recorded');
        Assert.isTrue(after.Response_Body__c.contains('"message":"hi"'), 'echoed body kept');
    }

    @IsTest
    static void baseClassDefaultsCoverTheOptionalMethods() {
        MinimalJob job = new MinimalJob();

        job.onSuccess(new HttpResponse(), new Integration_Log__c());
        job.onFailure(new Integration_Log__c());

        Assert.isNull(job.dedupKey(), 'no deduplication by default');
        Assert.isNull(job.recordId(), 'no record by default');
        Assert.isNull(job.isRetryable(new HttpResponse()), 'policy decides by default');
    }

    /** The least a job has to implement. */
    private class MinimalJob extends IntegrationJobBase {
        public override String integrationName() {
            return 'Minimal';
        }
        public override String operation() {
            return 'noop';
        }
        public override HttpRequest buildRequest(IntegrationSettings.Setting setting) {
            return new HttpRequest();
        }
    }
}
