@IsTest
private class IntegrationQueueableTest {
    private static List<Id> insertLogs(Integer count) {
        IntegrationSettings.overrides = new Map<String, IntegrationSettings.Setting>{
            'test' => new IntegrationSettings.Setting('Test').withMaxAttempts(3).withBaseDelayMinutes(1)
        };
        List<Integration_Log__c> logs = new List<Integration_Log__c>();
        for (Integer i = 0; i < count; i++) {
            logs.add(IntegrationLogs.newLog(new RecordingJob('q' + i), IntegrationSettings.get('Test')));
        }
        insert logs;
        return new List<Id>(new Map<Id, Integration_Log__c>(logs).keySet());
    }

    @IsTest
    static void processesOneChunkAndChainsTheRest() {
        List<Id> ids = insertLogs(12);
        Test.setMock(HttpCalloutMock.class, SequenceCalloutMock.always(200));

        Test.startTest();
        System.enqueueJob(new IntegrationQueueable(ids));
        Test.stopTest();

        Assert.areEqual(10, [SELECT COUNT() FROM Integration_Log__c WHERE Id IN :ids AND Status__c = 'Succeeded'], 'one chunk processed');
        Assert.areEqual(2, [SELECT COUNT() FROM Integration_Log__c WHERE Id IN :ids AND Status__c = 'Queued'], 'remainder untouched');
        Assert.areEqual(new List<Id>{ ids[10], ids[11] }, IntegrationQueueable.lastChained, 'remainder chained');
        Assert.areEqual(0, IntegrationQueueable.lastChainDelay, 'remainder chained without delay');
    }

    @IsTest
    static void retriesChainWithTheBackoffDelay() {
        List<Id> ids = insertLogs(1);
        Test.setMock(HttpCalloutMock.class, SequenceCalloutMock.always(503));

        Test.startTest();
        System.enqueueJob(new IntegrationQueueable(ids));
        Test.stopTest();

        Assert.areEqual('Retrying', [SELECT Status__c FROM Integration_Log__c WHERE Id = :ids[0]].Status__c, 'retrying');
        Assert.areEqual(ids, IntegrationQueueable.lastChained, 'retry chained');
        Assert.areEqual(1, IntegrationQueueable.lastChainDelay, 'with the backoff delay');
    }

    @IsTest
    static void nothingChainsWhenEverythingSucceeds() {
        List<Id> ids = insertLogs(2);
        Test.setMock(HttpCalloutMock.class, SequenceCalloutMock.always(200));

        Test.startTest();
        System.enqueueJob(new IntegrationQueueable(ids));
        Test.stopTest();

        Assert.isNull(IntegrationQueueable.lastChained, 'no chain');
        Assert.areEqual(2, [SELECT COUNT() FROM Integration_Log__c WHERE Id IN :ids AND Status__c = 'Succeeded'], 'both succeeded');
    }

    @IsTest
    static void recoveryFinalizerRetriesLogsLeftBehindByAnAbortedJob() {
        List<Id> ids = insertLogs(2);
        update new Integration_Log__c(Id = ids[1], Attempt__c = 2); // one attempt left

        new IntegrationQueueable.Recovery(ids).execute(new AbortedContext());

        Map<Id, Integration_Log__c> logs = new Map<Id, Integration_Log__c>(
            [SELECT Status__c, Attempt__c, Next_Attempt_At__c, Error_Message__c, Completed_At__c FROM Integration_Log__c WHERE Id IN :ids]
        );
        Assert.areEqual('Retrying', logs.get(ids[0]).Status__c, 'first log retries');
        Assert.areEqual(1, logs.get(ids[0]).Attempt__c.intValue(), 'the aborted run counts as an attempt');
        Assert.isTrue(logs.get(ids[0]).Next_Attempt_At__c > System.now(), 'retry scheduled');
        Assert.isTrue(logs.get(ids[0]).Error_Message__c.contains('Apex CPU time limit exceeded'), 'reason recorded');
        Assert.areEqual('Failed', logs.get(ids[1]).Status__c, 'last attempt used up');
        Assert.isNotNull(logs.get(ids[1]).Completed_At__c, 'failed log completed');
    }

    @IsTest
    static void recoveryFinalizerDoesNothingAfterSuccess() {
        List<Id> ids = insertLogs(1);

        new IntegrationQueueable.Recovery(ids).execute(new SuccessContext());

        Assert.areEqual('Queued', [SELECT Status__c FROM Integration_Log__c WHERE Id = :ids[0]].Status__c, 'untouched');
    }

    private class AbortedContext implements FinalizerContext {
        public Id getAsyncApexJobId() {
            return null;
        }
        public String getRequestId() {
            return 'test';
        }
        public ParentJobResult getResult() {
            return ParentJobResult.UNHANDLED_EXCEPTION;
        }
        public Exception getException() {
            return new IntegrationDispatcher.DispatchException('Apex CPU time limit exceeded');
        }
    }

    private class SuccessContext implements FinalizerContext {
        public Id getAsyncApexJobId() {
            return null;
        }
        public String getRequestId() {
            return 'test';
        }
        public ParentJobResult getResult() {
            return ParentJobResult.SUCCESS;
        }
        public Exception getException() {
            return null;
        }
    }
}
