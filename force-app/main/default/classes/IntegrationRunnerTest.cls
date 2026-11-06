@IsTest
private class IntegrationRunnerTest {
    // Logs are inserted before Test.startTest() and the runner is called once inside it: a callout after DML in
    // the same transaction is an error, and that is exactly the situation the queueable avoids in production.

    private static void testSetting(Integer maxAttempts) {
        IntegrationSettings.overrides = new Map<String, IntegrationSettings.Setting>{
            'test' => new IntegrationSettings.Setting('Test').withMaxAttempts(maxAttempts).withBaseDelayMinutes(1).withEndpoint('https://example.invalid/record')
        };
    }

    private static Id insertLog(RecordingJob job, String status, Integer attempt, Datetime nextAttempt) {
        Integration_Log__c log = IntegrationLogs.newLog(job, IntegrationSettings.get('Test'));
        log.Status__c = status;
        log.Attempt__c = attempt;
        log.Next_Attempt_At__c = nextAttempt;
        insert log;
        return log.Id;
    }

    private static Id queued(RecordingJob job) {
        return insertLog(job, 'Queued', 0, null);
    }

    private static Integration_Log__c reload(Id logId) {
        return [
            SELECT Status__c, Attempt__c, Max_Attempts__c, HTTP_Status__c, HTTP_Method__c, Endpoint__c, Error_Message__c, Next_Attempt_At__c,
                Completed_At__c, Request_Body__c, Response_Body__c, Duration_ms__c
            FROM Integration_Log__c
            WHERE Id = :logId
        ];
    }

    private static IntegrationRunner.Outcome run(List<Id> logIds, SequenceCalloutMock mock) {
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        IntegrationRunner.Outcome outcome = IntegrationRunner.run(logIds);
        Test.stopTest();
        return outcome;
    }

    @IsTest
    static void successfulAttemptCompletesTheLogAndRunsTheHandler() {
        testSetting(3);
        Id logId = queued(new RecordingJob('k1'));

        IntegrationRunner.Outcome outcome = run(new List<Id>{ logId }, SequenceCalloutMock.always(200));

        Integration_Log__c log = reload(logId);
        Assert.areEqual('Succeeded', log.Status__c, 'status');
        Assert.areEqual(1, log.Attempt__c.intValue(), 'one attempt');
        Assert.areEqual(200, log.HTTP_Status__c.intValue(), 'status code recorded');
        Assert.areEqual('POST', log.HTTP_Method__c, 'method recorded');
        Assert.areEqual('https://example.invalid/record', log.Endpoint__c, 'endpoint recorded');
        Assert.isTrue(log.Request_Body__c.contains('k1'), 'request body recorded');
        Assert.isTrue(log.Response_Body__c.contains('"status":200'), 'response body recorded');
        Assert.isNotNull(log.Completed_At__c, 'completed');
        Assert.isNotNull(log.Duration_ms__c, 'duration recorded');
        Assert.isNull(log.Error_Message__c, 'no error');
        Assert.areEqual(1, outcome.succeeded, 'outcome counts the success');
        Assert.areEqual(1, RecordingJob.successes, 'success handler ran');
        Assert.areEqual(logId, RecordingJob.lastSuccessLogId, 'handler received the log');
    }

    @IsTest
    static void retryableFailureSchedulesTheNextAttempt() {
        testSetting(3);
        Id logId = queued(new RecordingJob('k2'));

        IntegrationRunner.Outcome outcome = run(new List<Id>{ logId }, SequenceCalloutMock.always(503));

        Integration_Log__c log = reload(logId);
        Assert.areEqual('Retrying', log.Status__c, 'retrying after a 503');
        Assert.areEqual(1, log.Attempt__c.intValue(), 'first attempt counted');
        Assert.isTrue(log.Error_Message__c.startsWith('HTTP 503'), 'error recorded: ' + log.Error_Message__c);
        Assert.isTrue(log.Next_Attempt_At__c > System.now(), 'next attempt is in the future');
        Assert.isNull(log.Completed_At__c, 'not completed');
        Assert.areEqual(new List<Id>{ logId }, outcome.retryIds, 'outcome lists the retry');
        Assert.areEqual(1, outcome.retryDelayMinutes, 'base delay after the first failure');
        Assert.areEqual(0, RecordingJob.successes + RecordingJob.failures, 'no handler yet');
        Assert.isTrue(IntegrationRunner.lastPublished.isEmpty(), 'no failure event while retrying');
    }

    @IsTest
    static void aDueRetrySucceedsOnItsNextAttempt() {
        testSetting(3);
        Id logId = insertLog(new RecordingJob('k3'), 'Retrying', 1, System.now().addMinutes(-1));

        run(new List<Id>{ logId }, SequenceCalloutMock.always(200));

        Integration_Log__c log = reload(logId);
        Assert.areEqual('Succeeded', log.Status__c, 'second attempt succeeded');
        Assert.areEqual(2, log.Attempt__c.intValue(), 'attempts accumulate');
        Assert.isNull(log.Error_Message__c, 'error cleared on success');
        Assert.isNull(log.Next_Attempt_At__c, 'no next attempt');
        Assert.areEqual(1, RecordingJob.successes, 'success handler ran once');
    }

    @IsTest
    static void retriesThatAreNotDueYetAreSkipped() {
        testSetting(3);
        Id logId = insertLog(new RecordingJob('k4'), 'Retrying', 1, System.now().addMinutes(30));

        IntegrationRunner.Outcome outcome = run(new List<Id>{ logId }, SequenceCalloutMock.always(200));

        Assert.areEqual(1, reload(logId).Attempt__c.intValue(), 'not attempted');
        Assert.areEqual('Retrying', reload(logId).Status__c, 'still waiting');
        Assert.areEqual(0, outcome.succeeded + outcome.failed + outcome.retryIds.size(), 'nothing happened');
    }

    @IsTest
    static void exhaustedRetriesFailTheLogPublishAnEventAndRunTheFailureHandler() {
        testSetting(2);
        Id logId = insertLog(new RecordingJob('k5'), 'Retrying', 1, System.now().addMinutes(-1));

        IntegrationRunner.Outcome outcome = run(new List<Id>{ logId }, SequenceCalloutMock.always(503));

        Integration_Log__c log = reload(logId);
        Assert.areEqual('Failed', log.Status__c, 'retries exhausted');
        Assert.areEqual(2, log.Attempt__c.intValue(), 'max attempts reached');
        Assert.isNotNull(log.Completed_At__c, 'completed');
        Assert.isNull(log.Next_Attempt_At__c, 'no next attempt');
        Assert.areEqual(1, outcome.failed, 'outcome counts the failure');
        Assert.areEqual(1, IntegrationRunner.lastPublished.size(), 'one failure event published');
        Assert.areEqual(logId, IntegrationRunner.lastPublished[0].Log_Id__c, 'event names the log');
        Assert.areEqual(2, IntegrationRunner.lastPublished[0].Attempts__c.intValue(), 'event carries the attempt count');
        Assert.areEqual(1, RecordingJob.failures, 'failure handler ran');
        Assert.areEqual(logId, RecordingJob.lastFailureLogId, 'failure handler received the log');
    }

    @IsTest
    static void nonRetryableStatusFailsImmediately() {
        testSetting(3);
        Id logId = queued(new RecordingJob('k6'));

        run(new List<Id>{ logId }, SequenceCalloutMock.always(400));

        Integration_Log__c log = reload(logId);
        Assert.areEqual('Failed', log.Status__c, 'a 400 is not retried');
        Assert.areEqual(1, log.Attempt__c.intValue(), 'one attempt');
        Assert.areEqual(1, RecordingJob.failures, 'failure handler ran');
        Assert.areEqual(1, IntegrationRunner.lastPublished.size(), 'failure event published');
    }

    @IsTest
    static void calloutExceptionsRetry() {
        testSetting(3);
        Id logId = queued(new RecordingJob('k7'));

        run(new List<Id>{ logId }, new SequenceCalloutMock(new List<Object>{ new System.CalloutException('Read timed out') }));

        Integration_Log__c log = reload(logId);
        Assert.areEqual('Retrying', log.Status__c, 'timeouts retry');
        Assert.isTrue(log.Error_Message__c.contains('Read timed out'), 'exception recorded: ' + log.Error_Message__c);
        Assert.isNull(log.HTTP_Status__c, 'no response to record');
    }

    @IsTest
    static void aJobMayVetoARetry() {
        testSetting(3);
        RecordingJob job = new RecordingJob('k8');
        job.retryOverride = false;
        Id logId = queued(job);

        run(new List<Id>{ logId }, SequenceCalloutMock.always(503));

        Assert.areEqual('Failed', reload(logId).Status__c, 'job vetoed the retry of a 503');
    }

    @IsTest
    static void aJobMayForceARetry() {
        testSetting(3);
        RecordingJob job = new RecordingJob('k9');
        job.retryOverride = true;
        Id logId = queued(job);

        run(new List<Id>{ logId }, SequenceCalloutMock.always(400));

        Assert.areEqual('Retrying', reload(logId).Status__c, 'job forced a retry of a 400');
    }

    @IsTest
    static void handlerExceptionsAreRecordedWithoutLosingTheResponse() {
        testSetting(3);
        RecordingJob job = new RecordingJob('k10');
        job.throwInHandler = true;
        Id logId = queued(job);

        run(new List<Id>{ logId }, SequenceCalloutMock.always(200));

        Integration_Log__c log = reload(logId);
        Assert.areEqual('Handler Failed', log.Status__c, 'handler failure is its own status');
        Assert.isTrue(log.Error_Message__c.contains('handler exploded'), 'handler error recorded: ' + log.Error_Message__c);
        Assert.areEqual(200, log.HTTP_Status__c.intValue(), 'the successful response is kept');
    }

    @IsTest
    static void brokenJobsFailWithoutRetrying() {
        testSetting(3);
        RecordingJob job = new RecordingJob('k11');
        job.breakRequest = true;
        Id broken = queued(job);
        Integration_Log__c orphan = IntegrationLogs.newLog(new RecordingJob('k12'), IntegrationSettings.get('Test'));
        orphan.Job_Class__c = 'NoSuchJobClass';
        insert orphan;

        run(new List<Id>{ broken, orphan.Id }, SequenceCalloutMock.always(200));

        Integration_Log__c brokenLog = reload(broken);
        Assert.areEqual('Failed', brokenLog.Status__c, 'a job that cannot build its request fails');
        Assert.isTrue(brokenLog.Error_Message__c.contains('cannot build request'), 'reason recorded');
        Integration_Log__c orphanLog = reload(orphan.Id);
        Assert.areEqual('Failed', orphanLog.Status__c, 'a missing job class fails');
        Assert.isTrue(orphanLog.Error_Message__c.contains('NoSuchJobClass'), 'class named in the error');
        Assert.areEqual(1, RecordingJob.failures, 'only the job that exists gets a failure callback');
    }

    @IsTest
    static void onlyActiveLogsAreProcessed() {
        testSetting(3);
        Id done = insertLog(new RecordingJob('k13'), 'Succeeded', 1, null);
        Id waiting = queued(new RecordingJob('k14'));

        IntegrationRunner.Outcome outcome = run(new List<Id>{ done, waiting }, SequenceCalloutMock.always(200));

        Assert.areEqual(1, outcome.succeeded, 'only the queued log ran');
        Assert.areEqual(1, reload(done).Attempt__c.intValue(), 'completed log untouched');
        Assert.areEqual('Succeeded', reload(waiting).Status__c, 'queued log processed');
    }
}
