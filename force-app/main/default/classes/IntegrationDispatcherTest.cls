@IsTest
private class IntegrationDispatcherTest {
    private static void testSetting(Boolean active) {
        IntegrationSettings.overrides = new Map<String, IntegrationSettings.Setting>{
            'test' => new IntegrationSettings.Setting('Test').withMaxAttempts(3).withActive(active)
        };
    }

    private static Integer logsWithKey(String key) {
        return [SELECT COUNT() FROM Integration_Log__c WHERE Dedup_Key__c = :key];
    }

    @IsTest
    static void enqueueCreatesAQueuedLogThatCarriesTheJob() {
        testSetting(true);

        Id logId = IntegrationDispatcher.enqueue(new RecordingJob('a'));

        Integration_Log__c log = [
            SELECT Status__c, Attempt__c, Max_Attempts__c, Integration__c, Operation__c, Direction__c, Dedup_Key__c, Job_Class__c, Job_Payload__c, Async_Job_Id__c
            FROM Integration_Log__c
            WHERE Id = :logId
        ];
        Assert.areEqual('Queued', log.Status__c, 'queued');
        Assert.isNotNull(log.Async_Job_Id__c, 'the queueable holding the log is recorded');
        Assert.areEqual(0, log.Attempt__c.intValue(), 'no attempts yet');
        Assert.areEqual(3, log.Max_Attempts__c.intValue(), 'max attempts copied from the setting');
        Assert.areEqual('Test', log.Integration__c, 'integration name');
        Assert.areEqual('record', log.Operation__c, 'operation');
        Assert.areEqual('Outbound', log.Direction__c, 'direction');
        Assert.areEqual('a', log.Dedup_Key__c, 'dedup key');
        Assert.areEqual('RecordingJob', log.Job_Class__c, 'job class');
        Assert.isTrue(log.Job_Payload__c.contains('"key":"a"'), 'job state serialized');
        Assert.areEqual(new List<Id>{ logId }, IntegrationDispatcher.lastQueued, 'handed to the queue');
    }

    @IsTest
    static void anActiveLogWithTheSameKeyIsReusedUntilItCompletes() {
        testSetting(true);

        Id first = IntegrationDispatcher.enqueue(new RecordingJob('a'));
        Id again = IntegrationDispatcher.enqueue(new RecordingJob('a'));
        Assert.areEqual(first, again, 'same active log returned');
        Assert.areEqual(1, logsWithKey('a'), 'one log');

        update new Integration_Log__c(Id = first, Status__c = 'Succeeded');
        Id fresh = IntegrationDispatcher.enqueue(new RecordingJob('a'));
        Assert.areNotEqual(first, fresh, 'a completed log does not block new work');
        Assert.areEqual(2, logsWithKey('a'), 'two logs now');
    }

    @IsTest
    static void duplicateKeysWithinOneCallShareOneLog() {
        testSetting(true);

        List<Id> ids = IntegrationDispatcher.enqueueAll(new List<IntegrationJob>{ new RecordingJob('a'), new RecordingJob('a'), new RecordingJob('b') });

        Assert.areEqual(ids[0], ids[1], 'same key, same log');
        Assert.areNotEqual(ids[0], ids[2], 'different key, different log');
        Assert.areEqual(2, [SELECT COUNT() FROM Integration_Log__c WHERE Dedup_Key__c IN ('a', 'b')], 'two logs inserted');
        Assert.areEqual(2, IntegrationDispatcher.lastQueued.size(), 'two logs queued');
    }

    @IsTest
    static void jobsWithoutKeysAreNeverDeduplicated() {
        testSetting(true);

        List<Id> ids = IntegrationDispatcher.enqueueAll(new List<IntegrationJob>{ new RecordingJob(null), new RecordingJob(null) });

        Assert.areNotEqual(ids[0], ids[1], 'two separate logs');
    }

    @IsTest
    static void inactiveIntegrationsRefuseNewWork() {
        testSetting(false);
        try {
            IntegrationDispatcher.enqueue(new RecordingJob('a'));
            Assert.fail('expected DispatchException');
        } catch (IntegrationDispatcher.DispatchException e) {
            Assert.isTrue(e.getMessage().contains('inactive'), 'reason given: ' + e.getMessage());
        }
        Assert.areEqual(0, logsWithKey('a'), 'nothing logged');
    }

    @IsTest
    static void queuedWorkRunsAsynchronously() {
        testSetting(true);
        Test.setMock(HttpCalloutMock.class, SequenceCalloutMock.always(200));

        Test.startTest();
        List<Id> ids = IntegrationDispatcher.enqueueAll(new List<IntegrationJob>{ new RecordingJob('a'), new RecordingJob('b'), new RecordingJob('c') });
        Test.stopTest();

        Assert.areEqual(3, [SELECT COUNT() FROM Integration_Log__c WHERE Id IN :ids AND Status__c = 'Succeeded'], 'all three succeeded');
        Assert.areEqual(3, RecordingJob.successes, 'three success callbacks');
    }
}
