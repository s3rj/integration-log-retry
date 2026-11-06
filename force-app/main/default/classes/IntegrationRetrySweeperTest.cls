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
    static void requeuesQueuedLogsWhoseQueueableIsGone() {
        Integration_Log__c noJob = log('Queued', null);
        Integration_Log__c abortedJob = log('Queued', null);
        Integration_Log__c waitingJob = log('Queued', null);
        Integration_Log__c young = log('Queued', null);
        insert new List<Integration_Log__c>{ noJob, abortedJob, waitingJob, young };
        Id aborted = System.enqueueJob(new IntegrationQueueable(new List<Id>()));
        System.abortJob(aborted);
        Id waiting = System.enqueueJob(new IntegrationQueueable(new List<Id>()));
        abortedJob.Async_Job_Id__c = aborted;
        waitingJob.Async_Job_Id__c = waiting;
        update new List<Integration_Log__c>{ abortedJob, waitingJob };
        Datetime old = System.now().addMinutes(-IntegrationRetrySweeper.STRANDED_AFTER_MINUTES - 1);
        Test.setCreatedDate(noJob.Id, old);
        Test.setCreatedDate(abortedJob.Id, old);
        Test.setCreatedDate(waitingJob.Id, old);

        List<Id> requeued = IntegrationRetrySweeper.requeueStranded();

        Assert.areEqual(new Set<Id>{ noJob.Id, abortedJob.Id }, new Set<Id>(requeued), 'logs without a live queueable are re-queued');
        Assert.areEqual(new Set<Id>{ noJob.Id, abortedJob.Id }, new Set<Id>(IntegrationQueueable.lastChained), 'handed to a new queueable');
        Assert.areEqual(0, IntegrationQueueable.lastChainDelay, 'immediately');
        Map<Id, Integration_Log__c> after = new Map<Id, Integration_Log__c>([SELECT Status__c, Error_Message__c FROM Integration_Log__c WHERE Id IN :requeued]);
        Assert.isTrue(after.get(abortedJob.Id).Error_Message__c.contains('ended as Aborted'), 'reason names the job status: ' + after.get(abortedJob.Id).Error_Message__c);
        Assert.isTrue(after.get(noJob.Id).Error_Message__c.contains('was not found'), 'reason for a missing job');
        Assert.areEqual('Queued', after.get(noJob.Id).Status__c, 'still Queued for the runner');
        Assert.isNull([SELECT Error_Message__c FROM Integration_Log__c WHERE Id = :waitingJob.Id].Error_Message__c, 'a log whose job is still queued is left alone');
        Assert.isNull([SELECT Error_Message__c FROM Integration_Log__c WHERE Id = :young.Id].Error_Message__c, 'a recent log is left alone');
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
