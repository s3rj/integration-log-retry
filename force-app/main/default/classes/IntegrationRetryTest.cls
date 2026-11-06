@IsTest
private class IntegrationRetryTest {
    private static void testSetting() {
        IntegrationSettings.overrides = new Map<String, IntegrationSettings.Setting>{
            'test' => new IntegrationSettings.Setting('Test').withMaxAttempts(2).withBaseDelayMinutes(1)
        };
    }

    private static Integration_Log__c log(RecordingJob job, String status, Integer attempt) {
        Integration_Log__c log = IntegrationLogs.newLog(job, IntegrationSettings.get('Test'));
        log.Status__c = status;
        log.Attempt__c = attempt;
        if (IntegrationLogs.FINISHED_STATUSES.contains(status)) {
            log.Completed_At__c = System.now().addMinutes(-5);
        }
        insert log;
        return log;
    }

    private static Integration_Log__c reload(Id logId) {
        return [SELECT Status__c, Attempt__c, Max_Attempts__c, Next_Attempt_At__c, Completed_At__c, Error_Message__c FROM Integration_Log__c WHERE Id = :logId];
    }

    @IsTest
    static void failedLogGetsExactlyOneMoreAttemptNow() {
        testSetting();
        Integration_Log__c failed = log(new RecordingJob('f'), 'Failed', 2);

        Map<Id, String> outcomes = IntegrationRetry.retry(new List<Id>{ failed.Id });

        Assert.areEqual('Requeued', outcomes.get(failed.Id), 'outcome');
        Integration_Log__c after = reload(failed.Id);
        Assert.areEqual('Retrying', after.Status__c, 'back in flight');
        Assert.areEqual(3, after.Max_Attempts__c.intValue(), 'one more attempt than were used');
        Assert.isTrue(after.Next_Attempt_At__c <= System.now(), 'due now');
        Assert.isNull(after.Completed_At__c, 'no longer completed');
        Assert.areEqual(new List<Id>{ failed.Id }, IntegrationQueueable.lastChained, 'queued');
        Assert.areEqual(0, IntegrationQueueable.lastChainDelay, 'without delay');
    }

    @IsTest
    static void retryingLogIsBroughtForward() {
        testSetting();
        Integration_Log__c waiting = log(new RecordingJob('w'), 'Retrying', 1);
        update new Integration_Log__c(Id = waiting.Id, Next_Attempt_At__c = System.now().addHours(2));

        IntegrationRetry.retry(new List<Id>{ waiting.Id });

        Integration_Log__c after = reload(waiting.Id);
        Assert.isTrue(after.Next_Attempt_At__c <= System.now(), 'due now');
        Assert.areEqual(2, after.Max_Attempts__c.intValue(), 'attempt budget unchanged');
        Assert.areEqual(new List<Id>{ waiting.Id }, IntegrationQueueable.lastChained, 'queued');
    }

    @IsTest
    static void handlerFailedLogRerunsTheHandlerWithoutACallout() {
        testSetting();
        Integration_Log__c log = log(new RecordingJob('h'), 'Handler Failed', 1);
        update new Integration_Log__c(Id = log.Id, HTTP_Status__c = 200, Response_Body__c = '{"ok":true}', Error_Message__c = 'Handler failed: boom');
        SequenceCalloutMock mock = SequenceCalloutMock.always(500);
        Test.setMock(HttpCalloutMock.class, mock);

        Map<Id, String> outcomes = IntegrationRetry.retry(new List<Id>{ log.Id });

        Assert.areEqual('Succeeded', outcomes.get(log.Id), 'handler re-run succeeded');
        Assert.areEqual(1, RecordingJob.successes, 'success handler ran once');
        Assert.areEqual(log.Id, RecordingJob.lastSuccessLogId, 'with its log');
        Assert.isTrue(mock.requests.isEmpty(), 'the request was not sent again');
        Integration_Log__c after = reload(log.Id);
        Assert.areEqual('Succeeded', after.Status__c, 'status');
        Assert.isNull(after.Error_Message__c, 'error cleared');
        Assert.areEqual(1, after.Attempt__c.intValue(), 'no new attempt counted');
        Assert.isNull(IntegrationQueueable.lastChained, 'nothing queued');
    }

    @IsTest
    static void handlerThatFailsAgainStaysHandlerFailed() {
        testSetting();
        RecordingJob job = new RecordingJob('h2');
        job.throwInHandler = true;
        Integration_Log__c log = log(job, 'Handler Failed', 1);

        Map<Id, String> outcomes = IntegrationRetry.retry(new List<Id>{ log.Id });

        Assert.areEqual('Handler Failed', outcomes.get(log.Id), 'still failed');
        Integration_Log__c after = reload(log.Id);
        Assert.areEqual('Handler Failed', after.Status__c, 'status kept');
        Assert.isTrue(after.Error_Message__c.contains('again') && after.Error_Message__c.contains('handler exploded'), 'reason recorded: ' + after.Error_Message__c);
    }

    @IsTest
    static void finishedAndWaitingLogsAreSkipped() {
        testSetting();
        Integration_Log__c done = log(new RecordingJob('d'), 'Succeeded', 1);
        Integration_Log__c queued = log(new RecordingJob('q'), 'Queued', 0);

        Map<Id, String> outcomes = IntegrationRetry.retry(new List<Id>{ done.Id, queued.Id });

        Assert.areEqual('Skipped (Succeeded)', outcomes.get(done.Id), 'succeeded is not retried');
        Assert.areEqual('Skipped (Queued)', outcomes.get(queued.Id), 'queued is left to its queueable or the sweeper');
        Assert.isNull(IntegrationQueueable.lastChained, 'nothing queued');
    }

    @IsTest
    static void flowEntryPointReturnsOneOutcomePerRequest() {
        testSetting();
        Integration_Log__c failed = log(new RecordingJob('f2'), 'Failed', 2);
        Integration_Log__c done = log(new RecordingJob('d2'), 'Succeeded', 1);
        IntegrationRetry.Request first = new IntegrationRetry.Request();
        first.logId = failed.Id;
        IntegrationRetry.Request second = new IntegrationRetry.Request();
        second.logId = done.Id;
        IntegrationRetry.Request third = new IntegrationRetry.Request();
        third.logId = UserInfo.getUserId(); // not a log

        List<IntegrationRetry.Result> results = IntegrationRetry.retryFromFlow(new List<IntegrationRetry.Request>{ first, second, third });

        Assert.areEqual(3, results.size(), 'one result per request');
        Assert.areEqual('Requeued', results[0].outcome, 'failed log requeued');
        Assert.areEqual('Skipped (Succeeded)', results[1].outcome, 'done log skipped');
        Assert.areEqual('Skipped (not found)', results[2].outcome, 'unknown id reported');
    }
}
