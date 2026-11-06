@IsTest
private class IntegrationRetrySweeperTest {
    private static Integration_Log__c log(String status, Datetime nextAttempt) {
        IntegrationSettings.overrides = new Map<String, IntegrationSettings.Setting>{ 'test' => new IntegrationSettings.Setting('Test') };
        Integration_Log__c log = IntegrationLogs.newLog(new RecordingJob(null), IntegrationSettings.get('Test'));
        log.Status__c = status;
        log.Next_Attempt_At__c = nextAttempt;
        return log;
    }

    @IsTest
    static void requeuesOnlyRetriesThatAreDue() {
        Integration_Log__c due = log('Retrying', System.now().addMinutes(-5));
        Integration_Log__c notDue = log('Retrying', System.now().addMinutes(30));
        Integration_Log__c queued = log('Queued', null);
        Integration_Log__c done = log('Succeeded', null);
        insert new List<Integration_Log__c>{ due, notDue, queued, done };

        Test.startTest();
        new IntegrationRetrySweeper().execute((SchedulableContext) null);
        Test.stopTest();

        Assert.areEqual(new List<Id>{ due.Id }, IntegrationQueueable.lastChained, 'only the due retry is re-queued');
        Assert.areEqual(0, IntegrationQueueable.lastChainDelay, 'immediately');
    }

    @IsTest
    static void nothingDueMeansNothingQueued() {
        insert log('Retrying', System.now().addMinutes(30));

        Test.startTest();
        Database.executeBatch(new IntegrationRetrySweeper(), 10);
        Test.stopTest();

        Assert.isNull(IntegrationQueueable.lastChained, 'no queueable');
    }

    @IsTest
    static void scheduleRegistersSixHourlyJobsTenMinutesApart() {
        List<Id> cronIds = IntegrationRetrySweeper.schedule();

        Assert.areEqual(6, cronIds.size(), 'six jobs');
        Map<String, CronTrigger> byName = new Map<String, CronTrigger>();
        for (CronTrigger cron : [SELECT CronExpression, CronJobDetail.Name FROM CronTrigger WHERE Id IN :cronIds]) {
            byName.put(cron.CronJobDetail.Name, cron);
        }
        Assert.areEqual('0 0 * * * ?', byName.get('Integration retry sweeper :00').CronExpression, 'top of the hour');
        Assert.areEqual('0 50 * * * ?', byName.get('Integration retry sweeper :50').CronExpression, 'ten to the hour');
    }
}
